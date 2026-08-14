#!/usr/bin/env bash
# Build MosaicVPN portable tar.gz and Debian/Ubuntu .deb packages on Linux.
# Required: Flutter SDK, Go toolchain, dpkg-deb, a verified Linux sing-box binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT/flutter"
DIST_DIR="$ROOT/dist/linux"
STAGE_DIR="$DIST_DIR/MosaicVPN"
VERSION="${VERSION:-$(grep -E '^version:' "$FLUTTER_DIR/pubspec.yaml" | head -1 | sed -E 's/version:[[:space:]]*//' | cut -d+ -f1)}"
SING_BOX_BINARY="${SING_BOX_BINARY:-$ROOT/build/sing-box_linux_amd64}"
DAEMON_BINARY="${DAEMON_BINARY:-$ROOT/build/mosaicd_linux_amd64}"
CLI_BINARY="${CLI_BINARY:-$ROOT/build/mosaic_linux_amd64}"
BUNDLE="$FLUTTER_DIR/build/linux/x64/release/bundle"
PACKAGE_ROOT="$DIST_DIR/deb-root"

require_file() {
  local path="$1" hint="$2"
  if [[ ! -f "$path" ]]; then
    printf 'Required file is missing: %s\n%s\n' "$path" "$hint" >&2
    exit 1
  fi
}

command -v dpkg-deb >/dev/null || { echo 'dpkg-deb is required for the .deb package.' >&2; exit 1; }
command -v go >/dev/null || { echo 'Go is required to build mosaicd.' >&2; exit 1; }

cd "$FLUTTER_DIR"
flutter pub get
flutter build linux --release
require_file "$BUNDLE/mosaicvpn" 'Verify flutter/linux/CMakeLists.txt sets BINARY_NAME to mosaicvpn.'

mkdir -p "$ROOT/build" "$DIST_DIR"
if [[ ! -f "$DAEMON_BINARY" ]]; then
  (cd "$ROOT" && go build -trimpath -ldflags='-s -w' -o "$DAEMON_BINARY" ./cmd/mosaicd)
fi
if [[ ! -f "$CLI_BINARY" && -d "$ROOT/cmd/mosaic" ]]; then
  (cd "$ROOT" && go build -trimpath -ldflags='-s -w' -o "$CLI_BINARY" ./cmd/mosaic)
fi
require_file "$DAEMON_BINARY" 'Build mosaicd successfully before packaging.'
require_file "$SING_BOX_BINARY" 'Set SING_BOX_BINARY to the verified sing-box Linux executable.'

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "$BUNDLE/." "$STAGE_DIR/"
install -m 0755 "$DAEMON_BINARY" "$STAGE_DIR/mosaicd"
install -m 0755 "$SING_BOX_BINARY" "$STAGE_DIR/sing-box"
if [[ -f "$CLI_BINARY" ]]; then install -m 0755 "$CLI_BINARY" "$STAGE_DIR/mosaic"; fi
cat > "$STAGE_DIR/README.txt" <<EOF
MosaicVPN $VERSION — Linux portable

Start the client with: ./mosaicvpn

Keep mosaicd and sing-box next to mosaicvpn. The client needs these native files
for a complete local tunnel runtime. For system installation use the matching
MosaicVPN_${VERSION}_amd64.deb package.
EOF
python3 "$ROOT/scripts/make_linux_tar.py" "$STAGE_DIR" "$DIST_DIR/MosaicVPN-Portable-x86_64-v$VERSION.tar.gz"

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT/DEBIAN" "$PACKAGE_ROOT/opt/mosaicvpn" \
  "$PACKAGE_ROOT/usr/bin" "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor"
cp -a "$STAGE_DIR/." "$PACKAGE_ROOT/opt/mosaicvpn/"
ln -s /opt/mosaicvpn/mosaicvpn "$PACKAGE_ROOT/usr/bin/mosaicvpn"
cat > "$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: mosaicvpn
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libayatana-appindicator3-1 | libappindicator3-1
Maintainer: MosaicVPN <support@mosaicvpn.local>
Description: MosaicVPN desktop client
 A cross-platform desktop client for a protected network connection.
EOF
cat > "$PACKAGE_ROOT/usr/share/applications/ru.mosaicvpn.client.desktop" <<'EOF'
[Desktop Entry]
Name=MosaicVPN
Comment=MosaicVPN desktop client
Exec=/opt/mosaicvpn/mosaicvpn
Icon=ru.mosaicvpn.client
Terminal=false
Type=Application
Categories=Network;Utility;
StartupWMClass=ru.mosaicvpn.client
EOF
for directory in "$FLUTTER_DIR/assets/icons/hicolor"/*x*; do
  [[ -d "$directory" ]] || continue
  target="$PACKAGE_ROOT/usr/share/icons/hicolor/$(basename "$directory")/apps"
  mkdir -p "$target"
  cp "$directory/apps/ru.mosaicvpn.client.png" "$target/"
done
chmod 0755 "$PACKAGE_ROOT/DEBIAN"
dpkg-deb --root-owner-group --build "$PACKAGE_ROOT" "$DIST_DIR/MosaicVPN_${VERSION}_amd64.deb"

printf '\nCreated artifacts:\n  %s\n  %s\n' \
  "$DIST_DIR/MosaicVPN-Portable-x86_64-v$VERSION.tar.gz" \
  "$DIST_DIR/MosaicVPN_${VERSION}_amd64.deb"
