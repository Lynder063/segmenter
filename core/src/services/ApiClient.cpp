#include "services/ApiClient.h"

#include <QDeadlineTimer>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMutex>
#include <QMutexLocker>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QThread>
#include <QUrlQuery>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

constexpr int kRequestTimeoutMs = 30000;

/// One manager per thread: QNetworkAccessManager is not thread-safe and must
/// live on the thread that drives its event loop.
QNetworkAccessManager &networkManager()
{
    static thread_local QNetworkAccessManager manager;
    return manager;
}

UsageHeaders parseUsageHeaders(QNetworkReply *reply)
{
    const auto headerInt = [reply](const QByteArray &name) -> std::optional<int> {
        if (!reply->hasRawHeader(name)) {
            return std::nullopt;
        }
        bool ok = false;
        const int value = reply->rawHeader(name).toInt(&ok);
        return ok ? std::optional<int>(value) : std::nullopt;
    };

    UsageHeaders usage;
    usage.rateLimit = headerInt("x-ratelimit-limit");
    usage.rateRemaining = headerInt("x-ratelimit-remaining");
    usage.rateResetSeconds = headerInt("x-ratelimit-reset");
    usage.usageLimit = headerInt("x-usagelimit-limit");
    usage.usageRemaining = headerInt("x-usagelimit-remaining");
    usage.usageResetSeconds = headerInt("x-usagelimit-reset");
    return usage;
}

/// Shared across every client: a 429 from one endpoint means the account is
/// throttled, not just that one call.
QMutex g_rateLimitMutex;
qint64 g_rateLimitedUntilMsSinceEpoch = 0;

void waitForRateLimit()
{
    qint64 waitUntil = 0;
    {
        QMutexLocker locker(&g_rateLimitMutex);
        waitUntil = g_rateLimitedUntilMsSinceEpoch;
    }

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (waitUntil > now) {
        const qint64 sleepMs = std::min<qint64>(waitUntil - now, 60000);
        LoggerService::instance().info(
            QStringLiteral("[ApiClient] rate limited; waiting %1 ms").arg(sleepMs));
        QThread::msleep(static_cast<unsigned long>(sleepMs));
    }
}

void updateRateLimit(const UsageHeaders &usage)
{
    if (!usage.rateRemaining.has_value() || *usage.rateRemaining > 0) {
        return;
    }
    // Quota is spent. Hold every caller off until the reset the server named,
    // defaulting to a minute when it did not send one.
    const int resetSeconds = usage.rateResetSeconds.value_or(60);
    QMutexLocker locker(&g_rateLimitMutex);
    g_rateLimitedUntilMsSinceEpoch =
        QDateTime::currentMSecsSinceEpoch() + static_cast<qint64>(resetSeconds) * 1000;
}

/// Runs a request to completion on the calling thread.
ApiResponse performRequest(QNetworkRequest request,
                           const QByteArray &verb,
                           const QByteArray &body = {})
{
    ApiResponse response;

    request.setTransferTimeout(kRequestTimeoutMs);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("Segmenter/%1 (Windows)").arg(QStringLiteral(SEGMENTER_VERSION)));

    QNetworkReply *reply = nullptr;
    if (verb == "POST") {
        reply = networkManager().post(request, body);
    } else {
        reply = networkManager().get(request);
    }

    // A nested event loop is what makes this call synchronous. Safe because
    // every caller is a worker thread with no widgets of its own.
    QEventLoop loop;
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    loop.exec();

    response.httpStatus =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    response.usage = parseUsageHeaders(reply);
    updateRateLimit(response.usage);

    const QByteArray payload = reply->readAll();
    const QNetworkReply::NetworkError networkError = reply->error();
    const QString networkErrorString = reply->errorString();
    reply->deleteLater();

    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(payload, &parseError);
    if (document.isObject()) {
        response.json = document.object();
    } else if (document.isArray()) {
        response.jsonArray = document.array();
    }

    if (networkError != QNetworkReply::NoError) {
        // Prefer the server's own message when it sent one — "Season is
        // required for TV submissions" beats "Error transferring …".
        const QString serverMessage = response.json.value(QStringLiteral("message")).toString();
        const QString detail = response.json.value(QStringLiteral("detail")).toString();
        response.error = !serverMessage.isEmpty() ? serverMessage
                       : !detail.isEmpty()        ? detail
                                                  : networkErrorString;
        response.ok = false;
        LoggerService::instance().warn(
            QStringLiteral("[ApiClient] %1 %2 -> HTTP %3: %4")
                .arg(QString::fromUtf8(verb), request.url().toString())
                .arg(response.httpStatus)
                .arg(response.error));
        return response;
    }

    if (parseError.error != QJsonParseError::NoError && !payload.isEmpty()) {
        response.ok = false;
        response.error = QStringLiteral("Invalid JSON response");
        return response;
    }

    response.ok = true;
    return response;
}

void applyBearer(QNetworkRequest &request, const QString &apiKey)
{
    const QString trimmed = apiKey.trimmed();
    if (!trimmed.isEmpty()) {
        request.setRawHeader("Authorization", QStringLiteral("Bearer %1").arg(trimmed).toUtf8());
    }
}

/// TMDB v4 Read Access Tokens are JWTs; v3 keys are 32-character hex strings.
bool isTmdbBearerToken(const QString &key)
{
    return key.trimmed().startsWith(QLatin1String("eyJ"));
}

void applyTmdbAuth(QNetworkRequest &request, QUrlQuery &query, const QString &apiKey)
{
    const QString trimmed = apiKey.trimmed();
    if (isTmdbBearerToken(trimmed)) {
        request.setRawHeader("Authorization", QStringLiteral("Bearer %1").arg(trimmed).toUtf8());
    } else {
        query.addQueryItem(QStringLiteral("api_key"), trimmed);
    }
}

} // namespace

// MARK: - TheIntroDB v3

TheIntroDbClient &TheIntroDbClient::instance()
{
    static TheIntroDbClient client;
    return client;
}

ApiResponse TheIntroDbClient::fetchMedia(const MediaQuery &query, const QString &apiKey)
{
    waitForRateLimit();

    QUrl url(m_baseUrl + QStringLiteral("/media"));
    QUrlQuery params;
    if (query.tmdbId.has_value()) {
        params.addQueryItem(QStringLiteral("tmdb_id"), QString::number(*query.tmdbId));
    }
    if (!query.imdbId.trimmed().isEmpty()) {
        params.addQueryItem(QStringLiteral("imdb_id"), query.imdbId.trimmed());
    }
    if (query.season.has_value()) {
        params.addQueryItem(QStringLiteral("season"), QString::number(*query.season));
    }
    if (query.episode.has_value()) {
        params.addQueryItem(QStringLiteral("episode"), QString::number(*query.episode));
    }
    if (query.durationMs.has_value()) {
        params.addQueryItem(QStringLiteral("duration_ms"), QString::number(*query.durationMs));
    }
    url.setQuery(params);

    QNetworkRequest request(url);
    applyBearer(request, apiKey);

    return performRequest(request, "GET");
}

ApiResponse TheIntroDbClient::submit(const QJsonObject &requestBody, const QString &apiKey)
{
    waitForRateLimit();

    QNetworkRequest request{QUrl(m_baseUrl + QStringLiteral("/submit"))};
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    applyBearer(request, apiKey);

    LoggerService::instance().info(
        QStringLiteral("[TheIntroDbClient] POST %1/submit").arg(m_baseUrl));

    return performRequest(request, "POST",
                          QJsonDocument(requestBody).toJson(QJsonDocument::Compact));
}

// MARK: - IntroDB

IntroDbClient &IntroDbClient::instance()
{
    static IntroDbClient client;
    return client;
}

ApiResponse IntroDbClient::fetchSegments(const QString &imdbId, int season, int episode,
                                         const QString &apiKey)
{
    waitForRateLimit();

    QUrl url(m_baseUrl + QStringLiteral("/segments"));
    QUrlQuery params;
    params.addQueryItem(QStringLiteral("imdb_id"), imdbId.trimmed());
    params.addQueryItem(QStringLiteral("season"), QString::number(season));
    params.addQueryItem(QStringLiteral("episode"), QString::number(episode));
    url.setQuery(params);

    QNetworkRequest request(url);
    applyBearer(request, apiKey);

    return performRequest(request, "GET");
}

ApiResponse IntroDbClient::submit(const QJsonObject &requestBody, const QString &apiKey)
{
    waitForRateLimit();

    QNetworkRequest request{QUrl(m_baseUrl + QStringLiteral("/submit"))};
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    applyBearer(request, apiKey);

    LoggerService::instance().info(
        QStringLiteral("[IntroDbClient] POST %1/submit").arg(m_baseUrl));

    return performRequest(request, "POST",
                          QJsonDocument(requestBody).toJson(QJsonDocument::Compact));
}

// MARK: - TMDB

TmdbClient &TmdbClient::instance()
{
    static TmdbClient client;
    return client;
}

QString TmdbClient::posterUrl(const QString &posterPath)
{
    if (posterPath.isEmpty()) {
        return QString();
    }
    return QStringLiteral("https://image.tmdb.org/t/p/w185") + posterPath;
}

QVector<AutoLookupResult> TmdbClient::searchByTitle(const QString &query,
                                                    MediaType mediaType,
                                                    const QString &apiKey,
                                                    QString *errorOut)
{
    QVector<AutoLookupResult> results;

    if (apiKey.trimmed().isEmpty()) {
        if (errorOut) {
            *errorOut = QStringLiteral("TMDB API key missing");
        }
        return results;
    }

    const QString endpoint = (mediaType == MediaType::Movie)
                                 ? QStringLiteral("search/movie")
                                 : QStringLiteral("search/tv");

    QUrl url(m_baseUrl + QLatin1Char('/') + endpoint);
    QUrlQuery params;
    params.addQueryItem(QStringLiteral("query"), query.trimmed());
    params.addQueryItem(QStringLiteral("language"), QStringLiteral("en-US"));
    params.addQueryItem(QStringLiteral("include_adult"), QStringLiteral("false"));

    QNetworkRequest request;
    applyTmdbAuth(request, params, apiKey);
    url.setQuery(params);
    request.setUrl(url);

    const ApiResponse response = performRequest(request, "GET");
    if (!response.ok) {
        if (errorOut) {
            *errorOut = response.error;
        }
        return results;
    }

    const QJsonArray items = response.json.value(QStringLiteral("results")).toArray();
    for (const QJsonValue &value : items) {
        const QJsonObject item = value.toObject();

        AutoLookupResult result;
        result.tmdbId = item.value(QStringLiteral("id")).toInt();
        result.mediaType = mediaType;
        result.title = (mediaType == MediaType::Movie)
                           ? item.value(QStringLiteral("title")).toString()
                           : item.value(QStringLiteral("name")).toString();
        result.posterUrl = posterUrl(item.value(QStringLiteral("poster_path")).toString());

        const QString releaseDate = (mediaType == MediaType::Movie)
                                        ? item.value(QStringLiteral("release_date")).toString()
                                        : item.value(QStringLiteral("first_air_date")).toString();
        if (releaseDate.size() >= 4) {
            bool ok = false;
            const int year = releaseDate.left(4).toInt(&ok);
            if (ok) {
                result.matchedYear = year;
            }
        }

        if (result.tmdbId > 0 && !result.title.isEmpty()) {
            results.append(result);
        }
    }

    return results;
}

bool TmdbClient::fetchByTmdbId(int tmdbId, MediaType mediaType, const QString &apiKey,
                               QString *titleOut, QString *imdbIdOut)
{
    if (apiKey.trimmed().isEmpty() || tmdbId <= 0) {
        return false;
    }

    const QString endpoint = (mediaType == MediaType::Movie)
                                 ? QStringLiteral("movie/%1").arg(tmdbId)
                                 : QStringLiteral("tv/%1").arg(tmdbId);

    QUrl url(m_baseUrl + QLatin1Char('/') + endpoint);
    QUrlQuery params;
    params.addQueryItem(QStringLiteral("language"), QStringLiteral("en-US"));
    // Folding external_ids into the same call saves a second round trip; TV
    // records do not carry imdb_id at the top level the way movies do.
    params.addQueryItem(QStringLiteral("append_to_response"), QStringLiteral("external_ids"));

    QNetworkRequest request;
    applyTmdbAuth(request, params, apiKey);
    url.setQuery(params);
    request.setUrl(url);

    const ApiResponse response = performRequest(request, "GET");
    if (!response.ok) {
        return false;
    }

    if (titleOut) {
        *titleOut = (mediaType == MediaType::Movie)
                        ? response.json.value(QStringLiteral("title")).toString()
                        : response.json.value(QStringLiteral("name")).toString();
    }

    if (imdbIdOut) {
        QString imdbId = response.json.value(QStringLiteral("imdb_id")).toString();
        if (imdbId.isEmpty()) {
            imdbId = response.json.value(QStringLiteral("external_ids"))
                         .toObject()
                         .value(QStringLiteral("imdb_id"))
                         .toString();
        }
        *imdbIdOut = imdbId;
    }

    return true;
}

void TmdbClient::enrichWithImdbIds(QVector<AutoLookupResult> &results,
                                   MediaType mediaType,
                                   const QString &apiKey)
{
    for (AutoLookupResult &result : results) {
        QString title;
        QString imdbId;
        if (fetchByTmdbId(result.tmdbId, mediaType, apiKey, &title, &imdbId)) {
            result.imdbId = imdbId;
        }
    }
}

QVector<AutoLookupResult> TmdbClient::resolveHints(const ParsedFilenameHint &hint,
                                                   const QString &apiKey,
                                                   int limit)
{
    QVector<AutoLookupResult> results;
    if (hint.title.isEmpty()) {
        return results;
    }

    const MediaType mediaType = hint.mediaTypeHint();
    results = searchByTitle(hint.title, mediaType, apiKey);

    // A year parsed out of the filename is a strong signal; when it matches,
    // promote those candidates rather than filtering the rest away, because a
    // release year and a first-air year legitimately differ by one.
    if (hint.year.has_value()) {
        const int wanted = *hint.year;
        std::stable_sort(results.begin(), results.end(),
                         [wanted](const AutoLookupResult &a, const AutoLookupResult &b) {
                             const int distanceA = a.matchedYear.has_value()
                                 ? std::abs(*a.matchedYear - wanted) : 99;
                             const int distanceB = b.matchedYear.has_value()
                                 ? std::abs(*b.matchedYear - wanted) : 99;
                             return distanceA < distanceB;
                         });
    }

    if (results.size() > limit) {
        results.resize(limit);
    }

    for (AutoLookupResult &result : results) {
        result.season = hint.season;
        result.episode = hint.episode;
    }

    enrichWithImdbIds(results, mediaType, apiKey);
    return results;
}

} // namespace segmenter
