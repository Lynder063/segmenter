#!/bin/bash
# Exit immediately on error
set -e

echo "=== Segmenter Linux Packaging Tool ==="

# Define paths
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX_DIR="${WORKSPACE_DIR}/linux"
BUILD_DIR="${LINUX_DIR}/build"
DIST_DIR="${LINUX_DIR}/dist"

# run.sh creates its virtualenv beside itself, in linux/.venv. This looked for
# it at the repository root, so the check below failed every time and packaging
# never got past this point.
VENV_DIR="${LINUX_DIR}/.venv"

# Create the environment rather than refusing to work without it: a clean
# checkout on a CI runner has never run run.sh, and asking it to would only
# mean launching a GUI app on a headless machine.
if [ ! -d "${VENV_DIR}" ]; then
    echo "No virtualenv at ${VENV_DIR} — creating one..."
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet -r "${LINUX_DIR}/requirements.txt"
fi

# Activate virtual environment
source "${VENV_DIR}/bin/activate"

# Install PyInstaller if not already installed
if ! pip show pyinstaller > /dev/null 2>&1; then
    echo "Installing PyInstaller inside virtual environment..."
    pip install pyinstaller
fi

# Clean previous build artifacts
echo "Cleaning old build directories..."
rm -rf "${BUILD_DIR}" "${DIST_DIR}"

# 1. Compile the app using PyInstaller
echo "Compiling Segmenter PySide6 application using PyInstaller..."
pyinstaller --noconfirm --clean \
    --name="segmenter" \
    --windowed \
    --add-data "${WORKSPACE_DIR}/linux/app_icon.png:." \
    --paths="${WORKSPACE_DIR}/linux" \
    "${WORKSPACE_DIR}/linux/app.py"

echo "Standalone compiled binary generated at: ${DIST_DIR}/segmenter/segmenter"

# 2. Build DEB package (Debian/Ubuntu)
echo "Preparing Debian/Ubuntu package (.deb)..."
DEB_ROOT="${BUILD_DIR}/deb"
mkdir -p "${DEB_ROOT}/DEBIAN"
mkdir -p "${DEB_ROOT}/usr/bin"
mkdir -p "${DEB_ROOT}/usr/share/applications"
mkdir -p "${DEB_ROOT}/usr/share/pixmaps"
mkdir -p "${DEB_ROOT}/usr/share/segmenter"

# Copy PyInstaller distribution files
cp -r "${DIST_DIR}/segmenter/"* "${DEB_ROOT}/usr/share/segmenter/"
# Create symlink launcher in /usr/bin
ln -sf "/usr/share/segmenter/segmenter" "${DEB_ROOT}/usr/bin/segmenter"
# Copy application icon
cp "${WORKSPACE_DIR}/linux/app_icon.png" "${DEB_ROOT}/usr/share/pixmaps/segmenter.png"

# Create Desktop Entry
cat <<EOT > "${DEB_ROOT}/usr/share/applications/segmenter.desktop"
[Desktop Entry]
Name=Segmenter
Comment=Segmenter Timestamp Marker Editor
Exec=segmenter
Icon=segmenter
Terminal=false
Type=Application
Categories=AudioVideo;Video;Player;
EOT

# Create DEB control file
cat <<EOT > "${DEB_ROOT}/DEBIAN/control"
Package: segmenter
Version: 1.0.0
Section: utils
Priority: optional
Architecture: amd64
Depends: ffmpeg
Maintainer: Lynder <lynder@example.com>
Description: Segmenter timestamp marker editor.
 Elegant PySide6 app to detect, edit and upload movie and tv theme segments to IntroDB and TheIntroDB.
EOT

# Build DEB
if command -v dpkg-deb > /dev/null 2>&1; then
    echo "Building Debian package (.deb)..."
    dpkg-deb --build "${DEB_ROOT}" "${DIST_DIR}/segmenter_1.0.0_amd64.deb"
    echo "Successfully created Debian package: ${DIST_DIR}/segmenter_1.0.0_amd64.deb"
else
    echo "dpkg-deb not found. Skipping DEB generation (only relevant for Debian/Ubuntu systems)."
fi

# 3. Build RPM package (Fedora/RHEL/CentOS)
if command -v rpmbuild > /dev/null 2>&1; then
    echo "Building RPM package (.rpm)..."
    RPM_TOPDIR="${BUILD_DIR}/rpm"
    mkdir -p "${RPM_TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    
    # Pack sources
    tar -czf "${RPM_TOPDIR}/SOURCES/segmenter-1.0.0.tar.gz" -C "${DIST_DIR}" segmenter
    
    # Create SPEC file
    cat <<EOT > "${RPM_TOPDIR}/SPECS/segmenter.spec"
Name:           segmenter
Version:        1.0.0
Release:        1%{?dist}
Summary:        Segmenter timestamp marker editor
License:        MIT
URL:            https://github.com/fetchbot/introstamp
Source0:        segmenter-1.0.0.tar.gz
Requires:       ffmpeg

%description
Segmenter timestamp marker editor. Elegant PySide6 app to detect, edit and upload movie and tv theme segments to IntroDB and TheIntroDB.

%prep
%setup -q -n segmenter

%install
mkdir -p %{buildroot}/usr/share/segmenter
cp -r * %{buildroot}/usr/share/segmenter
mkdir -p %{buildroot}/usr/bin
ln -sf /usr/share/segmenter/segmenter %{buildroot}/usr/bin/segmenter
mkdir -p %{buildroot}/usr/share/pixmaps
cp %{buildroot}/usr/share/segmenter/app_icon.png %{buildroot}/usr/share/pixmaps/segmenter.png
mkdir -p %{buildroot}/usr/share/applications
cat <<EOF > %{buildroot}/usr/share/applications/segmenter.desktop
[Desktop Entry]
Name=Segmenter
Comment=Segmenter Timestamp Marker Editor
Exec=segmenter
Icon=segmenter
Terminal=false
Type=Application
Categories=AudioVideo;Video;Player;
EOF

%files
/usr/share/segmenter/
/usr/bin/segmenter
/usr/share/pixmaps/segmenter.png
/usr/share/applications/segmenter.desktop

%changelog
* Fri Jul 03 2026 Lynder - 1.0.0-1
- Initial Python Qt application release for Linux
EOT

    rpmbuild --define "_topdir ${RPM_TOPDIR}" -bb "${RPM_TOPDIR}/SPECS/segmenter.spec"
    cp "${RPM_TOPDIR}/RPMS/x86_64/"*.rpm "${DIST_DIR}/"
    echo "Successfully created RPM package in: ${DIST_DIR}/"
elif command -v alien > /dev/null 2>&1 && [ -f "${DIST_DIR}/segmenter_1.0.0_amd64.deb" ]; then
    echo "rpmbuild not found. Using alien to convert .deb to .rpm..."
    alien --to-rpm --dest="${DIST_DIR}" "${DIST_DIR}/segmenter_1.0.0_amd64.deb"
    echo "Successfully created RPM package via alien in: ${DIST_DIR}/"
else
    echo "Neither rpmbuild nor alien found. Skipping RPM generation."
fi

# 4. Generate Arch Linux package instructions (PKGBUILD)
echo "Generating Arch Linux PKGBUILD recipe..."
cat <<EOT > "${DIST_DIR}/PKGBUILD"
# Maintainer: Lynder <lynder@example.com>
pkgname=segmenter-bin
pkgver=1.0.0
pkgrel=1
pkgdesc="Segmenter timestamp marker editor. Elegant PySide6 app to detect, edit and upload movie and tv theme segments to IntroDB and TheIntroDB."
arch=('x86_64')
url="https://github.com/fetchbot/introstamp"
license=('MIT')
depends=('ffmpeg')
provides=('segmenter')
conflicts=('segmenter')
source=() # Standalone local binary package installation

package() {
    # Install binary distribution files
    install -d "\${pkgdir}/usr/share/segmenter"
    cp -r "${DIST_DIR}/segmenter/"* "\${pkgdir}/usr/share/segmenter/"
    
    # Symlink launcher
    install -d "\${pkgdir}/usr/bin"
    ln -sf "/usr/share/segmenter/segmenter" "\${pkgdir}/usr/bin/segmenter"
    
    # Desktop Entry & Icon
    install -d "\${pkgdir}/usr/share/applications"
    cat <<EOF > "\${pkgdir}/usr/share/applications/segmenter.desktop"
[Desktop Entry]
Name=Segmenter
Comment=Segmenter Timestamp Marker Editor
Exec=segmenter
Icon=segmenter
Terminal=false
Type=Application
Categories=AudioVideo;Video;Player;
EOF
    
    install -d "\${pkgdir}/usr/share/pixmaps"
    cp "${WORKSPACE_DIR}/linux/app_icon.png" "\${pkgdir}/usr/share/pixmaps/segmenter.png"
}
EOT
echo "PKGBUILD created at: ${DIST_DIR}/PKGBUILD"

# 4. Build AppImage (distribution-independent)
#
# .deb, .rpm and PKGBUILD each only serve one packaging family. An AppImage is a
# single executable file that runs on any glibc distribution new enough for the
# build host, which is what actually covers "every popular distro" — and it is
# the format that makes sense to attach to a GitHub Release.
echo "Preparing AppImage..."
APPDIR="${BUILD_DIR}/Segmenter.AppDir"
rm -rf "${APPDIR}"
install -d "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications" "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

cp -r "${DIST_DIR}/segmenter/." "${APPDIR}/usr/bin/"
cp "${LINUX_DIR}/app_icon.png" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/segmenter.png"
# The icon has to sit at the AppDir root as well; appimagetool looks for it
# there rather than in the icon theme directory.
cp "${LINUX_DIR}/app_icon.png" "${APPDIR}/segmenter.png"

cat > "${APPDIR}/segmenter.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Segmenter
Comment=Visual timestamp annotation and automatic segment detection
Exec=segmenter
Icon=segmenter
Terminal=false
Type=Application
Categories=AudioVideo;Video;Player;
DESKTOP
cp "${APPDIR}/segmenter.desktop" "${APPDIR}/usr/share/applications/segmenter.desktop"

cat > "${APPDIR}/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "${HERE}/usr/bin/segmenter" "$@"
APPRUN
chmod +x "${APPDIR}/AppRun"

APPIMAGETOOL="$(command -v appimagetool || true)"
if [ -z "${APPIMAGETOOL}" ]; then
    echo "appimagetool not on PATH — downloading it..."
    APPIMAGETOOL="${BUILD_DIR}/appimagetool"
    curl -fsSL -o "${APPIMAGETOOL}" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" || true
    chmod +x "${APPIMAGETOOL}" 2>/dev/null || true
fi

if [ -x "${APPIMAGETOOL}" ]; then
    # Containers usually lack FUSE, which appimagetool needs to mount itself;
    # --appimage-extract-and-run sidesteps that and works everywhere.
    ARCH=x86_64 "${APPIMAGETOOL}" --appimage-extract-and-run \
        "${APPDIR}" "${DIST_DIR}/Segmenter-x86_64.AppImage" \
        && echo "AppImage created at: ${DIST_DIR}/Segmenter-x86_64.AppImage" \
        || echo "appimagetool failed — skipping AppImage."
else
    echo "appimagetool unavailable — skipping AppImage."
fi

echo "=== Packaging Complete ==="
ls -l "${DIST_DIR}"
