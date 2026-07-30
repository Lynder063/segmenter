#!/usr/bin/env bash
set -e

# Segmenter macOS App & DMG Packaging Script
# Creates a standalone macOS .app bundle and .dmg disk image.
# Supports both Apple Silicon (arm64) and Intel (x86_64).

# mac/python -> mac -> repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
BUILD_DIR="$SCRIPT_DIR/build"
VENV_DIR="$SCRIPT_DIR/venv"

ARCH="$(uname -m)"
echo "🍏 Building Segmenter standalone application for macOS ($ARCH)..."

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

# Clean build and dist
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

ICON_PATH="$PROJECT_ROOT/linux/app_icon.png"
PLIST_PATH="$SCRIPT_DIR/Info.plist"

echo "🛠️ Compiling PyInstaller macOS App Bundle..."
pyinstaller \
    --noconfirm \
    --clean \
    --windowed \
    --name "Segmenter" \
    --osx-bundle-identifier "org.theintrodb.segmenter" \
    --icon "$ICON_PATH" \
    --add-data "$PROJECT_ROOT/linux:linux" \
    --add-data "$ICON_PATH:." \
    "$SCRIPT_DIR/app.py"

echo "✅ App Bundle successfully created at: $SCRIPT_DIR/dist/Segmenter.app"

# Attempt DMG creation using hdiutil if available
if command -v hdiutil &>/dev/null; then
    DMG_PATH="$SCRIPT_DIR/dist/Segmenter-$ARCH.dmg"
    echo "📦 Creating macOS Disk Image ($DMG_PATH)..."
    hdiutil create -volname "Segmenter" -srcfolder "$SCRIPT_DIR/dist/Segmenter.app" -ov -format UDZO "$DMG_PATH"
    echo "🎉 Standalone DMG generated at: $DMG_PATH"
fi

echo "----------------------------------------"
echo "Build complete for macOS ($ARCH)!"
