#!/usr/bin/env bash
set -euo pipefail

# Builds and bundles the Flatpak in this directory.
#
# Unlike package.sh, this does not reuse a ../build.sh output: Flatpak builds
# from source inside its own sandbox, against its own copy of Qt 6/libvlc/
# ffmpeg, so there is nothing to share with the host build.
#
# Usage: ./build.sh [--version X.Y.Z] [--local-source]
#
#   --local-source  Build this checkout instead of cloning
#                    github.com/Lynder063/segmenter, by pointing the manifest
#                    at segmenter-module.local.yml instead of
#                    segmenter-module.yml. Faster for iterating on the
#                    manifest itself; the committed manifest always builds
#                    from the pushed main branch, since that is what a real
#                    Flathub submission has to do.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="dev.lynder.Segmenter"
MANIFEST="${SCRIPT_DIR}/${APP_ID}.yml"
RUNTIME_VERSION="6.11"
VERSION="1.0.0"
LOCAL_SOURCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="$2"; shift 2 ;;
        --local-source) LOCAL_SOURCE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "=== Segmenter Flatpak build ==="

command -v flatpak >/dev/null || { echo "flatpak not found." >&2; exit 1; }
command -v flatpak-builder >/dev/null || { echo "flatpak-builder not found." >&2; exit 1; }

if ! flatpak remote-list --user 2>/dev/null | grep -q '^flathub'; then
    echo "Adding the flathub remote (--user)..."
    flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fi

for ref in "org.kde.Platform//${RUNTIME_VERSION}" "org.kde.Sdk//${RUNTIME_VERSION}"; do
    name="${ref%%//*}"
    if ! flatpak info --user "${name}" "${RUNTIME_VERSION}" >/dev/null 2>&1; then
        echo "Installing ${ref}..."
        flatpak install --user -y flathub "${ref}"
    fi
done

BUILD_DIR="${SCRIPT_DIR}/build"
REPO_DIR="${SCRIPT_DIR}/repo"
DIST_DIR="${SCRIPT_DIR}/../dist"
STATE_DIR="${SCRIPT_DIR}/.flatpak-builder"

MANIFEST_TO_BUILD="${MANIFEST}"
if [[ "${LOCAL_SOURCE}" == "1" ]]; then
    echo "Building from this checkout instead of cloning main..."
    MANIFEST_TO_BUILD="${SCRIPT_DIR}/.local-source.yml"
    sed 's/segmenter-module\.yml/segmenter-module.local.yml/' "${MANIFEST}" > "${MANIFEST_TO_BUILD}"
fi

rm -rf "${REPO_DIR}"
echo "Running flatpak-builder (this compiles ffmpeg and libvlc from source — expect it to take a while)..."
flatpak-builder --force-clean --state-dir="${STATE_DIR}" \
    --repo="${REPO_DIR}" \
    "${BUILD_DIR}" "${MANIFEST_TO_BUILD}"

mkdir -p "${DIST_DIR}"
BUNDLE="${DIST_DIR}/Segmenter-${VERSION}-x86_64.flatpak"
flatpak build-bundle "${REPO_DIR}" "${BUNDLE}" "${APP_ID}"

echo
echo "=== Build complete: ${BUNDLE} ==="
echo "Install with:  flatpak install --user ${BUNDLE}"
echo "Run with:      flatpak run ${APP_ID}"
