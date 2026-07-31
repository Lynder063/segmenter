#!/usr/bin/env bash
set -euo pipefail

# Build system for the native Linux (Qt 6 / C++) Segmenter port.
#
# Shares all of its code with the Windows port via ../../core; only the three
# files under src/platform differ.
#
# Usage: ./build.sh [--debug] [--run] [--install-deps] [--prefix DIR]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TYPE="Release"
DO_RUN=0
DO_DEPS=0
PREFIX="/usr/local"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)        BUILD_TYPE="Debug"; shift ;;
        --run)          DO_RUN=1; shift ;;
        --install-deps) DO_DEPS=1; shift ;;
        --prefix)       PREFIX="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

BUILD_DIR="${SCRIPT_DIR}/build/${BUILD_TYPE}"

echo "=== Segmenter Linux Native (Qt 6 / C++) Build ==="

# --- Optional dependency install --------------------------------------------
# libsecret and tesseract are optional; the build degrades gracefully without
# them and says so, but a normal install wants both.
if [[ "${DO_DEPS}" == "1" ]]; then
    if command -v apt-get >/dev/null; then
        sudo apt-get update
        sudo apt-get install -y \
            cmake ninja-build g++ pkg-config \
            qt6-base-dev qt6-base-dev-tools \
            libvlc-dev vlc-plugin-base \
            libsecret-1-dev \
            libtesseract-dev tesseract-ocr tesseract-ocr-eng \
            ffmpeg
    elif command -v dnf >/dev/null; then
        sudo dnf install -y \
            cmake ninja-build gcc-c++ pkgconf-pkg-config \
            qt6-qtbase-devel vlc-devel libsecret-devel \
            tesseract-devel tesseract-langpack-eng ffmpeg
    elif command -v pacman >/dev/null; then
        sudo pacman -S --needed --noconfirm \
            cmake ninja gcc pkgconf qt6-base vlc libsecret tesseract tesseract-data-eng ffmpeg
    else
        echo "Unrecognised package manager — install the Qt 6, LibVLC, libsecret" >&2
        echo "and Tesseract development packages by hand." >&2
        exit 1
    fi
fi

# --- Preflight ---------------------------------------------------------------
missing=()
command -v cmake >/dev/null || missing+=("cmake")
command -v g++   >/dev/null || missing+=("g++")
pkg-config --exists libvlc || missing+=("libvlc-dev")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing build dependencies: ${missing[*]}" >&2
    echo "Run: $0 --install-deps" >&2
    exit 1
fi

GENERATOR="Unix Makefiles"
command -v ninja >/dev/null && GENERATOR="Ninja"
echo "Generator:      ${GENERATOR}"
echo "Build type:     ${BUILD_TYPE}"
echo "Install prefix: ${PREFIX}"

# --- Configure & build -------------------------------------------------------
# SEGMENTER_CMAKE_EXTRA_ARGS is intentionally word-split (e.g. CI sets it to
# "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache");
# unset or empty for a normal local build.
# shellcheck disable=SC2086
cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" -G "${GENERATOR}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    ${SEGMENTER_CMAKE_EXTRA_ARGS:-}

cmake --build "${BUILD_DIR}" --parallel "$(nproc)"

BINARY="${BUILD_DIR}/bin/Segmenter"
if [[ ! -x "${BINARY}" ]]; then
    echo "Build reported success but ${BINARY} is missing." >&2
    exit 1
fi

SIZE="$(du -h "${BINARY}" | cut -f1)"
echo "=== Build complete: ${BINARY} (${SIZE}) ==="

if ! command -v ffmpeg >/dev/null; then
    echo
    echo "Note: ffmpeg is not on PATH. The frame strip, the waveform and RCD"
    echo "scanning all need it — install it before using those features."
fi

if [[ "${DO_RUN}" == "1" ]]; then
    echo "Launching Segmenter..."
    exec "${BINARY}"
fi

echo
echo "Install system-wide with:  sudo cmake --install ${BUILD_DIR}"
