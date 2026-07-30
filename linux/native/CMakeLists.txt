cmake_minimum_required(VERSION 3.21)

project(Segmenter
    VERSION 1.0.0
    DESCRIPTION "Visual timestamp annotation and automatic AI segment detection"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC OFF)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Network Concurrent)
qt_standard_project_setup()

find_package(PkgConfig REQUIRED)

# --- LibVLC -----------------------------------------------------------------
# Unlike Windows, distributions ship libvlc with a pkg-config file, so there is
# no vendored SDK to find.
pkg_check_modules(LIBVLC REQUIRED IMPORTED_TARGET libvlc)
set(LIBVLC_INCLUDE_DIR "${LIBVLC_INCLUDE_DIRS}")
set(LIBVLC_LIBRARY "${LIBVLC_LINK_LIBRARIES}")

# --- Optional platform backends ---------------------------------------------
# Both are optional so the app builds on a minimal system. Each degrades in a
# way the user is told about at runtime rather than failing silently:
#   without libsecret  -> keys land in a permission-restricted file
#   without tesseract  -> RCD falls back to audio-only detection
pkg_check_modules(LIBSECRET IMPORTED_TARGET libsecret-1)
pkg_check_modules(TESSERACT IMPORTED_TARGET tesseract lept)

# --- Shared core ------------------------------------------------------------
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../core" "${CMAKE_BINARY_DIR}/core")

# --- Linux executable -------------------------------------------------------
# Only the platform layer lives here; everything else comes from segmenter_core.
qt_add_executable(Segmenter
    src/main.cpp

    src/platform/CredentialStore.cpp
    src/platform/GpuDetector.cpp
    src/platform/OcrService.cpp
)

target_link_libraries(Segmenter PRIVATE segmenter_core)

if(LIBSECRET_FOUND)
    target_compile_definitions(Segmenter PRIVATE SEGMENTER_HAVE_LIBSECRET)
    target_link_libraries(Segmenter PRIVATE PkgConfig::LIBSECRET)
    message(STATUS "libsecret found — API keys will use the Secret Service keyring")
else()
    message(WARNING
        "libsecret-1 not found — API keys will fall back to a permission-restricted "
        "file rather than the keyring. Install libsecret-1-dev to enable it.")
endif()

if(TESSERACT_FOUND)
    target_compile_definitions(Segmenter PRIVATE SEGMENTER_HAVE_TESSERACT)
    target_link_libraries(Segmenter PRIVATE PkgConfig::TESSERACT)
    message(STATUS "Tesseract found — visual credits detection enabled")
else()
    message(WARNING
        "Tesseract not found — RCD will use audio-only detection and cannot tell "
        "closing credits from a next-episode preview. Install libtesseract-dev "
        "and tesseract-ocr-eng to enable it.")
endif()

target_compile_options(Segmenter PRIVATE -Wall -Wextra)

# --- Desktop integration ----------------------------------------------------
install(TARGETS Segmenter RUNTIME DESTINATION bin)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../app_icon.png"
        DESTINATION share/icons/hicolor/256x256/apps
        RENAME segmenter.png)

# Generated rather than committed, so the Exec line always matches the install
# prefix this build was configured with.
file(WRITE "${CMAKE_BINARY_DIR}/segmenter.desktop"
"[Desktop Entry]
Name=Segmenter
Comment=Visual timestamp annotation and automatic segment detection
Exec=Segmenter %f
Icon=segmenter
Terminal=false
Type=Application
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/x-msvideo;video/quicktime;video/webm;
")
install(FILES "${CMAKE_BINARY_DIR}/segmenter.desktop" DESTINATION share/applications)
