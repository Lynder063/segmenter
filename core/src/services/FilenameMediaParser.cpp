#include "services/FilenameMediaParser.h"

#include <QFileInfo>
#include <QRegularExpression>

namespace segmenter {
namespace {

// "S01E02", "Season 1 Episode 2", "1x02".
const QRegularExpression &tvPattern()
{
    static const QRegularExpression pattern(
        QStringLiteral(R"((?:s|season\s*)(\d{1,2})[\s._-]*[ex](\d{1,3})|(\d{1,2})x(\d{1,3}))"),
        QRegularExpression::CaseInsensitiveOption);
    return pattern;
}

const QRegularExpression &yearPattern()
{
    static const QRegularExpression pattern(QStringLiteral(R"(\b(19\d{2}|20\d{2})\b)"));
    return pattern;
}

// Release-group and encoding tags that would otherwise end up in the title.
const QRegularExpression &junkPattern()
{
    static const QRegularExpression pattern(
        QStringLiteral(R"(\b(1080p|720p|4k|2160p|bluray|webrip|web-dl|h264|h265|hevc|x264|x265|aac|dts|flac|mkv|mp4|avi)\b)"),
        QRegularExpression::CaseInsensitiveOption);
    return pattern;
}

} // namespace

ParsedFilenameHint FilenameMediaParser::parse(const QString &filePathOrName)
{
    const QString baseName = QFileInfo(filePathOrName).completeBaseName();

    ParsedFilenameHint hint;
    QString cleanTitle = baseName;

    const QRegularExpressionMatch tvMatch = tvPattern().match(baseName);
    if (tvMatch.hasMatch()) {
        if (!tvMatch.captured(1).isEmpty() && !tvMatch.captured(2).isEmpty()) {
            hint.season = tvMatch.captured(1).toInt();
            hint.episode = tvMatch.captured(2).toInt();
        } else if (!tvMatch.captured(3).isEmpty() && !tvMatch.captured(4).isEmpty()) {
            hint.season = tvMatch.captured(3).toInt();
            hint.episode = tvMatch.captured(4).toInt();
        }

        // Everything from the season marker onwards is release metadata.
        cleanTitle = baseName.left(tvMatch.capturedStart());
    }

    const QRegularExpressionMatch yearMatch = yearPattern().match(cleanTitle);
    if (yearMatch.hasMatch()) {
        hint.year = yearMatch.captured(1).toInt();
        cleanTitle = cleanTitle.left(yearMatch.capturedStart());
    }

    cleanTitle.remove(junkPattern());
    cleanTitle.replace(QLatin1Char('.'), QLatin1Char(' '));
    cleanTitle.replace(QLatin1Char('_'), QLatin1Char(' '));
    cleanTitle.replace(QLatin1Char('-'), QLatin1Char(' '));

    // Collapse the runs of spaces the substitutions above leave behind.
    static const QRegularExpression whitespaceRun(QStringLiteral(R"(\s+)"));
    cleanTitle.replace(whitespaceRun, QStringLiteral(" "));

    hint.title = cleanTitle.trimmed();
    return hint;
}

} // namespace segmenter
