#pragma once

#include <QHash>
#include <QString>
#include <QStringList>
#include <QVector>

#include <atomic>
#include <functional>

#include "models/Models.h"

namespace segmenter {

/// Repeated-Content Detection: finds the intro and credits of every episode in
/// a season by cross-correlating chroma fingerprints between them, then
/// disambiguates credits from previews using on-screen text.
///
/// Port of the macOS RCDEngineService. The algorithm is unchanged — same 12-bin
/// chroma layout, same window-length ladder, same adaptive thresholds, same
/// boundary expansion. Only the backends differ: a hand-rolled radix-2 FFT in
/// place of Accelerate vDSP, and Windows.Media.Ocr in place of Apple Vision.
class RcdEngine {
public:
    /// (message, percent 0-100)
    using ProgressHandler = std::function<void(const QString &, int)>;
    /// Verbose line for the scan dialog's log pane.
    using DebugLogger = std::function<void(const QString &)>;

    struct Options {
        RcdDetectionMethod method = RcdDetectionMethod::HardwareAccelerated;
        double minSegmentLengthSec = 15.0;
        double similarityThreshold = 0.80;
    };

    /// Matches keyed by episode filename.
    using Results = QHash<QString, QVector<RcdMatch>>;

    class Cancelled : public std::exception {};

    static RcdEngine &instance();

    /// Scans every supported video in `directoryPath`, naturally sorted.
    /// Throws Cancelled if `cancelFlag` is raised; throws std::runtime_error
    /// with a user-facing message on setup failures.
    Results scanSeason(const QString &directoryPath,
                       const Options &options,
                       const std::atomic_bool &cancelFlag,
                       const ProgressHandler &progress,
                       const DebugLogger &debugLogger = {});

    /// Scans one standalone file. Cross-episode correlation does not apply, so
    /// this routes to structural analysis instead — see detectStructuralSegments.
    Results scanSingleEpisode(const QString &videoPath,
                              const Options &options,
                              const std::atomic_bool &cancelFlag,
                              const ProgressHandler &progress,
                              const DebugLogger &debugLogger = {});

    /// Video files in a directory, naturally sorted (S01E01, S01E02, …, S01E10).
    static QStringList videoFilesIn(const QString &directoryPath);

    /// Chroma feature vector for a PCM snippet: 12 bins per frame, L2
    /// normalised. Exposed for testing.
    static QVector<float> computeChromaFeatures(const QVector<qint16> &pcmSamples);

    /// Search-region sizes, scaled to episode length rather than fixed.
    ///
    /// A fixed 10-minute intro window is 20% of a 50-minute drama but 45% of a
    /// 22-minute animation — and every extra minute searched is more room for
    /// incidental music to out-score the real theme. Scaling keeps the searched
    /// fraction roughly constant across formats; the floors keep very short
    /// episodes workable and the ceilings stop extraction ballooning on long ones.
    static void searchRegionSeconds(int durationSec, int *introSec, int *creditsSec);

private:
    RcdEngine() = default;

    /// Per-episode chroma for the intro and credits regions.
    struct EpisodeAudio {
        QVector<float> introFeatures;
        QVector<float> creditsFeatures;
        int durationSec = 0;
        // Region lengths travel with the features: the credits offset is
        // converted back to absolute time using this episode's own length.
        int introRegionSec = 0;
        int creditsRegionSec = 0;
    };

    /// One (base episode, window length) candidate from the template search.
    struct TemplateCandidate {
        int startBucket = 0;
        int wLen = 0;
        float score = 0.0f;
        QString baseName;
        float weightedScore = 0.0f;
        bool valid = false;
    };

    struct VisualCreditsOffset {
        double secondsBeforeEndStart = 0.0;
        double secondsBeforeEndEnd = 0.0;
        bool valid = false;
    };

    struct MusicRun {
        int startBucket = 0;
        int endBucket = 0;
        float confidence = 0.0f;
        bool valid = false;
    };

    Results runScan(const QStringList &videoFiles,
                    const QString &sourceDescription,
                    const Options &options,
                    const std::atomic_bool &cancelFlag,
                    const ProgressHandler &progress,
                    const DebugLogger &debugLogger);

    QVector<float> extractFeatureVector(const QString &path, int startSec, int durationSec) const;

    TemplateCandidate searchBestTemplateWindow(const QVector<float> &baseBuckets,
                                               const QString &baseName,
                                               int wLen,
                                               bool isIntro,
                                               const QStringList &sampleEpisodes,
                                               const QHash<QString, EpisodeAudio> &episodeAudio,
                                               float minThreshold,
                                               double secPerFrame) const;

    void expandBoundaries(const QVector<float> &baseBuckets, int baseStart,
                          const QVector<float> &epBuckets, int epStart,
                          int seedWLen, bool isBaseEpisode,
                          int *startFrame, int *endFrame) const;

    // --- Single-file structural path ---
    QVector<RcdMatch> detectStructuralSegments(const QString &videoPath,
                                               double minSegmentLengthSec,
                                               const std::atomic_bool &cancelFlag,
                                               const ProgressHandler &progress,
                                               const std::function<void(const QString &)> &log) const;

    static MusicRun longestMusicRun(const QVector<float> &buckets,
                                    int rangeStart, int rangeEnd,
                                    double minLengthSec, double secPerBucket);

    // --- Visual pass ---
    int textRectangleCount(const QString &videoPath, int timeSec) const;

    VisualCreditsOffset detectCreditsVisually(const QString &videoPath,
                                              int durationSec,
                                              const std::atomic_bool &cancelFlag,
                                              const std::function<void(const QString &)> &log) const;

    TemplateCandidate pickCreditsCandidate(const QVector<TemplateCandidate> &candidates,
                                           const QHash<QString, EpisodeAudio> &episodeAudio,
                                           const QStringList &sampleEpisodes,
                                           double secPerFrame,
                                           const std::function<void(const QString &)> &log) const;

    /// Mean on-screen text lines per sampled frame across a candidate window.
    float textDensity(const QString &videoPath, double startSec, double endSec) const;

    QVector<RcdMatch> refineMatchesWithOcr(const QVector<RcdMatch> &matches,
                                           const QString &videoPath,
                                           RcdDetectionMethod method,
                                           const std::function<void(const QString &)> &log) const;
};

} // namespace segmenter
