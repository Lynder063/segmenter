#pragma once

#include <QString>

#include "models/Models.h"

namespace segmenter {

/// Pulls a show title, year, season and episode out of a release filename so
/// the TMDB lookup can be pre-filled. Direct port of the macOS
/// FilenameMediaParser — same three patterns, same order of operations.
class FilenameMediaParser {
public:
    static ParsedFilenameHint parse(const QString &filePathOrName);
};

} // namespace segmenter
