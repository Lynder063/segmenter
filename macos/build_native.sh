#!/usr/bin/env bash
set -e

# Segmenter Native Swift macOS Build Script
# Compiles Universal Binary (arm64 Apple Silicon + x86_64 Intel)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="$PROJECT_ROOT/macos_native"
DIST_DIR="$SCRIPT_DIR/dist_native"
APP_BUNDLE="$DIST_DIR/Segmenter.app"

echo "🍏 Building Native Swift Universal macOS App (arm64 + x86_64)..."
echo "--------------------------------------------------------"

cd "$SWIFT_DIR"

echo "🛠️ Compiling arm64 (Apple Silicon)..."
swift build -c release --triple arm64-apple-macosx12.0

echo "🛠️ Compiling x86_64 (Intel)..."
swift build -c release --triple x86_64-apple-macosx12.0

ARM64_BIN="$SWIFT_DIR/.build/arm64-apple-macosx/release/Segmenter"
X86_BIN="$SWIFT_DIR/.build/x86_64-apple-macosx/release/Segmenter"

rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "🔀 Creating Universal Binary using lipo..."
lipo -create -output "$APP_BUNDLE/Contents/MacOS/Segmenter" "$ARM64_BIN" "$X86_BIN"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "✅ Universal macOS Application created successfully at:"
echo "   $APP_BUNDLE"

echo "🔍 Verifying Universal Binary Architectures:"
file "$APP_BUNDLE/Contents/MacOS/Segmenter"
lipo -info "$APP_BUNDLE/Contents/MacOS/Segmenter"

echo "--------------------------------------------------------"
echo "🎉 Build finished! Run directly via:"
echo "   $APP_BUNDLE/Contents/MacOS/Segmenter"
