import Foundation

public enum SegmentValidationError: LocalizedError {
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMessage(let msg):
            return msg
        }
    }
}

public final class SegmentValidator {
    public static let minDurationMs: Int = 5_000
    public static let maxTimestampMs: Int = 21_600_000 // 6 hours
    public static let maxIntroDurationMs: Int = 200_000
    public static let maxRecapDurationMs: Int = 1_200_000
    public static let maxCreditsDurationMs: Int = 1_800_000
    public static let maxPreviewDurationMs: Int = 1_800_000

    private static let imdbPattern = try! NSRegularExpression(pattern: "^tt[0-9]{7,8}$")

    public static func makeTheIntroDBSubmissionRequest(draft: SubmissionDraft) throws -> [String: Any] {
        let imdbId = normalizeImdb(draft.imdbId)
        let hasTmdb = draft.tmdbId > 0
        let hasImdb = imdbId != nil && isValidImdb(imdbId!)

        guard hasTmdb || hasImdb else {
            throw SegmentValidationError.invalidMessage("At least TMDB ID or a valid IMDB ID must be provided")
        }

        if draft.mediaType == .movie {
            if draft.season != nil || draft.episode != nil {
                throw SegmentValidationError.invalidMessage("Season and episode must be empty for movie submissions")
            }
        } else if draft.mediaType == .tv {
            guard let season = draft.season, season > 0,
                  let episode = draft.episode, episode > 0 else {
                throw SegmentValidationError.invalidMessage("Season and episode are required for TV submissions")
            }
        }

        let validated = try validateDraftRange(draft)

        var payload: [String: Any] = [
            "type": (validated["type"] as! MediaType).rawValue,
            "segment": (validated["segment"] as! SegmentType).rawValue,
            "start_ms": validated["start_ms"] as! Int
        ]

        if hasTmdb {
            payload["tmdb_id"] = validated["tmdb_id"]
        } else {
            payload["tmdb_id"] = NSNull()
        }

        if let season = validated["season"] as? Int {
            payload["season"] = String(season)
        }
        if let episode = validated["episode"] as? Int {
            payload["episode"] = String(episode)
        }
        if let endMs = validated["end_ms"] as? Int {
            payload["end_ms"] = endMs
        }
        if let imdb = validated["imdb_id"] as? String {
            payload["imdb_id"] = imdb
        }
        if let videoDuration = draft.videoDurationMs {
            payload["video_duration_ms"] = videoDuration
        }

        return payload
    }

    public static func makeIntroDBSubmissionRequest(draft: SubmissionDraft) throws -> [String: Any] {
        guard draft.mediaType == .tv else {
            throw SegmentValidationError.invalidMessage("IntroDB supports TV episodes only")
        }

        guard let imdbId = normalizeImdb(draft.imdbId), isValidImdb(imdbId) else {
            throw SegmentValidationError.invalidMessage("Valid IMDB ID is required for IntroDB uploads")
        }

        guard let season = draft.season, season > 0,
              let episode = draft.episode, episode > 0 else {
            throw SegmentValidationError.invalidMessage("Season and episode are required for IntroDB uploads")
        }

        guard let introdbSegment = toIntroDBSegmentType(draft.segment) else {
            throw SegmentValidationError.invalidMessage("IntroDB does not support \(draft.segment.displayName) uploads")
        }

        let validated = try validateDraftRange(draft)
        guard let endMs = validated["end_ms"] as? Int else {
            throw SegmentValidationError.invalidMessage("IntroDB requires an explicit end timestamp")
        }

        let startMs = validated["start_ms"] as! Int

        return [
            "segment_type": introdbSegment,
            "imdb_id": imdbId,
            "season": season,
            "episode": episode,
            "start_sec": Double(startMs) / 1000.0,
            "end_sec": Double(endMs) / 1000.0,
            "tvdb_id": NSNull(),
            "tmdb_id": draft.tmdbId > 0 ? draft.tmdbId : NSNull()
        ]
    }

    private static func toIntroDBSegmentType(_ segment: SegmentType) -> String? {
        switch segment {
        case .intro: return "intro"
        case .recap: return "recap"
        case .credits: return "outro"
        case .preview: return nil
        }
    }

    private static func validateDraftRange(_ draft: SubmissionDraft) throws -> [String: Any] {
        switch draft.segment {
        case .intro:
            return try validateIntroOrRecap(draft, maxDurationMs: maxIntroDurationMs)
        case .recap:
            return try validateIntroOrRecap(draft, maxDurationMs: maxRecapDurationMs)
        case .credits:
            return try validateCreditsOrPreview(draft, maxDurationMs: maxCreditsDurationMs)
        case .preview:
            return try validateCreditsOrPreview(draft, maxDurationMs: maxPreviewDurationMs)
        }
    }

    private static func validateIntroOrRecap(_ draft: SubmissionDraft, maxDurationMs: Int) throws -> [String: Any] {
        var start = draft.startMs
        if start == nil {
            if draft.segment == .intro {
                start = 0
            } else {
                throw SegmentValidationError.invalidMessage("\(draft.segment.displayName) start is required")
            }
        } else {
            start = max(start!, 0)
        }

        guard let end = draft.endMs else {
            throw SegmentValidationError.invalidMessage("\(draft.segment.displayName) end is required")
        }

        try assertTimestampBounds(start!)
        try assertTimestampBounds(end)

        guard end >= start! else {
            throw SegmentValidationError.invalidMessage("End must be greater than or equal to start")
        }

        let duration = end - start!
        if duration != 0 {
            guard duration >= minDurationMs && duration <= maxDurationMs else {
                throw SegmentValidationError.invalidMessage("\(draft.segment.displayName) duration must be 0 or between \(minDurationMs / 1000)s and \(maxDurationMs / 1000)s")
            }
        }

        return [
            "tmdb_id": draft.tmdbId,
            "type": draft.mediaType,
            "segment": draft.segment,
            "season": draft.season as Any,
            "episode": draft.episode as Any,
            "start_ms": start!,
            "end_ms": end,
            "imdb_id": normalizeImdb(draft.imdbId) as Any
        ]
    }

    private static func validateCreditsOrPreview(_ draft: SubmissionDraft, maxDurationMs: Int) throws -> [String: Any] {
        guard let start = draft.startMs else {
            throw SegmentValidationError.invalidMessage("\(draft.segment.displayName) start is required")
        }

        try assertTimestampBounds(start)

        if draft.segment == .credits && start != 0 && start < minDurationMs {
            throw SegmentValidationError.invalidMessage("Credits start must be 0 or at least \(minDurationMs / 1000)s")
        }

        var end = draft.endMs
        if end == nil && draft.segment == .credits, let videoDuration = draft.videoDurationMs {
            end = videoDuration
        }

        if let explicitEnd = end {
            try assertTimestampBounds(explicitEnd)
            guard explicitEnd > start else {
                throw SegmentValidationError.invalidMessage("End must be greater than start")
            }

            let duration = explicitEnd - start
            guard duration >= minDurationMs && duration <= maxDurationMs else {
                throw SegmentValidationError.invalidMessage("\(draft.segment.displayName) duration must be between \(minDurationMs / 1000)s and \(maxDurationMs / 1000)s")
            }
        }

        return [
            "tmdb_id": draft.tmdbId,
            "type": draft.mediaType,
            "segment": draft.segment,
            "season": draft.season as Any,
            "episode": draft.episode as Any,
            "start_ms": start,
            "end_ms": end as Any,
            "imdb_id": normalizeImdb(draft.imdbId) as Any
        ]
    }

    private static func assertTimestampBounds(_ value: Int) throws {
        guard value >= 0 && value <= maxTimestampMs else {
            throw SegmentValidationError.invalidMessage("Timestamp must be between 0 and \(maxTimestampMs)")
        }
    }

    public static func normalizeImdb(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func isValidImdb(_ imdb: String) -> Bool {
        let range = NSRange(location: 0, length: imdb.utf16.count)
        return imdbPattern.firstMatch(in: imdb, options: [], range: range) != nil
    }
}
