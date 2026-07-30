# Shared Qt 6 core: models, services, RCD engine and the entire UI.
#
# Everything here is platform-neutral. The three headers in src/platform declare
# interfaces that each platform target implements and links in — that is the
# whole of the per-platform surface, and it is why Windows and Linux run the
# same application rather than two ports of it.

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Network Concurrent)

qt_add_library(segmenter_core STATIC
    src/Application.cpp
    src/Application.h
    src/Theme.cpp
    src/Theme.h

    src/models/Models.cpp
    src/models/Models.h

    src/platform/CredentialStore.h
    src/platform/GpuDetector.h
    src/platform/OcrService.h

    src/services/ApiClient.cpp
    src/services/ApiClient.h
    src/services/AudioExtractorService.cpp
    src/services/AudioExtractorService.h
    src/services/FFmpegService.cpp
    src/services/FFmpegService.h
    src/services/Fft.cpp
    src/services/Fft.h
    src/services/FilenameMediaParser.cpp
    src/services/FilenameMediaParser.h
    src/services/LoggerService.cpp
    src/services/LoggerService.h
    src/services/RcdEngine.cpp
    src/services/RcdEngine.h
    src/services/RcdFeatureCache.cpp
    src/services/RcdFeatureCache.h
    src/services/SegmentValidator.cpp
    src/services/SegmentValidator.h

    src/views/FrameStripWidget.cpp
    src/views/FrameStripWidget.h
    src/views/MainWindow.cpp
    src/views/MainWindow.h
    src/views/RcdScanDialog.cpp
    src/views/RcdScanDialog.h
    src/views/SegmentEditorRow.cpp
    src/views/SegmentEditorRow.h
    src/views/SidebarPanel.cpp
    src/views/SidebarPanel.h
    src/views/TimelineWidget.cpp
    src/views/TimelineWidget.h
    src/views/VlcVideoPlayer.cpp
    src/views/VlcVideoPlayer.h
)

qt_add_resources(segmenter_core "core_resources"
    PREFIX "/"
    FILES
        resources/app_icon.png
)

# PUBLIC so the platform targets inherit the include path and can include the
# same "platform/CredentialStore.h" the core does.
target_include_directories(segmenter_core PUBLIC src)

target_link_libraries(segmenter_core PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Concurrent
)

target_include_directories(segmenter_core PUBLIC ${LIBVLC_INCLUDE_DIR})
target_link_libraries(segmenter_core PUBLIC ${LIBVLC_LIBRARY})
if(LIBVLCCORE_LIBRARY)
    target_link_libraries(segmenter_core PUBLIC ${LIBVLCCORE_LIBRARY})
endif()

target_compile_definitions(segmenter_core PUBLIC
    SEGMENTER_VERSION="${PROJECT_VERSION}"
)

if(MSVC)
    target_compile_options(segmenter_core PRIVATE
        /W4 /permissive- /utf-8 /MP /EHsc
        $<$<CONFIG:Release>:/O2>
        # The chroma correlation inner loops are the hot path of a season scan.
        $<$<CONFIG:Release>:/fp:fast>
    )
    target_compile_definitions(segmenter_core PUBLIC
        UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
    )
else()
    target_compile_options(segmenter_core PRIVATE
        -Wall -Wextra
        $<$<CONFIG:Release>:-O2>
        $<$<CONFIG:Release>:-ffast-math>
    )
endif()
