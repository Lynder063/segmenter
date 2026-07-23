#!/usr/bin/env bash
set -e

# Segmenter Native Swift Universal macOS Build Script
# Compiles Universal Binary (arm64 Apple Silicon + x86_64 Intel)
# Bundles static ffmpeg/ffprobe and VLCKit.framework into App Bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="$PROJECT_ROOT/macos_native"
DIST_DIR="$SCRIPT_DIR/dist_native"
APP_BUNDLE="$DIST_DIR/Segmenter.app"
BIN_DIR="$APP_BUNDLE/Contents/Resources/bin"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

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
mkdir -p "$BIN_DIR"
mkdir -p "$FRAMEWORKS_DIR"

echo "🔀 Creating Universal Binary using lipo..."
lipo -create -output "$APP_BUNDLE/Contents/MacOS/Segmenter" "$ARM64_BIN" "$X86_BIN"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy VLCKit.framework into App Bundle Frameworks directory
echo "🎬 Bundling VLCKit.framework into App Bundle Frameworks..."
VLC_FRAMEWORK="$SWIFT_DIR/.build/artifacts/vlckit-spm/VLCKit/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
if [ -d "$VLC_FRAMEWORK" ]; then
    cp -R "$VLC_FRAMEWORK" "$FRAMEWORKS_DIR/"
elif [ -d "$SWIFT_DIR/.build/arm64-apple-macosx/release/VLCKit.framework" ]; then
    cp -R "$SWIFT_DIR/.build/arm64-apple-macosx/release/VLCKit.framework" "$FRAMEWORKS_DIR/"
fi

# Add @executable_path/../Frameworks rpath so dyld loads VLCKit.framework
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/Segmenter" 2>/dev/null || true

# Bundle FFmpeg and FFprobe binaries if available in /tmp or system
echo "📦 Bundling FFmpeg & FFprobe utilities into App Bundle..."
if [ -f "/tmp/ffmpeg" ]; then
    cp "/tmp/ffmpeg" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
elif command -v ffmpeg &>/dev/null; then
    cp "$(which ffmpeg)" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
fi

if [ -f "/tmp/ffprobe" ]; then
    cp "/tmp/ffprobe" "$BIN_DIR/ffprobe"
    chmod +x "$BIN_DIR/ffprobe"
elif command -v ffprobe &>/dev/null; then
    cp "$(which ffprobe)" "$BIN_DIR/ffprobe"
    chmod +x "$BIN_DIR/ffprobe"
fi

echo "✅ Universal macOS Application created successfully at:"
echo "   $APP_BUNDLE"

echo "🔍 Verifying Universal Binary Architectures:"
file "$APP_BUNDLE/Contents/MacOS/Segmenter"
lipo -info "$APP_BUNDLE/Contents/MacOS/Segmenter"

if [ -d "$FRAMEWORKS_DIR/VLCKit.framework" ]; then
    echo "🎬 Bundled VLCKit Framework verified at:"
    echo "   $FRAMEWORKS_DIR/VLCKit.framework"
fi

echo "--------------------------------------------------------"
echo "🎉 Build finished! Run directly via:"
echo "   $APP_BUNDLE/Contents/MacOS/Segmenter"
