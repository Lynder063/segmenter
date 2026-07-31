#include "models/Models.h"

#include <QRegularExpression>
#include <QStringList>

namespace segmenter {

// MARK: - Media Type

QString mediaTypeApiValue(MediaType type)
{
    switch (type) {
    case MediaType::Movie: return QStringLiteral("movie");
    case MediaType::Tv:    return QStringLiteral("tv");
    }
    return QStringLiteral("movie");
}

QString mediaTypeDisplayName(MediaType type)
{
    switch (type) {
    case MediaType::Movie: return QStringLiteral("Movie");
    case MediaType::Tv:    return QStringLiteral("TV Show");
    }
    return QStringLiteral("Movie");
}

std::optional<MediaType> mediaTypeFromApiValue(const QString &value)
{
    const QString normalized = value.trimmed().toLower();
    if (normalized == QLatin1String("movie")) return MediaType::Movie;
    if (normalized == QLatin1String("tv"))    return MediaType::Tv;
    return std::nullopt;
}

// MARK: - Segment Type

const QVector<SegmentType> &allSegmentTypes()
{
    static const QVector<SegmentType> types = {
        SegmentType::Intro,
        SegmentType::Recap,
        SegmentType::Credits,
        SegmentType::Preview,
    };
    return types;
}

QString segmentTypeApiValue(SegmentType type)
{
    switch (type) {
    case SegmentType::Intro:   return QStringLiteral("intro");
    case SegmentType::Recap:   return QStringLiteral("recap");
    case SegmentType::Credits: return QStringLiteral("credits");
    case SegmentType::Preview: return QStringLiteral("preview");
    }
    return QStringLiteral("intro");
}

QString segmentTypeDisplayName(SegmentType type)
{
    switch (type) {
    case SegmentType::Intro:   return QStringLiteral("Intro");
    case SegmentType::Recap:   return QStringLiteral("Recap");
    case SegmentType::Credits: return QStringLiteral("Credits");
    case SegmentType::Preview: return QStringLiteral("Preview");
    }
    return QStringLiteral("Intro");
}

std::optional<SegmentType> segmentTypeFromApiValue(const QString &value)
{
    const QString normalized = value.trimmed().toLower();
    if (normalized == QLatin1String("intro"))   return SegmentType::Intro;
    if (normalized == QLatin1String("recap"))   return SegmentType::Recap;
    if (normalized == QLatin1String("credits")) return SegmentType::Credits;
    if (normalized == QLatin1String("preview")) return SegmentType::Preview;
    return std::nullopt;
}

QString segmentTypeHexColor(SegmentType type)
{
    switch (type) {
    case SegmentType::Intro:   return QStringLiteral("#007AFF");
    case SegmentType::Recap:   return QStringLiteral("#FF9500");
    case SegmentType::Credits: return QStringLiteral("#34C759");
    case SegmentType::Preview: return QStringLiteral("#FF2D55");
    }
    return QStringLiteral("#007AFF");
}

QColor segmentTypeColor(SegmentType type)
{
    return QColor(segmentTypeHexColor(type));
}

// MARK: - Usage Headers

QString UsageHeaders::shortDescription() const
{
    QStringList chunks;
    if (rateRemaining.has_value() && rateLimit.has_value()) {
        chunks << QStringLiteral("rate %1/%2").arg(*rateRemaining).arg(*rateLimit);
    }
    if (usageRemaining.has_value() && usageLimit.has_value()) {
        chunks << QStringLiteral("usage %1/%2").arg(*usageRemaining).arg(*usageLimit);
    }
    return chunks.isEmpty() ? QStringLiteral("No limit headers")
                            : chunks.join(QStringLiteral(" • "));
}

// MARK: - Auto Lookup Result

QString AutoLookupResult::displayLabel() const
{
    QString label = title;
    if (matchedYear.has_value()) {
        label += QStringLiteral(" (%1)").arg(*matchedYear);
    }
    if (season.has_value() && episode.has_value()) {
        label += QStringLiteral(" — S%1E%2")
                     .arg(*season, 2, 10, QLatin1Char('0'))
                     .arg(*episode, 2, 10, QLatin1Char('0'));
    }
    return label;
}

// MARK: - RCD Detection Method

const QVector<RcdDetectionMethod> &allRcdDetectionMethods()
{
    static const QVector<RcdDetectionMethod> methods = {
        RcdDetectionMethod::HardwareAccelerated,
        RcdDetectionMethod::ChromaprintFft,
        RcdDetectionMethod::MultimodalFusion,
        RcdDetectionMethod::SingleEpisode,
    };
    return methods;
}

QString rcdMethodDisplayName(RcdDetectionMethod method)
{
    switch (method) {
    case RcdDetectionMethod::HardwareAccelerated:
        // Not platform-specific text on purpose — this label is shared by
        // Windows (Windows.Media.Ocr) and Linux (Tesseract) alike.
        return QStringLiteral("HW Accelerated (SIMD FFT + OCR)");
    case RcdDetectionMethod::ChromaprintFft:
        return QStringLiteral("Chromaprint 12-Bin Pitch Chromagram (AcoustID)");
    case RcdDetectionMethod::MultimodalFusion:
        // Same platform-neutral wording as HardwareAccelerated above — "Vision"
        // here would misleadingly suggest Apple's framework specifically.
        return QStringLiteral("Multimodal Fusion (Audio Chroma + OCR)");
    case RcdDetectionMethod::SingleEpisode:
        return QStringLiteral("Single Episode (Standalone — No Season Folder)");
    }
    return QString();
}

QString rcdMethodDescription(RcdDetectionMethod method)
{
    switch (method) {
    case RcdDetectionMethod::HardwareAccelerated:
        return QStringLiteral(
            "Chromaprint 12-bin pitch chromagram cross-correlation across episodes, "
            "combined with on-screen text density and black-frame visual snapping.");
    case RcdDetectionMethod::ChromaprintFft:
        return QStringLiteral(
            "Pure acoustical pitch class profile cross-correlation. No visual pass — "
            "fastest option, and the only one that never extracts video frames.");
    case RcdDetectionMethod::MultimodalFusion:
        return QStringLiteral(
            "Dual score fusion: 60% audio chroma correlation, 40% on-screen text "
            "detection. Best at telling closing credits apart from a next-episode preview.");
    case RcdDetectionMethod::SingleEpisode:
        return QStringLiteral(
            "Structural analysis of one file: locates the longest sustained run of "
            "music-like audio near the start and end. Needs no sibling episodes, but "
            "is less precise than a full season scan.");
    }
    return QString();
}

bool rcdMethodNeedsSeasonFolder(RcdDetectionMethod method)
{
    return method != RcdDetectionMethod::SingleEpisode;
}

// MARK: - Time formatting

QString formatTimecode(int milliseconds)
{
    const int clamped = std::max(0, milliseconds);
    const int totalSeconds = clamped / 1000;
    const int ms = clamped % 1000;
    const int hours = totalSeconds / 3600;
    const int minutes = (totalSeconds % 3600) / 60;
    const int seconds = totalSeconds % 60;

    if (hours > 0) {
        return QStringLiteral("%1:%2:%3.%4")
            .arg(hours)
            .arg(minutes, 2, 10, QLatin1Char('0'))
            .arg(seconds, 2, 10, QLatin1Char('0'))
            .arg(ms, 3, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2.%3")
        .arg(minutes, 2, 10, QLatin1Char('0'))
        .arg(seconds, 2, 10, QLatin1Char('0'))
        .arg(ms, 3, 10, QLatin1Char('0'));
}

std::optional<int> parseTimecode(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty() || trimmed == QLatin1String("--")) {
        return std::nullopt;
    }

    // Bare millisecond count, e.g. pasted straight out of an API response.
    bool plainOk = false;
    const int plain = trimmed.toInt(&plainOk);
    if (plainOk) {
        return std::max(0, plain);
    }

    // [HH:]MM:SS[.mmm]
    static const QRegularExpression pattern(
        QStringLiteral(R"(^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$)"));
    const QRegularExpressionMatch match = pattern.match(trimmed);
    if (!match.hasMatch()) {
        return std::nullopt;
    }

    const int hours = match.captured(1).isEmpty() ? 0 : match.captured(1).toInt();
    const int minutes = match.captured(2).toInt();
    const int seconds = match.captured(3).toInt();

    QString fraction = match.captured(4);
    // ".5" means 500 ms, not 5 ms.
    while (fraction.length() < 3 && !fraction.isEmpty()) {
        fraction.append(QLatin1Char('0'));
    }
    const int ms = fraction.isEmpty() ? 0 : fraction.toInt();

    return ((hours * 3600) + (minutes * 60) + seconds) * 1000 + ms;
}

} // namespace segmenter
