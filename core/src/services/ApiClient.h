#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QVector>

#include "models/Models.h"

namespace segmenter {

/// Outcome of one HTTP call. Every client method returns this rather than
/// throwing: the callers are worker threads feeding a status bar, and an error
/// string is what they need to display.
struct ApiResponse {
    bool ok = false;
    QJsonObject json;
    QJsonArray jsonArray;
    UsageHeaders usage;
    QString error;
    int httpStatus = 0;
};

/// TheIntroDB v3 (https://api.theintrodb.org/v3).
///
/// Calls block the calling thread — run them from a worker. A shared rate-limit
/// gate makes a caller wait when the previous response reported no remaining
/// quota, rather than firing requests that are certain to come back 429.
class TheIntroDbClient {
public:
    static TheIntroDbClient &instance();

    ApiResponse fetchMedia(const MediaQuery &query, const QString &apiKey);
    ApiResponse submit(const QJsonObject &requestBody, const QString &apiKey);

private:
    TheIntroDbClient() = default;
    QString m_baseUrl = QStringLiteral("https://api.theintrodb.org/v3");
};

/// IntroDB (https://api.introdb.app). TV episodes only.
class IntroDbClient {
public:
    static IntroDbClient &instance();

    ApiResponse fetchSegments(const QString &imdbId, int season, int episode,
                              const QString &apiKey);
    ApiResponse submit(const QJsonObject &requestBody, const QString &apiKey);

private:
    IntroDbClient() = default;
    QString m_baseUrl = QStringLiteral("https://api.introdb.app");
};

/// TMDB (https://api.themoviedb.org/3), for title/season/episode resolution.
///
/// Accepts both credential shapes: a v3 API key goes in the `api_key` query
/// parameter, a v4 Read Access Token goes in an Authorization: Bearer header.
/// Which one the user pasted is decided by shape, not by a setting.
class TmdbClient {
public:
    static TmdbClient &instance();

    QVector<AutoLookupResult> searchByTitle(const QString &query,
                                            MediaType mediaType,
                                            const QString &apiKey,
                                            QString *errorOut = nullptr);

    /// Title and IMDB id for a known TMDB id.
    bool fetchByTmdbId(int tmdbId, MediaType mediaType, const QString &apiKey,
                       QString *titleOut, QString *imdbIdOut);

    /// Best-effort resolution of a parsed filename, carrying the season and
    /// episode from the hint onto each result.
    QVector<AutoLookupResult> resolveHints(const ParsedFilenameHint &hint,
                                           const QString &apiKey,
                                           int limit = 6);

    static QString posterUrl(const QString &posterPath);

private:
    TmdbClient() = default;

    /// Fills in the IMDB ids the search endpoint does not return, which
    /// IntroDB uploads require. One extra request per result, so it is capped
    /// by the caller's `limit`.
    void enrichWithImdbIds(QVector<AutoLookupResult> &results,
                           MediaType mediaType,
                           const QString &apiKey);

    QString m_baseUrl = QStringLiteral("https://api.themoviedb.org/3");
};

} // namespace segmenter
