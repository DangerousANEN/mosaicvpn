#!/usr/bin/env bash
# Build the GPLv3 sing-box/libbox Android runtime used by MosaicVPN.
#
# This script is intentionally source-first: every release can reconstruct the
# native AAR from the pinned upstream revision instead of downloading a binary
# of unknown provenance. It requires Go 1.23+, JDK 17, Android SDK and NDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.13.18"
REVISION="45ca32dcb966f07f97fc888fe8586e359dbe8405"
UPSTREAM="https://github.com/SagerNet/sing-box.git"
WORK_DIR="${SINGBOX_SOURCE_DIR:-$ROOT/.cache/sing-box-$VERSION}"
OUTPUT_DIR="$ROOT/flutter/android/app/libs"
PROVENANCE="$ROOT/flutter/android/libbox/VERSION.txt"

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to the Android SDK." >&2
  exit 1
fi
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  echo "ANDROID_NDK_HOME must point to the Android NDK." >&2
  exit 1
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "JAVA_HOME must point to JDK 17." >&2
  exit 1
fi
if ! "$JAVA_HOME/bin/java" --version 2>&1 | grep -q 'openjdk 17'; then
  echo "libbox build requires OpenJDK 17." >&2
  exit 1
fi

if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  git clone --filter=blob:none "$UPSTREAM" "$WORK_DIR"
fi
cd "$WORK_DIR"
git fetch --tags --force origin
git checkout --detach "$REVISION"
[[ "$(git rev-parse HEAD)" == "$REVISION" ]]

make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"

scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
for arch in arm64 arm amd64 386; do
  go run ./cmd/internal/build_libbox -target android -platform "android/$arch"
  mkdir -p "$scratch/$arch"
  mv libbox.aar "$scratch/$arch/libbox.aar"
  mv libbox-legacy.aar "$scratch/$arch/libbox-legacy.aar"
done

go run ./cmd/internal/merge_aar -output "$scratch/libbox.aar" "$scratch"/*/libbox.aar
go run ./cmd/internal/merge_aar -output "$scratch/libbox-legacy.aar" "$scratch"/*/libbox-legacy.aar

mkdir -p "$OUTPUT_DIR" "$(dirname "$PROVENANCE")"
install -m 0644 "$scratch/libbox.aar" "$OUTPUT_DIR/libbox.aar"
install -m 0644 "$scratch/libbox-legacy.aar" "$OUTPUT_DIR/libbox-legacy.aar"
cat > "$PROVENANCE" <<EOF
Runtime: sing-box experimental/libbox
Version: $VERSION
Source repository: $UPSTREAM
Source revision: $REVISION
Build targets: android/arm64, android/arm, android/amd64, android/386
Build tool: github.com/sagernet/gomobile v0.1.12
License: GPL-3.0-or-later
EOF
printf '%s  %s\n' "$(sha256sum "$OUTPUT_DIR/libbox.aar" | awk '{print $1}')" "libbox.aar" >> "$PROVENANCE"
printf '%s  %s\n' "$(sha256sum "$OUTPUT_DIR/libbox-legacy.aar" | awk '{print $1}')" "libbox-legacy.aar" >> "$PROVENANCE"
printf 'Built multi-ABI Android libbox runtime:\n'
cat "$PROVENANCE"
