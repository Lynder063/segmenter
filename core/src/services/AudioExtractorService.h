#pragma once

#include <QString>
#include <QVector>

#include <functional>

namespace segmenter {

/// Builds the two density tracks the timeline draws, and that the single-file
/// structural scan reads its boundaries out of.
///
/// The macOS build gets its music likelihood from Apple's SoundAnalysis
/// classifier running on the Neural Engine. There is no equivalent on Windows,
/// so this uses spectral flatness instead — the same substitute the Linux port
/// already runs (linux/audio.py). Music is tonal and harmonic, so its spectrum
/// is peaky (low flatness); speech and ambience are closer to noise (high
/// flatness). Scoring `1 - flatness` separates a title theme from dialogue
/// well enough for the structural pass, without a model or a download.
class AudioExtractorService {
public:
    struct Result {
        /// Peak amplitude per bucket, normalised to 0..1.
        QVector<float> waveformBuckets;
        /// Music likelihood per bucket, 0..1, smoothed.
        QVector<float> musicLikelihoodBuckets;

        bool isValid() const { return !waveformBuckets.isEmpty(); }
    };

    /// Progress is reported 0-100.
    using ProgressHandler = std::function<void(int)>;

    static AudioExtractorService &instance();

    /// Blocking; call from a worker thread. `durationMs` may be 0, in which
    /// case the duration is probed via ffprobe.
    Result analyze(const QString &videoPath,
                   int durationMs,
                   const ProgressHandler &progressHandler = {}) const;

    /// Bucket count for a given duration — one bucket per 250 ms, clamped.
    /// Kept identical to the macOS formula so both builds draw the same
    /// timeline resolution for the same file.
    static int bucketCountFor(int durationMs);

private:
    AudioExtractorService() = default;

    /// Box blur over `radius` neighbours on each side, matching the macOS
    /// `smoothBuckets`. Without it, single-bucket dropouts inside a theme tune
    /// break the run-length search in the structural pass.
    static QVector<float> smoothBuckets(const QVector<float> &input, int radius);
};

} // namespace segmenter
