#!/usr/bin/env bash
set -e

# Segmenter macOS Quick Start Launcher
# Supports Apple Silicon (arm64) and Intel (x86_64)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$SCRIPT_DIR/venv_mac"

ARCH="$(uname -m)"
echo "🍏 Segmenter Launcher for macOS ($ARCH)"
echo "----------------------------------------"

# Ensure python3 is available
if ! command -v python3 &>/dev/null; then
    echo "❌ Error: python3 is not installed or not in PATH."
    echo "Please install Python 3.10+ (e.g., via 'brew install python@3.11')."
    exit 1
fi

# Ensure ffmpeg is available
if ! command -v ffmpeg &>/dev/null; then
    echo "⚠️ Warning: ffmpeg was not found in PATH."
    echo "Audio extraction and thumbnail generation require ffmpeg (install via 'brew install ffmpeg')."
fi

# Create virtualenv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating macOS Python virtual environment in $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

echo "⚡ Activating virtual environment..."
source "$VENV_DIR/bin/activate"

echo "📥 Installing / updating macOS dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

echo "🚀 Launching Segmenter (macOS $ARCH)..."
python "$SCRIPT_DIR/app.py" "$@"
