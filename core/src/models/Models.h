#pragma once

#include <QColor>
#include <QString>
#include <QVector>

#include <optional>

namespace segmenter {

// MARK: - Media Type

enum class MediaType {
    Movie,
    Tv,
};

QString mediaTypeApiValue(MediaType type);
QString mediaTypeDisplayName(MediaType type);
std::optional<MediaType> mediaTypeFromApiValue(const QString &value);

// MARK: - Segment Type

enum class SegmentType {
    Intro,
    Recap,
    Credits,
    Preview,
};

// Iteration order is the order the tracks appear in the timeline and the order
// the draft rows appear in the sidebar.
const QVector<SegmentType> &allSegmentTypes();

QString segmentTypeApiValue(SegmentType type);
QString segmentTypeDisplayName(SegmentType type);
std::optional<SegmentType> segmentTypeFromApiValue(const QString &value);

// Same palette as the macOS port (Models.swift) so a segment reads the same
// colour on either platform.
QColor segmentTypeColor(SegmentType type);
QString segmentTypeHexColor(SegmentType type);

// MARK: - Segment Range

struct SegmentRange {
    std::optional<int> startMs;
    std::optional<int> endMs;

    int normalizedStartMs() const { return std::max(startMs.value_or(0), 0); }
};

// MARK: - Segment Draft

struct SegmentDraft {
    std::optional<int> startMs;
    std::optional<int> endMs;

    bool isEmpty() const { return !startMs.has_value() && !endMs.has_value(); }
    bool isComplete() const { return startMs.has_value() && endMs.has_value(); }

    bool operator==(const SegmentDraft &other) const {
        return startMs == other.startMs && endMs == other.endMs;
    }
};

// MARK: - Timeline Density Track (Waveform & Spectral Flatness)

struct TimelineDensityTrack {
    QString label;
    QVector<float> buckets;
    QVector<float> musicLikelihoodBuckets;

    bool hasContent() const { return !label.isEmpty() && !buckets.isEmpty(); }
};

// MARK: - Media Query

struct MediaQuery {
    std::optional<int> tmdbId;
    QString imdbId;
    std::optional<int> season;
    std::optional<int> episode;
    std::optional<int> durationMs;
};

// MARK: - Submission Draft

struct SubmissionDraft {
    int tmdbId = 0;
    QString imdbId;
    MediaType mediaType = MediaType::Movie;
    SegmentType segment = SegmentType::Intro;
    std::optional<int> season;
    std::optional<int> episode;
    std::optional<int> startMs;
    std::optional<int> endMs;
    std::optional<int> videoDurationMs;
};

// MARK: - Usage Headers

struct UsageHeaders {
    std::optional<int> rateLimit;
    std::optional<int> rateRemaining;
    std::optional<int> rateResetSeconds;
    std::optional<int> usageLimit;
    std::optional<int> usageRemaining;
    std::optional<int> usageResetSeconds;

    QString shortDescription() const;
};

// MARK: - Auto Lookup Result

struct AutoLookupResult {
    int tmdbId = 0;
    QString imdbId;
    MediaType mediaType = MediaType::Movie;
    std::optional<int> season;
    std::optional<int> episode;
    QString title;
    std::optional<int> matchedYear;
    QString posterUrl;

    QString displayLabel() const;
};

// MARK: - Parsed Filename Hint

struct ParsedFilenameHint {
    QString title;
    std::optional<int> year;
    std::optional<int> season;
    std::optional<int> episode;

    MediaType mediaTypeHint() const {
        return (season.has_value() || episode.has_value()) ? MediaType::Tv : MediaType::Movie;
    }
};

// MARK: - Media Info

struct MediaInfo {
    int durationMs = 0;
    double frameRate = 0.0;
    int width = 0;
    int height = 0;
    QString videoCodec;
    QString audioCodec;

    bool isValid() const { return durationMs > 0; }
};

// MARK: - RCD Match

struct RcdMatch {
    SegmentType type = SegmentType::Intro;
    double startSec = 0.0;
    double endSec = 0.0;
    float confidence = 0.0f;

    double durationSec() const { return endSec - startSec; }
};

// MARK: - RCD Detection Method
//
// Mirrors the four methods the macOS port settled on. The Apple-framework names
// are replaced by the Windows backends that stand in for them: a hand-rolled
// radix-2 FFT where macOS uses Accelerate vDSP, and Windows.Media.Ocr where
// macOS uses Vision.

enum class RcdDetectionMethod {
    HardwareAccelerated,
    ChromaprintFft,
    MultimodalFusion,
    SingleEpisode,
};

const QVector<RcdDetectionMethod> &allRcdDetectionMethods();

QString rcdMethodDisplayName(RcdDetectionMethod method);
QString rcdMethodDescription(RcdDetectionMethod method);

// Only the season-scan methods need a folder of sibling episodes to correlate
// against; SingleEpisode deliberately does not.
bool rcdMethodNeedsSeasonFolder(RcdDetectionMethod method);

// MARK: - Time formatting

// "01:56.042" — the transport-bar and draft-field format.
QString formatTimecode(int milliseconds);

// "01:56.042" back to milliseconds. Also accepts "HH:MM:SS.mmm" and a bare
// millisecond count. Returns nullopt when the text cannot be read as a time.
std::optional<int> parseTimecode(const QString &text);

} // namespace segmenter
