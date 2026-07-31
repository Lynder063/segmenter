#!/usr/bin/env bash
set -euo pipefail

# Builds and packages Segmenter locally, without relying on GitHub Actions.
#
# Only Linux packages can be produced from this machine — Windows needs
# windows/native/build.ps1 on Windows, macOS needs mac/native/build.sh on
# macOS. This script just orchestrates the existing Linux scripts
# (linux/native/build.sh, linux/native/package.sh and, optionally,
# linux/native/flatpak/build.sh) so you don't have to remember the order or
# the flags. Everything it produces lands in linux/native/dist/, which is
# already git-ignored — nothing this script does gets committed.
#
# Usage: ./build-local.sh [--install-deps] [--with-flatpak] [--version X.Y.Z]
#
#   --install-deps  Install build dependencies via your distro's package
#                    manager first (apt/dnf/pacman) — same flag build.sh
#                    itself takes. Skip if you already have them.
#   --with-flatpak  Also build the Flatpak bundle. Off by default: it
#                    compiles ffmpeg and libvlc from source inside the
#                    sandbox on a cold cache, which takes a long time.
#   --version X.Y.Z Version string to embed in the packages (default 1.0.0).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="${SCRIPT_DIR}/linux/native"

INSTALL_DEPS=0
WITH_FLATPAK=0
VERSION="1.0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-deps) INSTALL_DEPS=1; shift ;;
        --with-flatpak) WITH_FLATPAK=1; shift ;;
        --version)      VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This machine isn't Linux — build.sh/package.sh here only target Linux." >&2
    echo "Windows: windows\\native\\build.ps1 on a Windows machine." >&2
    echo "macOS:   ./mac/native/build.sh on a Mac." >&2
    exit 1
fi

echo "=== 1/3: Building the native app ==="
BUILD_ARGS=()
[[ "${INSTALL_DEPS}" == "1" ]] && BUILD_ARGS+=(--install-deps)
"${LINUX_DIR}/build.sh" "${BUILD_ARGS[@]}"

echo
echo "=== 2/3: Packaging .deb, .rpm, AppImage ==="
chmod +x "${LINUX_DIR}/package.sh"
"${LINUX_DIR}/package.sh" --version "${VERSION}"

if [[ "${WITH_FLATPAK}" == "1" ]]; then
    echo
    echo "=== 3/3: Building the Flatpak (this compiles ffmpeg + libvlc from source" \
         "on a cold cache — expect it to take a while) ==="
    chmod +x "${LINUX_DIR}/flatpak/build.sh"
    "${LINUX_DIR}/flatpak/build.sh" --version "${VERSION}" --local-source
else
    echo
    echo "=== 3/3: Skipping Flatpak (pass --with-flatpak to include it) ==="
fi

echo
echo "=== Done — packages are in ${LINUX_DIR}/dist/ (git-ignored) ==="
ls -lh "${LINUX_DIR}/dist/"
