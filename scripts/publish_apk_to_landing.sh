#!/usr/bin/env bash
# Publishes a release APK to the landing assets on the VPS.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Releases v0.3.53–v0.3.55 shipped a LOCAL `flutter build apk` artifact to the
# site. The checked-in `flutter/android/app/libs/libbox.aar` is an x86_64-only
# emulator stub, so those APKs contained ONLY `lib/x86_64/libbox.so`. On a real
# ARM phone the sing-box core is simply absent and the app crashes the moment a
# connection starts. Only CI rebuilds libbox for arm64-v8a + armeabi-v7a.
#
# Therefore: the landing APK must ALWAYS come from GitHub Releases (CI-built),
# never from a local build. This script enforces that with hard preflight gates.
#
# Usage: scripts/publish_apk_to_landing.sh v0.3.56
set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag>   e.g. $0 v0.3.56" >&2
  exit 2
fi

REPO="DangerousANEN/mosaicvpn"
APK="MosaicVPN-Android-${TAG}.apk"
URL="https://github.com/${REPO}/releases/download/${TAG}/${APK}"
VPS="${MOSAIC_VPS:-root@5.175.188.152}"
SSH_KEY="${MOSAIC_SSH_KEY:-$HOME/.ssh/id_ed25519_vitaly}"
LANDING="/etc/letsencrypt/landing/assets"

# NOTE: on Windows/MSYS the native curl.exe and scp.exe cannot resolve MSYS
# paths like /tmp/... — `mktemp -d` returns exactly that and every write fails
# with "No such file or directory". Use a native-resolvable scratch dir there.
if [[ -n "${LOCALAPPDATA:-}" ]]; then
  WORK="$(mktemp -d "${LOCALAPPDATA}/Temp/mosaic-apk-XXXXXX")"
else
  WORK="$(mktemp -d)"
fi
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading CI artifact ${APK}"
# The VPS has clean egress to GitHub; the dev workstation may need a proxy.
curl -fL --retry 3 --retry-delay 2 -o "${WORK}/${APK}" "$URL" \
  || curl -fL --socks5-hostname 127.0.0.1:10808 -o "${WORK}/${APK}" "$URL"

echo "==> Preflight: verifying ABI coverage"
ABIS="$(unzip -l "${WORK}/${APK}" | grep -oE 'lib/[^/]+/libbox\.so' || true)"
echo "$ABIS" | sed 's/^/    /'

fail() { echo "FATAL: $1" >&2; exit 1; }

grep -q 'lib/arm64-v8a/libbox.so'   <<<"$ABIS" || fail "no arm64-v8a libbox.so — this is a local/emulator build, NOT a CI artifact. Refusing to publish."
grep -q 'lib/armeabi-v7a/libbox.so' <<<"$ABIS" || fail "no armeabi-v7a libbox.so — 32-bit ARM devices would crash. Refusing to publish."

SIZE=$(stat -c %s "${WORK}/${APK}" 2>/dev/null || stat -f %z "${WORK}/${APK}")
[[ "$SIZE" -gt 60000000 ]] || fail "APK is ${SIZE} bytes; a real multi-ABI build is >60MB. Refusing to publish."
echo "    size=${SIZE} bytes — OK"

echo "==> Uploading to ${VPS}:${LANDING}"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "${WORK}/${APK}" "${VPS}:${LANDING}/${APK}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VPS" \
  "cp -p '${LANDING}/${APK}' '${LANDING}/MosaicVPN-Android.apk'"

echo "==> Verifying what the site actually serves"
# NOTE: GNU md5sum prefixes the hash with '\' when the filename contains a
# backslash (every Windows path does), so strip it before comparing.
LOCAL_MD5=$(md5sum "${WORK}/${APK}" | awk '{gsub(/^\\/,"",$1); print $1}')
REMOTE_MD5=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VPS" \
  "md5sum '${LANDING}/MosaicVPN-Android.apk'" | awk '{gsub(/^\\/,"",$1); print $1}')
[[ "$LOCAL_MD5" == "$REMOTE_MD5" ]] \
  || fail "md5 mismatch: local=${LOCAL_MD5} remote=${REMOTE_MD5}"

SERVED=$(curl -sI "https://sub.zxc1x1.ru/assets/MosaicVPN-Android.apk" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
[[ "$SERVED" == "$SIZE" ]] \
  || fail "site serves ${SERVED} bytes but the artifact is ${SIZE}"

echo "OK: ${TAG} published — md5=${LOCAL_MD5}, ${SIZE} bytes, arm64+arm32 verified."
