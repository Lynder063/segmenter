import Foundation

// Actor-isolated: previously a plain class with an unsynchronized mutable dictionary.
// Safe today only because every caller happened to run serially — but the RCD engine's
// audio extraction and Vision AI refinement are now parallelized (see RCDEngineService),
// so any shared mutable state they might touch needs real isolation, not a lucky accident.
public actor RCDCacheService {
    public static let shared = RCDCacheService()

    private var cache: [String: [RCDMatch]] = [:]
    private let fileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolvedURL = home.appendingPathComponent(".segmenter_rcd_cache.json")
        fileURL = resolvedURL

        // Inlined rather than calling the actor-isolated loadFromDisk(): a synchronous actor
        // initializer runs before actor isolation is established, so it can set stored
        // properties directly but can't call other isolated instance methods.
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return }
        do {
            let data = try Data(contentsOf: resolvedURL)
            cache = try JSONDecoder().decode([String: [RCDMatch]].self, from: data)
            LoggerService.shared.info("[RCDCache] Loaded \(cache.count) cached episode RCD matches from disk")
        } catch {
            LoggerService.shared.warn("[RCDCache] Failed to load cache from disk: \(error)")
        }
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
}
