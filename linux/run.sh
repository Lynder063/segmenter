#!/usr/bin/env bash
set -e

# Resolve the directory of the script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=== Segmenter Linux Launcher ==="

# Check for Python 3
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is not installed or not in PATH." >&2
    exit 1
fi

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment in $DIR/.venv..."
    python3 -m venv .venv
fi

# Activate virtual environment and install requirements
echo "Installing/checking dependencies..."
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# Run the PySide6 application
echo "Starting Segmenter..."
exec .venv/bin/python app.py "$@"
