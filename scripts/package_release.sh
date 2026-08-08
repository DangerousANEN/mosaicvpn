#!/usr/bin/env bash
# Package built artifacts into distributable archives for the website.
#
# Produces, under dist/downloads/:
#   MosaicVPN-windows-x64.zip      GUI + mosaicd.exe + mosaic.exe
#   MosaicVPN-linux-x86_64.tar.gz  GUI + mosaicd + mosaic
#   MosaicBox-android.apk          release APK
#
# Run from the repo root:  bash scripts/package_release.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/downloads"
STAGE="$ROOT/dist/.stage"
VERSION="$(grep -E '^version:' "$ROOT/flutter/pubspec.yaml" | head -1 | sed 's/version: *//' | tr -d '\r' | cut -d+ -f1)"
VERSION="${VERSION:-0.0.0}"

mkdir -p "$OUT"
rm -rf "$STAGE"
mkdir -p "$STAGE"

ok=0; skip=0

# ── Windows ────────────────────────────────────────────────────────
WIN_SRC="$ROOT/flutter/build/windows/x64/runner/Release"
if [ -f "$WIN_SRC/mosaic_vpn.exe" ]; then
  D="$STAGE/MosaicVPN"
  mkdir -p "$D"
  cp -r "$WIN_SRC"/* "$D"/
  [ -f "$ROOT/build/mosaicd.exe" ] && cp "$ROOT/build/mosaicd.exe" "$D"/
  [ -f "$ROOT/build/mosaic.exe" ]  && cp "$ROOT/build/mosaic.exe"  "$D"/
  # The sing-box engine must sit next to mosaicd — LocateSingBox() looks for it
  # alongside the daemon binary first (internal/state/singbox_backend.go).
  # Without it Connect fails at runtime, so treat a missing engine as fatal.
  if [ -f "$ROOT/dist/MosaicVPN/sing-box.exe" ]; then
    cp "$ROOT/dist/MosaicVPN/sing-box.exe" "$D"/
    [ -f "$ROOT/dist/MosaicVPN/libcronet.dll" ] && cp "$ROOT/dist/MosaicVPN/libcronet.dll" "$D"/
  else
    echo "FAIL windows  (sing-box.exe not found — archive would ship without the VPN engine)" >&2
    exit 1
  fi
  ( cd "$STAGE" && \
    if command -v zip >/dev/null 2>&1; then
      zip -qr "$OUT/MosaicVPN-windows-x64.zip" MosaicVPN
    else
      # git-bash on Windows has no zip(1); fall back to PowerShell.
      powershell -NoProfile -Command "Compress-Archive -Path 'MosaicVPN' -DestinationPath '$(cygpath -w "$OUT/MosaicVPN-windows-x64.zip" 2>/dev/null || echo "$OUT/MosaicVPN-windows-x64.zip")' -Force"
    fi )
  rm -rf "$D"
  echo "OK   windows  -> MosaicVPN-windows-x64.zip"
  ok=$((ok+1))
else
  echo "SKIP windows  (missing $WIN_SRC/mosaic_vpn.exe — run: flutter build windows --release)"
  skip=$((skip+1))
fi

# ── Linux ──────────────────────────────────────────────────────────
LIN_SRC="$ROOT/flutter/build/linux/x64/release/bundle"
if [ -d "$LIN_SRC" ]; then
  D="$STAGE/MosaicVPN"
  mkdir -p "$D"
  cp -r "$LIN_SRC"/* "$D"/
  # Exec bits are set by make_linux_tar.py below, not here: chmod is a no-op on
  # NTFS under git-bash.
  [ -f "$ROOT/build/mosaicd_linux_amd64" ] && cp "$ROOT/build/mosaicd_linux_amd64" "$D/mosaicd"
  [ -f "$ROOT/build/mosaic_linux_amd64" ]  && cp "$ROOT/build/mosaic_linux_amd64"  "$D/mosaic"
  # Same engine requirement as Windows — see the note in the block above.
  if [ -f "$ROOT/build/sing-box_linux_amd64" ]; then
    cp "$ROOT/build/sing-box_linux_amd64" "$D/sing-box"
  else
    echo "FAIL linux    (sing-box_linux_amd64 not found — archive would ship without the VPN engine)" >&2
    exit 1
  fi
  # NTFS under git-bash does not carry a POSIX exec bit, so `chmod +x` above is
  # a no-op and a plain `tar -czf` records 0644 — leaving users with
  # "Permission denied" after extracting. Build the archive in Python so the
  # four executables get 0755 while data/ and lib/ payload stays 0644.
  #
  # Paths go through cygpath: this may be Windows python, which cannot read
  # MSYS-style /c/... paths.
  winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
  if ! python "$(winpath "$ROOT/scripts/make_linux_tar.py")" \
              "$(winpath "$D")" \
              "$(winpath "$OUT/MosaicVPN-linux-x86_64.tar.gz")"; then
    echo "FAIL linux    (tar build failed)" >&2
    exit 1
  fi
  rm -rf "$D"
  echo "OK   linux    -> MosaicVPN-linux-x86_64.tar.gz"
  ok=$((ok+1))
else
  echo "SKIP linux    (missing $LIN_SRC — run: flutter build linux --release)"
  skip=$((skip+1))
fi

# ── Android ────────────────────────────────────────────────────────
APK="$ROOT/flutter/build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK" ]; then
  cp "$APK" "$OUT/MosaicBox-android.apk"
  echo "OK   android  -> MosaicBox-android.apk"
  ok=$((ok+1))
else
  echo "SKIP android  (missing $APK — run: flutter build apk --release)"
  skip=$((skip+1))
fi

rm -rf "$STAGE"

# ── Manifest ───────────────────────────────────────────────────────
{
  echo "{"
  echo "  \"version\": \"$VERSION\","
  echo "  \"generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"files\": ["
  first=1
  for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in downloads.json) continue;; esac
    [ $first -eq 0 ] && echo ","
    first=0
    printf '    {"name": "%s", "bytes": %s}' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')"
  done
  echo ""
  echo "  ]"
  echo "}"
} > "$OUT/downloads.json"

echo ""
echo "packaged=$ok skipped=$skip  ->  $OUT"
ls -la "$OUT"
