import Foundation

public enum APIClientError: LocalizedError {
    case httpError(statusCode: Int?, message: String, usage: UsageHeaders?)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg, _):
            if let c = code {
                return "HTTP \(c): \(msg)"
            }
            return msg
        case .requestFailed(let msg):
            return "Request failed: \(msg)"
        }
    }
}

// MARK: - TheIntroDB Client
public actor TheIntroDBClient {
    private let baseURL: String
    private var lastRateLimitReset: TimeInterval = 0
    private var rateLimitRemaining: Int = 9999

    public init(baseURL: String = "https://api.theintrodb.org/v3") {
        self.baseURL = baseURL
    }

    private func waitForRateLimit() async {
        let now = Date().timeIntervalSince1970
        let timeUntilReset = lastRateLimitReset - now
        if rateLimitRemaining <= 1 && timeUntilReset > 0 {
            LoggerService.shared.warn("[TheIntroDBClient] Rate limit hit. Waiting \(String(format: "%.1f", timeUntilReset))s...")
            try? await Task.sleep(nanoseconds: UInt64(timeUntilReset * 1_000_000_000))
        }
    }

    private func updateRateLimit(from headers: UsageHeaders) {
        if let remaining = headers.rateRemaining {
            self.rateLimitRemaining = remaining
        }
        if let resetSec = headers.rateResetSeconds {
            self.lastRateLimitReset = Date().timeIntervalSince1970 + TimeInterval(resetSec)
        }
    }

    public func fetchMedia(query: MediaQuery, apiKey: String?) async throws -> ([String: Any], UsageHeaders) {
        await waitForRateLimit()

        var components = URLComponents(string: "\(baseURL)/media")!
        var queryItems: [URLQueryItem] = []
        if let tmdb = query.tmdbId { queryItems.append(URLQueryItem(name: "tmdb_id", value: String(tmdb))) }
        if let imdb = query.imdbId, !imdb.isEmpty { queryItems.append(URLQueryItem(name: "imdb_id", value: imdb.trimmingCharacters(in: .whitespaces))) }
        if let season = query.season { queryItems.append(URLQueryItem(name: "season", value: String(season))) }
        if let episode = query.episode { queryItems.append(URLQueryItem(name: "episode", value: String(episode))) }
        if let duration = query.durationMs { queryItems.append(URLQueryItem(name: "duration_ms", value: String(duration))) }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        if let key = apiKey, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            request.addValue("Bearer \(key.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        }

        let (data, _, usage) = try await performRequest(request)
        updateRateLimit(from: usage)


        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, usage)
        }
        throw APIClientError.requestFailed("Invalid JSON response")
    }

    public func submit(requestBody: [String: Any], apiKey: String) async throws -> ([String: Any], UsageHeaders) {
        await waitForRateLimit()

        let url = URL(string: "\(baseURL)/submit")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        LoggerService.shared.info("[TheIntroDBClient] Submitting segment POST \(url)...")
        let (data, _, usage) = try await performRequest(request)
        updateRateLimit(from: usage)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, usage)
        }
        throw APIClientError.requestFailed("Invalid JSON response")
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, UsageHeaders) {
        var req = request
        req.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIClientError.requestFailed("Not an HTTP response")
            }
            let usage = parseUsageHeaders(httpResponse.allHeaderFields)
            if (200...299).contains(httpResponse.statusCode) {
                return (data, httpResponse, usage)
            } else {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
                throw APIClientError.httpError(statusCode: httpResponse.statusCode, message: errMsg, usage: usage)
            }
        } catch let err as APIClientError {
            throw err
        } catch {
            throw APIClientError.requestFailed(error.localizedDescription)
        }
    }
}

// MARK: - IntroDB Client
public actor IntroDBClient {
    private let baseURL: String

    public init(baseURL: String = "https://api.introdb.app") {
        self.baseURL = baseURL
    }

    public func fetchSegments(imdbId: String, season: Int, episode: Int, apiKey: String?) async throws -> ([String: Any], UsageHeaders) {
        var components = URLComponents(string: "\(baseURL)/segments")!
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        if let key = apiKey, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            request.addValue(key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-API-Key")
        }

        let (data, _, usage) = try await performRequest(request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, usage)
        }
        throw APIClientError.requestFailed("Invalid JSON response")
    }

    public func submit(requestBody: [String: Any], apiKey: String) async throws -> ([String: Any], UsageHeaders) {
        let url = URL(string: "\(baseURL)/submit")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        LoggerService.shared.info("[IntroDBClient] Submitting segment POST \(url)...")
        let (data, _, usage) = try await performRequest(request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, usage)
        }
        throw APIClientError.requestFailed("Invalid JSON response")
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, UsageHeaders) {
        var req = request
        req.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIClientError.requestFailed("Not an HTTP response")
            }
            let usage = parseUsageHeaders(httpResponse.allHeaderFields)
            if (200...299).contains(httpResponse.statusCode) {
                return (data, httpResponse, usage)
            } else {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
                throw APIClientError.httpError(statusCode: httpResponse.statusCode, message: errMsg, usage: usage)
            }
        } catch let err as APIClientError {
            throw err
        } catch {
            throw APIClientError.requestFailed(error.localizedDescription)
        }
    }
}

// MARK: - TMDB Client
public actor TMDBClient {
    private let baseURL: String
    private let imageBaseURL: String = "https://image.tmdb.org/t/p/"

    public init(baseURL: String = "https://api.themoviedb.org/3") {
        self.baseURL = baseURL
    }

    public func resolveHints(hint: ParsedFilenameHint, apiKey: String, limit: Int = 6) async throws -> [AutoLookupResult] {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !cleanedKey.isEmpty else {
            throw APIClientError.requestFailed("TMDB API key is missing")
        }
        guard !hint.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        let endpoint = hint.mediaTypeHint == .movie ? "search/movie" : "search/tv"
        let yearQueryName = hint.mediaTypeHint == .movie ? "year" : "first_air_date_year"

        var components = URLComponents(string: "\(baseURL)/\(endpoint)")!
        var queryItems = [
            URLQueryItem(name: "query", value: hint.title),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let y = hint.year {
            queryItems.append(URLQueryItem(name: yearQueryName, value: String(y)))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        var mapped: [AutoLookupResult] = []
        for item in results.prefix(limit) {
            guard let tmdbId = item["id"] as? Int else { continue }
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? "Untitled"
            let dateStr = (item["release_date"] as? String) ?? (item["first_air_date"] as? String)
            var year: Int? = nil
            if let date = dateStr, date.count >= 4 {
                year = Int(date.prefix(4))
            }
            let posterPath = item["poster_path"] as? String
            let posterUrl = posterPath.map { "\(imageBaseURL)w154/\($0.hasPrefix("/") ? String($0.dropFirst()) : $0)" }

            mapped.append(AutoLookupResult(
                tmdbId: tmdbId,
                imdbId: nil,
                mediaType: hint.mediaTypeHint,
                season: hint.season,
                episode: hint.episode,
                title: title,
                matchedYear: year,
                posterUrl: posterUrl
            ))
        }

        return await enrichWithIMDbIDs(results: mapped, mediaType: hint.mediaTypeHint, apiKey: cleanedKey)
    }

    private func enrichWithIMDbIDs(results: [AutoLookupResult], mediaType: MediaType, apiKey: String) async -> [AutoLookupResult] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for item in results {
                group.addTask {
                    let imdb = await self.fetchIMDbID(mediaType: mediaType, tmdbId: item.tmdbId, apiKey: apiKey)
                    return (item.tmdbId, imdb)
                }
            }

            var idMap: [Int: String] = [:]
            for await (tmdbId, imdb) in group {
                if let imdb = imdb {
                    idMap[tmdbId] = imdb
                }
            }

            return results.map { item in
                var copy = item
                copy.imdbId = idMap[item.tmdbId]
                return copy
            }
        }
    }

    private func fetchIMDbID(mediaType: MediaType, tmdbId: Int, apiKey: String) async -> String? {
        let prefix = mediaType == .movie ? "movie" : "tv"
        guard let url = URL(string: "\(baseURL)/\(prefix)/\(tmdbId)/external_ids?language=en-US") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["imdb_id"] as? String
            }
        } catch {
            return nil
        }
        return nil
    }
}

// MARK: - Helper Usage Header Parser
private func parseUsageHeaders(_ headers: [AnyHashable: Any]) -> UsageHeaders {
    var dict: [String: String] = [:]
    for (k, v) in headers {
        if let keyStr = (k as? String)?.lowercased(), let valStr = (v as? CustomStringConvertible)?.description {
            dict[keyStr] = valStr
        }
    }

    func getInt(_ key: String) -> Int? {
        dict[key.lowercased()].flatMap { Int($0) }
    }

    return UsageHeaders(
        rateLimit: getInt("x-ratelimit-limit"),
        rateRemaining: getInt("x-ratelimit-remaining"),
        rateResetSeconds: getInt("x-ratelimit-reset"),
        usageLimit: getInt("x-usagelimit-limit"),
        usageRemaining: getInt("x-usagelimit-remaining"),
        usageResetSeconds: getInt("x-usagelimit-reset")
    )
}
