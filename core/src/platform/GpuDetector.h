#pragma once

#include <QString>
#include <QStringList>

namespace segmenter {

/// Reports the installed display adapters so the scan dialog can name the
/// hardware.
///
/// Per-platform backing: DXGI on Windows, `/sys/class/drm` on Linux.
class GpuDetector {
public:
    /// Adapter descriptions, most capable first. Software rasterisers
    /// (WARP, llvmpipe) are filtered out.
    static QStringList adapters();

    /// The primary adapter's name, or a generic label when enumeration fails.
    static QString primaryAdapter();

    /// Short line for the scan dialog, e.g.
    /// "NVIDIA GeForce RTX 4070 • 16 threads".
    static QString accelerationSummary();
};

} // namespace segmenter
