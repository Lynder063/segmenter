#pragma once

#include <QJsonObject>
#include <QString>

#include <stdexcept>

#include "models/Models.h"

namespace segmenter {

/// Thrown when a draft cannot be turned into a valid submission. The message is
/// user-facing — it goes straight into the status bar.
class SegmentValidationError : public std::runtime_error {
public:
    explicit SegmentValidationError(const QString &message)
        : std::runtime_error(message.toStdString())
        , m_message(message)
    {}

    const QString &message() const { return m_message; }

private:
    QString m_message;
};

/// Builds and validates the request bodies for the two upload targets.
/// Port of the macOS SegmentValidator, including its bounds and its
/// per-segment duration limits.
class SegmentValidator {
public:
    static constexpr int kMinDurationMs = 5'000;
    static constexpr int kMaxTimestampMs = 21'600'000; // 6 hours
    static constexpr int kMaxIntroDurationMs = 200'000;
    static constexpr int kMaxRecapDurationMs = 1'200'000;
    static constexpr int kMaxCreditsDurationMs = 1'800'000;
    static constexpr int kMaxPreviewDurationMs = 1'800'000;

    /// TheIntroDB v3 payload. Throws SegmentValidationError.
    static QJsonObject makeTheIntroDbSubmissionRequest(const SubmissionDraft &draft);

    /// IntroDB payload. TV only, requires a valid IMDB id and an explicit end.
    /// Throws SegmentValidationError.
    static QJsonObject makeIntroDbSubmissionRequest(const SubmissionDraft &draft);

    static QString normalizeImdb(const QString &raw);
    static bool isValidImdb(const QString &imdb);

private:
    struct ValidatedRange {
        int startMs = 0;
        std::optional<int> endMs;
    };

    static ValidatedRange validateDraftRange(const SubmissionDraft &draft);
    static ValidatedRange validateIntroOrRecap(const SubmissionDraft &draft, int maxDurationMs);
    static ValidatedRange validateCreditsOrPreview(const SubmissionDraft &draft, int maxDurationMs);

    static void assertTimestampBounds(int value);

    /// IntroDB names the closing segment "outro" and has no preview concept.
    static QString toIntroDbSegmentType(SegmentType segment);
};

} // namespace segmenter
