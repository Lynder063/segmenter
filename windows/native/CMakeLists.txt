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

# --- LibVLC -----------------------------------------------------------------
# The VLC SDK ships headers + import libraries; the runtime DLLs and the plugin
# tree are copied next to the executable below. Detection stays manual because
# VideoLAN does not publish a CMake config package for the Windows SDK.
set(VLC_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vlc" CACHE PATH "Path to the VLC SDK root")

find_path(LIBVLC_INCLUDE_DIR
    NAMES vlc/vlc.h
    HINTS "${VLC_SDK_DIR}/sdk/include" "${VLC_SDK_DIR}/include"
)
find_library(LIBVLC_LIBRARY
    NAMES libvlc vlc
    HINTS "${VLC_SDK_DIR}/sdk/lib" "${VLC_SDK_DIR}/lib"
)
find_library(LIBVLCCORE_LIBRARY
    NAMES libvlccore vlccore
    HINTS "${VLC_SDK_DIR}/sdk/lib" "${VLC_SDK_DIR}/lib"
)

if(NOT LIBVLC_INCLUDE_DIR OR NOT LIBVLC_LIBRARY)
    message(FATAL_ERROR
        "LibVLC SDK not found under '${VLC_SDK_DIR}'.\n"
        "See windows/native/build.ps1 for how to fetch it, or pass -DVLC_SDK_DIR=<path>."
    )
endif()

# --- Shared core ------------------------------------------------------------
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../core" "${CMAKE_BINARY_DIR}/core")

# --- Windows executable -----------------------------------------------------
# Only the platform layer lives here; everything else comes from segmenter_core.
qt_add_executable(Segmenter WIN32
    src/main.cpp

    src/platform/CredentialStore.cpp
    src/platform/GpuDetector.cpp
    src/platform/OcrService.cpp
)

target_link_libraries(Segmenter PRIVATE segmenter_core)

# Credential Manager, DXGI adapter enumeration, and WinRT activation for
# Windows.Media.Ocr.
target_link_libraries(Segmenter PRIVATE
    advapi32
    dxgi
    windowsapp
)

if(MSVC)
    target_compile_options(Segmenter PRIVATE /W4 /permissive- /utf-8 /MP /EHsc)
endif()

# --- Make the build output directly runnable --------------------------------
# Without this, build/<config>/bin holds a lone Segmenter.exe that fails to
# start with a missing-Qt6Widgets.dll error — the natural thing to double-click
# is the one thing that cannot work.

get_filename_component(_qt_bin_dir "${Qt6_DIR}/../../../bin" ABSOLUTE)
find_program(WINDEPLOYQT_EXECUTABLE NAMES windeployqt HINTS "${_qt_bin_dir}")

if(WINDEPLOYQT_EXECUTABLE)
    add_custom_command(TARGET Segmenter POST_BUILD
        COMMAND "${WINDEPLOYQT_EXECUTABLE}"
                --no-translations --no-system-d3d-compiler --no-opengl-sw
                --$<LOWER_CASE:$<CONFIG>>
                "$<TARGET_FILE:Segmenter>"
        COMMENT "Deploying Qt runtime next to the executable"
        VERBATIM
    )
else()
    message(WARNING
        "windeployqt not found near ${_qt_bin_dir}; the build output will not "
        "run in place. Use build.ps1, which stages dist/ explicitly.")
endif()

# LibVLC resolves its plugin tree relative to the DLL, so both DLLs and the
# whole plugins folder have to travel with the executable.
add_custom_command(TARGET Segmenter POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${VLC_SDK_DIR}/libvlc.dll" "${VLC_SDK_DIR}/libvlccore.dll"
            "$<TARGET_FILE_DIR:Segmenter>"
    COMMAND ${CMAKE_COMMAND} -E copy_directory_if_different
            "${VLC_SDK_DIR}/plugins"
            "$<TARGET_FILE_DIR:Segmenter>/plugins"
    COMMENT "Copying LibVLC runtime next to the executable"
    VERBATIM
)

install(TARGETS Segmenter RUNTIME DESTINATION .)
