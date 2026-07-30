#include "services/RcdFeatureCache.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutexLocker>
#include <QStandardPaths>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

QJsonArray toJsonArray(const QVector<float> &values)
{
    QJsonArray array;
    for (const float value : values) {
        array.append(static_cast<double>(value));
    }
    return array;
}

QVector<float> fromJsonArray(const QJsonArray &array)
{
    QVector<float> values;
    values.reserve(array.size());
    for (const QJsonValue &value : array) {
        values.append(static_cast<float>(value.toDouble()));
    }
    return values;
}

} // namespace

RcdFeatureCache &RcdFeatureCache::instance()
{
    static RcdFeatureCache cache;
    return cache;
}

RcdFeatureCache::RcdFeatureCache()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    m_cacheDirectory = QDir(base).filePath(QStringLiteral("rcd-features"));
    QDir().mkpath(m_cacheDirectory);
}

std::optional<RcdFeatureCache::FileStamp> RcdFeatureCache::fileStamp(const QString &filePath)
{
    const QFileInfo info(filePath);
    if (!info.exists() || !info.isFile()) {
        return std::nullopt;
    }

    FileStamp stamp;
    stamp.sizeBytes = info.size();
    stamp.modifiedMsSinceEpoch = info.lastModified().toMSecsSinceEpoch();
    return stamp;
}

QString RcdFeatureCache::cacheKey(const QString &filePath)
{
    // Hash the path rather than sanitising it: episode filenames routinely
    // carry characters that are illegal in a filename on some volume or other,
    // and a fixed-length key sidesteps MAX_PATH on deep season folders.
    const QByteArray digest =
        QCryptographicHash::hash(QDir::toNativeSeparators(filePath).toUtf8(),
                                 QCryptographicHash::Sha256);
    return QString::fromLatin1(digest.toHex());
}

std::optional<RcdFeatureCache::CacheEntry> RcdFeatureCache::readFromDisk(const QString &key) const
{
    QFile file(QDir(m_cacheDirectory).filePath(key + QStringLiteral(".json")));
    if (!file.open(QIODevice::ReadOnly)) {
        return std::nullopt;
    }

    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    if (!document.isObject()) {
        return std::nullopt;
    }

    const QJsonObject root = document.object();
    if (root.value(QStringLiteral("version")).toInt() != kFeatureVersion) {
        return std::nullopt;
    }

    CacheEntry entry;
    entry.version = kFeatureVersion;
    entry.stamp.sizeBytes =
        static_cast<qint64>(root.value(QStringLiteral("sizeBytes")).toDouble());
    entry.stamp.modifiedMsSinceEpoch =
        static_cast<qint64>(root.value(QStringLiteral("modifiedMs")).toDouble());

    entry.features.introFeatures =
        fromJsonArray(root.value(QStringLiteral("introFeatures")).toArray());
    entry.features.creditsFeatures =
        fromJsonArray(root.value(QStringLiteral("creditsFeatures")).toArray());
    entry.features.durationSec = root.value(QStringLiteral("durationSec")).toInt();
    entry.features.introRegionSec = root.value(QStringLiteral("introRegionSec")).toInt();
    entry.features.creditsRegionSec = root.value(QStringLiteral("creditsRegionSec")).toInt();

    // A v3 entry without region sizes cannot be used: the credits offset is
    // converted back to absolute time using this episode's own region length,
    // so a missing value would silently place the segment at the wrong point.
    if (entry.features.introRegionSec <= 0 || entry.features.creditsRegionSec <= 0) {
        return std::nullopt;
    }

    return entry;
}

void RcdFeatureCache::writeToDisk(const QString &key, const CacheEntry &entry) const
{
    QJsonObject root;
    root.insert(QStringLiteral("version"), entry.version);
    root.insert(QStringLiteral("sizeBytes"), static_cast<double>(entry.stamp.sizeBytes));
    root.insert(QStringLiteral("modifiedMs"), static_cast<double>(entry.stamp.modifiedMsSinceEpoch));
    root.insert(QStringLiteral("introFeatures"), toJsonArray(entry.features.introFeatures));
    root.insert(QStringLiteral("creditsFeatures"), toJsonArray(entry.features.creditsFeatures));
    root.insert(QStringLiteral("durationSec"), entry.features.durationSec);
    root.insert(QStringLiteral("introRegionSec"), entry.features.introRegionSec);
    root.insert(QStringLiteral("creditsRegionSec"), entry.features.creditsRegionSec);

    QFile file(QDir(m_cacheDirectory).filePath(key + QStringLiteral(".json")));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        LoggerService::instance().warn(
            QStringLiteral("[RcdFeatureCache] could not write %1").arg(file.fileName()));
        return;
    }
    file.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

std::optional<RcdFeatureCache::FeatureSet> RcdFeatureCache::features(const QString &filePath)
{
    const std::optional<FileStamp> stamp = fileStamp(filePath);
    if (!stamp.has_value()) {
        return std::nullopt;
    }

    const QString key = cacheKey(filePath);

    {
        QMutexLocker locker(&m_mutex);
        const auto it = m_memoryCache.constFind(key);
        if (it != m_memoryCache.constEnd() && it->stamp == *stamp) {
            return it->features;
        }
    }

    const std::optional<CacheEntry> entry = readFromDisk(key);
    if (!entry.has_value() || !(entry->stamp == *stamp)) {
        return std::nullopt;
    }

    {
        QMutexLocker locker(&m_mutex);
        m_memoryCache.insert(key, *entry);
    }
    return entry->features;
}

void RcdFeatureCache::store(const FeatureSet &features, const QString &filePath)
{
    const std::optional<FileStamp> stamp = fileStamp(filePath);
    if (!stamp.has_value()) {
        return;
    }

    CacheEntry entry;
    entry.version = kFeatureVersion;
    entry.stamp = *stamp;
    entry.features = features;

    const QString key = cacheKey(filePath);
    {
        QMutexLocker locker(&m_mutex);
        m_memoryCache.insert(key, entry);
    }
    writeToDisk(key, entry);
}

void RcdFeatureCache::clear()
{
    {
        QMutexLocker locker(&m_mutex);
        m_memoryCache.clear();
    }

    QDir directory(m_cacheDirectory);
    const QFileInfoList entries =
        directory.entryInfoList(QStringList{QStringLiteral("*.json")}, QDir::Files);
    for (const QFileInfo &entry : entries) {
        QFile::remove(entry.absoluteFilePath());
    }

    LoggerService::instance().info(
        QStringLiteral("[RcdFeatureCache] cleared %1 cached feature set(s)").arg(entries.size()));
}

} // namespace segmenter
