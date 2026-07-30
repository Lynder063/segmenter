#!/usr/bin/env bash
set -euo pipefail

# Packages the native Linux build as a .deb and an AppImage.
#
# The .deb declares its Qt/VLC dependencies and lets the distribution supply
# them; the AppImage bundles everything and runs on any glibc distribution at
# least as old as the build host. Between them they cover the popular distros
# without needing one build per package format.
#
# Expects ./build.sh to have run first.
#
# Usage: ./package.sh [--build-dir DIR] [--version X.Y.Z]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build/Release"
VERSION="1.0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --version)   VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

DIST_DIR="${SCRIPT_DIR}/dist"
STAGE_DIR="${BUILD_DIR}/stage"

if [[ ! -x "${BUILD_DIR}/bin/Segmenter" ]]; then
    echo "No binary at ${BUILD_DIR}/bin/Segmenter — run ./build.sh first." >&2
    exit 1
fi

echo "=== Packaging Segmenter ${VERSION} ==="
rm -rf "${DIST_DIR}" "${STAGE_DIR}"
mkdir -p "${DIST_DIR}"

# Lay out a normal /usr tree via the install rules in CMakeLists.
DESTDIR="${STAGE_DIR}" cmake --install "${BUILD_DIR}" --prefix /usr >/dev/null
echo "Staged to ${STAGE_DIR}"

# --- .deb --------------------------------------------------------------------
echo "Building .deb..."
DEB_ROOT="${BUILD_DIR}/deb"
rm -rf "${DEB_ROOT}"
mkdir -p "${DEB_ROOT}/DEBIAN"
cp -a "${STAGE_DIR}/usr" "${DEB_ROOT}/"

# Depends is deliberately loose on minor versions: pinning exact Qt point
# releases would make the package uninstallable on the next distro update.
cat > "${DEB_ROOT}/DEBIAN/control" <<CONTROL
Package: segmenter
Version: ${VERSION}
Section: video
Priority: optional
Architecture: amd64
Depends: libqt6widgets6 (>= 6.4), libqt6network6 (>= 6.4), libqt6concurrent6 (>= 6.4), libvlc5, libc6
Recommends: ffmpeg, libsecret-1-0, tesseract-ocr, tesseract-ocr-eng, vlc-plugin-base
Maintainer: Kryštof Malinda <lynder063@users.noreply.github.com>
Description: Visual timestamp annotation and automatic segment detection
 Detect, edit and submit Intro, Recap, Credits and Preview markers for video
 files, and upload them to TheIntroDB and IntroDB.
 .
 Season fingerprinting cross-correlates the audio of every episode in a folder
 to locate recurring intros and credits automatically.
CONTROL

dpkg-deb --build --root-owner-group "${DEB_ROOT}" \
    "${DIST_DIR}/segmenter_${VERSION}_amd64.deb" >/dev/null
echo "  -> ${DIST_DIR}/segmenter_${VERSION}_amd64.deb"

# --- AppImage ----------------------------------------------------------------
echo "Building AppImage..."
APPDIR="${BUILD_DIR}/Segmenter.AppDir"
rm -rf "${APPDIR}"
cp -a "${STAGE_DIR}" "${APPDIR}"

# linuxdeploy expects the icon and desktop file at the AppDir root as well as
# in the icon theme, and resolves them by name.
cp "${APPDIR}/usr/share/icons/hicolor/256x256/apps/segmenter.png" "${APPDIR}/segmenter.png"
cp "${APPDIR}/usr/share/applications/segmenter.desktop" "${APPDIR}/segmenter.desktop"

TOOL_DIR="${BUILD_DIR}/appimage-tools"
mkdir -p "${TOOL_DIR}"

fetch_tool() {
    local name="$1" url="$2"
    if [[ ! -x "${TOOL_DIR}/${name}" ]]; then
        echo "  fetching ${name}..."
        curl -fsSL -o "${TOOL_DIR}/${name}" "${url}"
        chmod +x "${TOOL_DIR}/${name}"
    fi
}

BASE="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous"
QT_BASE="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous"

if fetch_tool linuxdeploy "${BASE}/linuxdeploy-x86_64.AppImage" \
   && fetch_tool linuxdeploy-plugin-qt "${QT_BASE}/linuxdeploy-plugin-qt-x86_64.AppImage"; then

    # Containers usually lack FUSE, which these tools need to mount themselves.
    export APPIMAGE_EXTRACT_AND_RUN=1
    export QMAKE="${QMAKE:-$(command -v qmake6 || command -v qmake || true)}"
    export OUTPUT="${DIST_DIR}/Segmenter-${VERSION}-x86_64.AppImage"

    # linuxdeploy-plugin-qt bundles only the xcb platform plugin by default.
    # That is enough for a desktop session but leaves `--scan` broken, because
    # headless mode needs the offscreen plugin — the AppImage would abort with
    # "Available platform plugins are: xcb". Wayland is added when the host has
    # it, so a Wayland session runs natively instead of through XWayland.
    EXTRA_PLUGINS="libqoffscreen.so;libqminimal.so"
    QT_PLUGIN_DIR="$(find /usr/lib -maxdepth 4 -type d -name platforms -path '*qt6*' 2>/dev/null | head -1)"
    if [[ -n "${QT_PLUGIN_DIR}" && -f "${QT_PLUGIN_DIR}/libqwayland-generic.so" ]]; then
        EXTRA_PLUGINS="${EXTRA_PLUGINS};libqwayland-generic.so"
    fi
    export EXTRA_PLATFORM_PLUGINS="${EXTRA_PLUGINS}"
    echo "  bundling extra platform plugins: ${EXTRA_PLATFORM_PLUGINS}"

    if "${TOOL_DIR}/linuxdeploy" \
        --appdir "${APPDIR}" \
        --plugin qt \
        --output appimage \
        --desktop-file "${APPDIR}/segmenter.desktop" \
        --icon-file "${APPDIR}/segmenter.png"; then
        echo "  -> ${OUTPUT}"
    else
        echo "  linuxdeploy failed — skipping AppImage." >&2
    fi
else
    echo "  could not fetch linuxdeploy — skipping AppImage." >&2
fi

echo
echo "=== Packaging complete ==="
ls -lh "${DIST_DIR}"
