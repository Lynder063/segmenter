import Foundation

public final class RCDCacheService {
    public static let shared = RCDCacheService()

    private var cache: [String: [RCDMatch]] = [:]
    private let fileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appendingPathComponent(".segmenter_rcd_cache.json")
        loadFromDisk()
    }

    public func saveResults(_ results: [String: [RCDMatch]]) {
        for (filename, matches) in results {
            cache[filename] = matches
        }
        saveToDisk()
        LoggerService.shared.info("[RCDCache] Saved RCD scan results for \(results.count) episodes to cache")
    }

    public func getMatches(forFilename filename: String) -> [RCDMatch]? {
        // Direct match
        if let matches = cache[filename], !matches.isEmpty {
            return matches
        }
        // Case-insensitive / normalized match
        let lowerName = filename.lowercased()
        for (cachedKey, matches) in cache {
            if cachedKey.lowercased() == lowerName {
                return matches
            }
        }
        return nil
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: fileURL, options: [.atomic])
        } catch {

            LoggerService.shared.warn("[RCDCache] Failed to persist cache to disk: \(error)")
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            cache = try JSONDecoder().decode([String: [RCDMatch]].self, from: data)
            LoggerService.shared.info("[RCDCache] Loaded \(cache.count) cached episode RCD matches from disk")
        } catch {
            LoggerService.shared.warn("[RCDCache] Failed to load cache from disk: \(error)")
        }
    }
}
