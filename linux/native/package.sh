#!/usr/bin/env bash
set -euo pipefail

# Packages the native Linux build as a .deb, an .rpm and an AppImage, and
# copies the Arch PKGBUILD alongside them.
#
# The .deb and .rpm declare their Qt/VLC dependencies and let the distribution
# supply them; the AppImage bundles everything and runs on any glibc
# distribution at least as old as the build host. Between the three of them
# they cover the popular distros without needing one build per format — the
# PKGBUILD is the one exception, since Arch wants a source recipe rather than
# a prebuilt binary (see PKGBUILD's own header comment for why).
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
#
# qadwaitadecorations-qt6 in Recommends: GNOME's Mutter does not implement
# server-side window decoration, so Qt falls back to drawing its own — and
# without this plugin installed, main.cpp's QT_WAYLAND_DECORATION=adwaita
# silently has nothing to select, falling through to Qt's default plugin.
cat > "${DEB_ROOT}/DEBIAN/control" <<CONTROL
Package: segmenter
Version: ${VERSION}
Section: video
Priority: optional
Architecture: amd64
Depends: libqt6widgets6 (>= 6.5), libqt6network6 (>= 6.5), libqt6concurrent6 (>= 6.5), libvlc5, libc6
Recommends: ffmpeg, libsecret-1-0, tesseract-ocr, tesseract-ocr-eng, vlc-plugin-base, qadwaitadecorations-qt6
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

# --- .rpm ----------------------------------------------------------------------
if command -v rpmbuild >/dev/null; then
    echo "Building .rpm..."
    RPM_TOPDIR="${BUILD_DIR}/rpm"
    rm -rf "${RPM_TOPDIR}"
    mkdir -p "${RPM_TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    tar -czf "${RPM_TOPDIR}/SOURCES/segmenter-${VERSION}.tar.gz" -C "${STAGE_DIR}" usr
    cp "${SCRIPT_DIR}/../../LICENSE" "${RPM_TOPDIR}/SOURCES/LICENSE"

    # Repackages the same staged tree as the .deb above rather than rebuilding
    # from source — rpmbuild's own dependency scanner still adds the precise
    # library-level Requires by reading the staged binary; qt6-qtbase/vlc-libs
    # below are just the human-readable package names on top of that, loose on
    # minor versions for the same reason the .deb's Depends is.
    cat > "${RPM_TOPDIR}/SPECS/segmenter.spec" <<SPEC
# The binary here is already-built and (per CMakeLists.txt's Release flags)
# already stripped — there is no debuginfo for rpmbuild to extract, so its
# automatic debuginfo subpackage would otherwise fail on an empty file list.
%global debug_package %{nil}

Name:           segmenter
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Visual timestamp annotation and automatic segment detection
License:        MIT
URL:            https://github.com/Lynder063/segmenter
Source0:        segmenter-${VERSION}.tar.gz
Source1:        LICENSE
BuildArch:      x86_64

Requires:       qt6-qtbase >= 6.5, qt6-qtbase-gui >= 6.5, vlc-libs
Recommends:     ffmpeg-free, libsecret, tesseract, tesseract-langpack-eng, qt6-qtwayland-adwaita-decoration

%description
Detect, edit and submit Intro, Recap, Credits and Preview markers for video
files, and upload them to TheIntroDB and IntroDB.

Season fingerprinting cross-correlates the audio of every episode in a folder
to locate recurring intros and credits automatically.

%prep
%setup -q -c -n stage
cp %{SOURCE1} .

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a usr %{buildroot}/

%files
%license LICENSE
/usr/bin/Segmenter
/usr/share/icons/hicolor/256x256/apps/segmenter.png
/usr/share/applications/segmenter.desktop

%changelog
* $(LC_ALL=C date "+%a %b %d %Y") Kryštof Malinda <lynder063@users.noreply.github.com> - ${VERSION}-1
- Native Qt 6 / C++ Linux port
SPEC

    if rpmbuild --define "_topdir ${RPM_TOPDIR}" -bb "${RPM_TOPDIR}/SPECS/segmenter.spec" >/dev/null; then
        RPM_FILE="$(find "${RPM_TOPDIR}/RPMS" -name '*.rpm' | head -1)"
        cp "${RPM_FILE}" "${DIST_DIR}/"
        echo "  -> ${DIST_DIR}/$(basename "${RPM_FILE}")"
    else
        echo "  rpmbuild failed — skipping .rpm." >&2
    fi
else
    echo "rpmbuild not found — skipping .rpm. Install the rpm-build package to enable it." >&2
fi

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

# --- PKGBUILD --------------------------------------------------------------
# A recipe, not a built package — makepkg needs Arch to run — but copying it
# alongside the real packages means a local ./package.sh run produces the same
# complete dist/ that CI's release.yml assembles from these two sources.
if [[ -f "${SCRIPT_DIR}/PKGBUILD" ]]; then
    cp "${SCRIPT_DIR}/PKGBUILD" "${DIST_DIR}/"
    echo "  -> ${DIST_DIR}/PKGBUILD (Arch/AUR recipe, not a built package)"
fi

echo
echo "=== Packaging complete ==="
ls -lh "${DIST_DIR}"
