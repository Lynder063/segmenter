#pragma once

#include <QHash>
#include <QMutex>
#include <QString>
#include <QVector>

#include <optional>

namespace segmenter {

/// Two-level cache (memory, then disk) of the per-episode chroma feature
/// vectors an RCD scan extracts, ported from the macOS RCDFeatureCacheService.
///
/// Re-scanning a season with a different method or threshold, or after dropping
/// one new episode into the folder, then skips decode + FFT entirely for every
/// file that has not changed.
class RcdFeatureCache {
public:
    struct FeatureSet {
        QVector<float> introFeatures;
        QVector<float> creditsFeatures;
        int durationSec = 0;
        int introRegionSec = 0;
        int creditsRegionSec = 0;
    };

    static RcdFeatureCache &instance();

    /// Returns the cached features for `filePath`, or nullopt when nothing is
    /// cached, the file has changed since, or the entry predates the current
    /// feature layout.
    std::optional<FeatureSet> features(const QString &filePath);

    void store(const FeatureSet &features, const QString &filePath);

    /// Drops every entry, on disk and in memory. Exposed through the scan
    /// dialog so a user can force a clean re-extraction.
    void clear();

    QString cacheDirectory() const { return m_cacheDirectory; }

private:
    RcdFeatureCache();

    // Bumped whenever the chroma layout, sample rate, hop size or region sizing
    // changes — otherwise a stale entry silently feeds incompatible vectors
    // into the correlator. Kept in step with the macOS `featureVersion`.
    static constexpr int kFeatureVersion = 3;

    struct FileStamp {
        qint64 sizeBytes = 0;
        qint64 modifiedMsSinceEpoch = 0;

        bool operator==(const FileStamp &other) const {
            return sizeBytes == other.sizeBytes
                && modifiedMsSinceEpoch == other.modifiedMsSinceEpoch;
        }
    };

    struct CacheEntry {
        int version = kFeatureVersion;
        FileStamp stamp;
        FeatureSet features;
    };

    static std::optional<FileStamp> fileStamp(const QString &filePath);
    static QString cacheKey(const QString &filePath);

    std::optional<CacheEntry> readFromDisk(const QString &key) const;
    void writeToDisk(const QString &key, const CacheEntry &entry) const;

    QString m_cacheDirectory;
    mutable QMutex m_mutex;
    QHash<QString, CacheEntry> m_memoryCache;
};

} // namespace segmenter
