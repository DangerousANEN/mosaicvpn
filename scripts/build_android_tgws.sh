#!/usr/bin/env bash
# Build the MIT tg-ws-proxy Android AAR used by MosaicVPN as the Telegram
# resilience layer (local SOCKS5 -> WS+TLS -> Telegram DC behind Cloudflare).
# Mirrors scripts/build_android_libbox.sh: source-first, reproducible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="https://github.com/d0mhate/-tg-ws-proxy-Manager-go.git"
VERSION="v1.4.1"
WORK_DIR="${TGWS_SOURCE_DIR:-$ROOT/.cache/tg-ws-proxy}"
OUTPUT_DIR="$ROOT/flutter/android/app/libs"
PROVENANCE="$ROOT/flutter/android/libbox/TGWS_VERSION.txt"

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to the Android SDK." >&2
  exit 1
fi
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  echo "ANDROID_NDK_HOME must point to the Android NDK." >&2
  exit 1
fi

if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  git clone --filter=blob:none "$REPO" "$WORK_DIR"
fi
cd "$WORK_DIR"
git fetch --tags --force origin
git checkout --detach "$VERSION"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$VERSION")" ]]

# Install official gomobile (the sagernet fork from the sing-box build has no
# `bind` package). CGO is not needed for the binding itself.
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$PATH:$(go env GOPATH)/bin"
# The gomobile bind step requires golang.org/x/mobile in the module graph.
# Copy the binding into the module tree FIRST so go mod tidy keeps it.
cp -r "$ROOT/scripts/_tgws_binding" libtgws
rm -rf libtgws/livecheck
go get -tool golang.org/x/mobile/cmd/gobind
go mod tidy

# bind: single AAR covering all ABIs via gomobile's android target.
# androidapi 24 matches the app's minSdk; the binding uses no newer APIs.
gomobile bind -v -androidapi 24 \
  -ldflags="-s -w" \
  -target=android -o "$OUTPUT_DIR/tgws.aar" \
  ./libtgws

mkdir -p "$(dirname "$PROVENANCE")"
REVISION="$(git rev-parse HEAD)"
cat > "$PROVENANCE" <<EOF
tg-ws-proxy $VERSION
Source: $REPO (MIT)
Revision: $REVISION
Binding: scripts/build_android_tgws.sh + scripts/tgws_binding/tgws.go
gomobile bind -androidapi 26 -target=android
EOF
echo "built $OUTPUT_DIR/tgws.aar"
cat "$PROVENANCE"