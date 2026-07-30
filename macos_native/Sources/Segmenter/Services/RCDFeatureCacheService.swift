import Foundation
import CryptoKit

/// Caches extracted chroma feature vectors (intro + credits regions) per video file on disk,
/// keyed by file path + size + modification date. Re-running a season scan (different method,
/// threshold, or one new episode dropped into the folder) previously re-decoded and re-FFT'd
/// every episode from scratch — the expensive, purely deterministic part of RCD scanning.
/// Only the correlation/matching step actually needs to rerun.
public actor RCDFeatureCacheService {
    public static let shared = RCDFeatureCacheService()

    public struct FeatureSet: Sendable {
        public let introFeatures: [Float]
        public let creditsFeatures: [Float]
        public let durationSec: Int
        public let introRegionSec: Int
        public let creditsRegionSec: Int
    }

    /// Bump whenever the extraction parameters or chroma feature layout change (sample rate,
    /// FFT/hop size, bin count, or the intro/credits region lengths). Cached vectors are only
    /// comparable to vectors produced by the same pipeline — without this, changing e.g. the
    /// intro window length would silently reuse features extracted under the old settings.
    private static let featureVersion = 3

    private struct CacheEntry: Codable {
        let fileSize: Int64
        let modifiedAt: TimeInterval
        let introFeatures: [Float]
        let creditsFeatures: [Float]
        let durationSec: Int
        /// Optional so entries written before versioning existed decode cleanly — and are then
        /// rejected as stale by the version check.
        let featureVersion: Int?
        let introRegionSec: Int?
        let creditsRegionSec: Int?
    }

    private let cacheDirectory: URL
    private var memoryCache: [String: CacheEntry] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        cacheDirectory = base.appendingPathComponent("Segmenter/RCDFeatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func features(for url: URL) -> FeatureSet? {
        guard let stamp = fileStamp(for: url) else { return nil }
        let key = cacheKey(for: url)

        if let cached = memoryCache[key], matches(cached, stamp) {
            return featureSet(from: cached)
        }

        let onDiskURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: onDiskURL),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              matches(entry, stamp) else {
            return nil
        }

        // Treat an empty entry as a cache miss and delete it, so a cache poisoned by an earlier
        // failed run (e.g. before ffmpeg was installed) self-heals instead of persisting forever.
        guard !entry.introFeatures.isEmpty || !entry.creditsFeatures.isEmpty else {
            LoggerService.shared.warn("[RCDFeatureCache] Discarding empty cached entry for \(url.lastPathComponent) — will re-extract")
            try? FileManager.default.removeItem(at: onDiskURL)
            memoryCache.removeValue(forKey: key)
            return nil
        }

        memoryCache[key] = entry
        return featureSet(from: entry)
    }

    /// Region lengths are optional in the on-disk schema; the version check already rejects
    /// entries that predate them, so a nil here means a corrupt entry rather than an old one.
    private func featureSet(from entry: CacheEntry) -> FeatureSet? {
        guard let introRegion = entry.introRegionSec, let creditsRegion = entry.creditsRegionSec else { return nil }
        return FeatureSet(
            introFeatures: entry.introFeatures,
            creditsFeatures: entry.creditsFeatures,
            durationSec: entry.durationSec,
            introRegionSec: introRegion,
            creditsRegionSec: creditsRegion
        )
    }

    public func store(_ features: FeatureSet, for url: URL) {
        // Never persist a failed extraction. extractFeatureVector() returns an empty array when
        // ffmpeg is missing or the decode fails; caching that would poison the entry permanently,
        // because later runs would "reuse" the empty features and silently find nothing forever.
        guard !features.introFeatures.isEmpty || !features.creditsFeatures.isEmpty else {
            LoggerService.shared.warn("[RCDFeatureCache] Refusing to cache empty features for \(url.lastPathComponent) — extraction likely failed")
            return
        }
        guard let stamp = fileStamp(for: url) else { return }
        let entry = CacheEntry(
            fileSize: stamp.fileSize,
            modifiedAt: stamp.modifiedAt,
            introFeatures: features.introFeatures,
            creditsFeatures: features.creditsFeatures,
            durationSec: features.durationSec,
            featureVersion: Self.featureVersion,
            introRegionSec: features.introRegionSec,
            creditsRegionSec: features.creditsRegionSec
        )
        let key = cacheKey(for: url)
        memoryCache[key] = entry

        guard let data = try? JSONEncoder().encode(entry) else { return }
        let onDiskURL = cacheDirectory.appendingPathComponent("\(key).json")
        try? data.write(to: onDiskURL, options: [.atomic])
    }

    // MARK: - Private

    private struct FileStamp {
        let fileSize: Int64
        let modifiedAt: TimeInterval
    }

    private func fileStamp(for url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let size: Int64
        if let sizeInt64 = attrs[.size] as? Int64 {
            size = sizeInt64
        } else if let sizeInt = attrs[.size] as? Int {
            size = Int64(sizeInt)
        } else {
            return nil
        }
        return FileStamp(fileSize: size, modifiedAt: modDate.timeIntervalSince1970)
    }

    private func matches(_ entry: CacheEntry, _ stamp: FileStamp) -> Bool {
        entry.featureVersion == Self.featureVersion
            && entry.fileSize == stamp.fileSize
            && entry.modifiedAt == stamp.modifiedAt
    }

    /// SHA256 of the absolute path — must be stable across process launches, unlike
    /// String.hashValue (which is randomly seeded per-process and would silently miss
    /// every cache entry on the next app launch).
    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
