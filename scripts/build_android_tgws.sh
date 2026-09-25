#!/usr/bin/env bash
# Build the MIT tg-ws-proxy engine binaries for MosaicVPN's Telegram
# resilience layer (github.com/d0mhate/-tg-ws-proxy-Manager-go).
#
# The engine ships as EXECUTABLES inside the APK's jniLibs (libtgws.so per
# ABI), spawned out-of-process by the Kotlin TgWsBridge. This avoids the
# two-gomobile-runtimes clash: the app already embeds libgojni.so from
# sing-box, so a second gomobile AAR can never coexist in one classloader.
#
# All android GOARCH targets require external linking, so every build goes
# through the NDK clang wrapper (cgo enabled, no Go sources use C).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="v1.4.1"
UPSTREAM="https://github.com/d0mhate/-tg-ws-proxy-Manager-go.git"
WORK_DIR="${TGWS_SOURCE_DIR:-$ROOT/.cache/tg-ws-proxy}"
OUTPUT_DIR="$ROOT/flutter/android/app/src/main/jniLibs"
BINDING_SRC="$ROOT/scripts/_tgws_binding/cmd/tgws"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  echo "ANDROID_NDK_HOME must point to the Android NDK." >&2
  exit 1
fi

mkdir -p "$ROOT/.cache"
if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  git clone --filter=blob:none "$UPSTREAM" "$WORK_DIR"
fi
cd "$WORK_DIR" || exit 1
git fetch --tags --force origin
git checkout --detach "$VERSION"

# Runner-side binding source lives in-repo (underscore dir: invisible to
# `go vet ./...` at the repo root).
rm -rf ./cmd_tgws_mosaic
cp -r "$BINDING_SRC" ./cmd_tgws_mosaic

NDK_LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin"
if [[ ! -d "$NDK_LLVM" ]]; then
  NDK_LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
fi

build_one() { # goarch api-level-suffix triplet
  local goarch="$1" api="$2" triplet="$3"
  local cc="$NDK_LLVM/${api}-clang"
  mkdir -p "$OUTPUT_DIR/$triplet"
  CC="$cc" CGO_ENABLED=1 GOOS=android GOARCH="$goarch" \
    go build -trimpath -ldflags="-s -w" \
    -o "$OUTPUT_DIR/$triplet/libtgws.so" \
    ./cmd_tgws_mosaic
  echo "built $OUTPUT_DIR/$triplet/libtgws.so"
}

build_one arm64 aarch64-linux-android24 arm64-v8a
build_one arm   armv7a-linux-androideabi24 armeabi-v7a
build_one 386   i686-linux-android24 x86
build_one amd64 x86_64-linux-android24 x86_64

rm -rf ./cmd_tgws_mosaic
printf '%s  %s\n' "$(sha256sum "$OUTPUT_DIR/arm64-v8a/libtgws.so" | awk '{print $1}')" "libtgws.so (arm64-v8a)"
echo "tgws engine build complete"
