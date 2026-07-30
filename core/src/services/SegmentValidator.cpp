#include "services/SegmentValidator.h"

#include <QJsonValue>
#include <QRegularExpression>

namespace segmenter {

QString SegmentValidator::normalizeImdb(const QString &raw)
{
    const QString trimmed = raw.trimmed();
    return trimmed.isEmpty() ? QString() : trimmed;
}

bool SegmentValidator::isValidImdb(const QString &imdb)
{
    static const QRegularExpression pattern(QStringLiteral("^tt[0-9]{7,8}$"));
    return pattern.match(imdb).hasMatch();
}

QString SegmentValidator::toIntroDbSegmentType(SegmentType segment)
{
    switch (segment) {
    case SegmentType::Intro:   return QStringLiteral("intro");
    case SegmentType::Recap:   return QStringLiteral("recap");
    case SegmentType::Credits: return QStringLiteral("outro");
    case SegmentType::Preview: return QString(); // unsupported
    }
    return QString();
}

void SegmentValidator::assertTimestampBounds(int value)
{
    if (value < 0 || value > kMaxTimestampMs) {
        throw SegmentValidationError(
            QStringLiteral("Timestamp must be between 0 and %1").arg(kMaxTimestampMs));
    }
}

SegmentValidator::ValidatedRange
SegmentValidator::validateIntroOrRecap(const SubmissionDraft &draft, int maxDurationMs)
{
    const QString name = segmentTypeDisplayName(draft.segment);

    int start = 0;
    if (!draft.startMs.has_value()) {
        // An intro that begins at the very first frame is routinely left blank;
        // every other segment has to say where it starts.
        if (draft.segment != SegmentType::Intro) {
            throw SegmentValidationError(QStringLiteral("%1 start is required").arg(name));
        }
    } else {
        start = std::max(*draft.startMs, 0);
    }

    if (!draft.endMs.has_value()) {
        throw SegmentValidationError(QStringLiteral("%1 end is required").arg(name));
    }
    const int end = *draft.endMs;

    assertTimestampBounds(start);
    assertTimestampBounds(end);

    if (end < start) {
        throw SegmentValidationError(
            QStringLiteral("End must be greater than or equal to start"));
    }

    // A zero-length range is the documented way to say "this show has no intro",
    // so it bypasses the minimum-duration floor.
    const int duration = end - start;
    if (duration != 0 && (duration < kMinDurationMs || duration > maxDurationMs)) {
        throw SegmentValidationError(
            QStringLiteral("%1 duration must be 0 or between %2s and %3s")
                .arg(name)
                .arg(kMinDurationMs / 1000)
                .arg(maxDurationMs / 1000));
    }

    return ValidatedRange{start, end};
}

SegmentValidator::ValidatedRange
SegmentValidator::validateCreditsOrPreview(const SubmissionDraft &draft, int maxDurationMs)
{
    const QString name = segmentTypeDisplayName(draft.segment);

    if (!draft.startMs.has_value()) {
        throw SegmentValidationError(QStringLiteral("%1 start is required").arg(name));
    }
    const int start = *draft.startMs;
    assertTimestampBounds(start);

    if (draft.segment == SegmentType::Credits && start != 0 && start < kMinDurationMs) {
        throw SegmentValidationError(
            QStringLiteral("Credits start must be 0 or at least %1s").arg(kMinDurationMs / 1000));
    }

    std::optional<int> end = draft.endMs;
    // Credits that run to the end of the file need not be marked explicitly.
    if (!end.has_value() && draft.segment == SegmentType::Credits
        && draft.videoDurationMs.has_value()) {
        end = draft.videoDurationMs;
    }

    if (end.has_value()) {
        assertTimestampBounds(*end);
        if (*end <= start) {
            throw SegmentValidationError(QStringLiteral("End must be greater than start"));
        }

        const int duration = *end - start;
        if (duration < kMinDurationMs || duration > maxDurationMs) {
            throw SegmentValidationError(
                QStringLiteral("%1 duration must be between %2s and %3s")
                    .arg(name)
                    .arg(kMinDurationMs / 1000)
                    .arg(maxDurationMs / 1000));
        }
    }

    return ValidatedRange{start, end};
}

SegmentValidator::ValidatedRange SegmentValidator::validateDraftRange(const SubmissionDraft &draft)
{
    switch (draft.segment) {
    case SegmentType::Intro:
        return validateIntroOrRecap(draft, kMaxIntroDurationMs);
    case SegmentType::Recap:
        return validateIntroOrRecap(draft, kMaxRecapDurationMs);
    case SegmentType::Credits:
        return validateCreditsOrPreview(draft, kMaxCreditsDurationMs);
    case SegmentType::Preview:
        return validateCreditsOrPreview(draft, kMaxPreviewDurationMs);
    }
    throw SegmentValidationError(QStringLiteral("Unknown segment type"));
}

QJsonObject SegmentValidator::makeTheIntroDbSubmissionRequest(const SubmissionDraft &draft)
{
    const QString imdbId = normalizeImdb(draft.imdbId);
    const bool hasTmdb = draft.tmdbId > 0;
    const bool hasImdb = !imdbId.isEmpty() && isValidImdb(imdbId);

    if (!hasTmdb && !hasImdb) {
        throw SegmentValidationError(
            QStringLiteral("At least TMDB ID or a valid IMDB ID must be provided"));
    }

    if (draft.mediaType == MediaType::Movie) {
        if (draft.season.has_value() || draft.episode.has_value()) {
            throw SegmentValidationError(
                QStringLiteral("Season and episode must be empty for movie submissions"));
        }
    } else {
        if (!draft.season.has_value() || *draft.season <= 0
            || !draft.episode.has_value() || *draft.episode <= 0) {
            throw SegmentValidationError(
                QStringLiteral("Season and episode are required for TV submissions"));
        }
    }

    const ValidatedRange range = validateDraftRange(draft);

    QJsonObject payload;
    payload.insert(QStringLiteral("type"), mediaTypeApiValue(draft.mediaType));
    payload.insert(QStringLiteral("segment"), segmentTypeApiValue(draft.segment));
    payload.insert(QStringLiteral("start_ms"), range.startMs);

    // An explicit null rather than an omitted key: the v3 API distinguishes
    // "no TMDB id" from "field absent" when reconciling against IMDB.
    payload.insert(QStringLiteral("tmdb_id"),
                   hasTmdb ? QJsonValue(draft.tmdbId) : QJsonValue(QJsonValue::Null));

    // Season and episode go up as strings — the v3 API rejects them as numbers.
    if (draft.season.has_value()) {
        payload.insert(QStringLiteral("season"), QString::number(*draft.season));
    }
    if (draft.episode.has_value()) {
        payload.insert(QStringLiteral("episode"), QString::number(*draft.episode));
    }
    if (range.endMs.has_value()) {
        payload.insert(QStringLiteral("end_ms"), *range.endMs);
    }
    if (!imdbId.isEmpty()) {
        payload.insert(QStringLiteral("imdb_id"), imdbId);
    }
    if (draft.videoDurationMs.has_value()) {
        payload.insert(QStringLiteral("video_duration_ms"), *draft.videoDurationMs);
    }

    return payload;
}

QJsonObject SegmentValidator::makeIntroDbSubmissionRequest(const SubmissionDraft &draft)
{
    if (draft.mediaType != MediaType::Tv) {
        throw SegmentValidationError(QStringLiteral("IntroDB supports TV episodes only"));
    }

    const QString imdbId = normalizeImdb(draft.imdbId);
    if (imdbId.isEmpty() || !isValidImdb(imdbId)) {
        throw SegmentValidationError(
            QStringLiteral("Valid IMDB ID is required for IntroDB uploads"));
    }

    if (!draft.season.has_value() || *draft.season <= 0
        || !draft.episode.has_value() || *draft.episode <= 0) {
        throw SegmentValidationError(
            QStringLiteral("Season and episode are required for IntroDB uploads"));
    }

    const QString introdbSegment = toIntroDbSegmentType(draft.segment);
    if (introdbSegment.isEmpty()) {
        throw SegmentValidationError(
            QStringLiteral("IntroDB does not support %1 uploads")
                .arg(segmentTypeDisplayName(draft.segment)));
    }

    const ValidatedRange range = validateDraftRange(draft);
    if (!range.endMs.has_value()) {
        throw SegmentValidationError(
            QStringLiteral("IntroDB requires an explicit end timestamp"));
    }

    QJsonObject payload;
    payload.insert(QStringLiteral("segment_type"), introdbSegment);
    payload.insert(QStringLiteral("imdb_id"), imdbId);
    payload.insert(QStringLiteral("season"), *draft.season);
    payload.insert(QStringLiteral("episode"), *draft.episode);
    payload.insert(QStringLiteral("start_sec"), static_cast<double>(range.startMs) / 1000.0);
    payload.insert(QStringLiteral("end_sec"), static_cast<double>(*range.endMs) / 1000.0);
    payload.insert(QStringLiteral("tvdb_id"), QJsonValue(QJsonValue::Null));
    payload.insert(QStringLiteral("tmdb_id"),
                   draft.tmdbId > 0 ? QJsonValue(draft.tmdbId) : QJsonValue(QJsonValue::Null));

    return payload;
}

} // namespace segmenter
