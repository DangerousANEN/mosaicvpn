#!/usr/bin/env bash
# MosaicVPN — Build both Setup (NSIS) and Portable distributions
# ================================================================
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="$ROOT_DIR/native"
DIST_DIR="$NATIVE_DIR/dist"

echo "=== MosaicVPN Distribution Builder ==="
echo "Version: $VERSION"
echo ""

# --- Step 1: Build release binary ---
echo "[1/4] Building cargo --release..."
cd "$NATIVE_DIR"
cargo build --release
echo "  -> Binary: target/release/mosaicvpn.exe"
echo ""

# --- Step 2: Copy icon to dist ---
echo "[2/4] Copying icon..."
cp "$ROOT_DIR/ui/src-tauri/icons/icon.ico" "$DIST_DIR/icon.ico"
echo "  -> $DIST_DIR/icon.ico"
echo ""

# --- Step 3: Build NSIS Setup ---
echo "[3/4] Building NSIS installer..."
MAKE_NSIS="/c/Program Files (x86)/NSIS/makensis.exe"
if [ ! -f "$MAKE_NSIS" ]; then
    echo "  ERROR: makensis not found. Install NSIS: winget install NSIS.NSIS"
    exit 1
fi
cd "$DIST_DIR"
"$MAKE_NSIS" /VERSION
"$MAKE_NSIS" installer.nsi
SETUP_FILE="$DIST_DIR/mosaicvpn-setup-$VERSION.exe"
if [ -f "$SETUP_FILE" ]; then
    SIZE=$(ls -lh "$SETUP_FILE" | awk '{print $5}')
    echo "  -> Setup: $SETUP_FILE ($SIZE)"
else
    echo "  ERROR: Setup file not created!"
    exit 1
fi
echo ""

# --- Step 4: Build Portable ZIP ---
echo "[4/4] Building portable ZIP..."
PORTABLE_DIR="$DIST_DIR/mosaicvpn-portable-$VERSION"
rm -rf "$PORTABLE_DIR"
mkdir -p "$PORTABLE_DIR"
cp "$NATIVE_DIR/target/release/mosaicvpn.exe" "$PORTABLE_DIR/mosaicvpn.exe"
cp "$DIST_DIR/icon.ico" "$PORTABLE_DIR/icon.ico"
cp "$DIST_DIR/README.txt" "$PORTABLE_DIR/README.txt"

ZIP_FILE="$DIST_DIR/mosaicvpn-portable-$VERSION.zip"
cd "$DIST_DIR"
# Use PowerShell Compress-Archive for cross-platform compatibility on Windows
powershell.exe -NoProfile -Command \
    "Compress-Archive -Path '$(basename "$PORTABLE_DIR")' -DestinationPath '$(basename "$ZIP_FILE")' -Force"
if [ -f "$ZIP_FILE" ]; then
    SIZE=$(ls -lh "$ZIP_FILE" | awk '{print $5}')
    echo "  -> Portable: $ZIP_FILE ($SIZE)"
else
    echo "  ERROR: Portable ZIP not created!"
    exit 1
fi
echo ""

# --- Summary ---
echo "=== Build Complete ==="
echo ""
echo "  Setup:     mosaicvpn-setup-$VERSION.exe  ($(ls -lh "$SETUP_FILE" | awk '{print $5}'))"
echo "  Portable:  mosaicvpn-portable-$VERSION.zip  ($(ls -lh "$ZIP_FILE" | awk '{print $5}'))"
echo ""
echo "  Output dir: $DIST_DIR"
