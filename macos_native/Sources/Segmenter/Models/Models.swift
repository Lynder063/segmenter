import Foundation
import SwiftUI
import AppKit

// MARK: - Media Type
public enum MediaType: String, Codable, CaseIterable, Identifiable {
    case movie = "movie"
    case tv = "tv"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .movie: return "Movie"
        case .tv: return "TV Show"
        }
    }
}

// MARK: - Segment Type
public enum SegmentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case intro = "intro"
    case recap = "recap"
    case credits = "credits"
    case preview = "preview"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .intro: return "Intro"
        case .recap: return "Recap"
        case .credits: return "Credits"
        case .preview: return "Preview"
        }
    }

    public var hexColor: String {
        switch self {
        case .intro: return "#007AFF"   // macOS System Blue
        case .recap: return "#FF9500"   // macOS System Orange
        case .credits: return "#34C759" // macOS System Green
        case .preview: return "#FF2D55" // macOS System Pink
        }
    }

    public var color: Color {
        switch self {
        case .intro: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case .recap: return Color(red: 1.00, green: 0.58, blue: 0.00)
        case .credits: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .preview: return Color(red: 1.00, green: 0.18, blue: 0.33)
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .intro: return NSColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1.0)
        case .recap: return NSColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1.0)
        case .credits: return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
        case .preview: return NSColor(red: 1.00, green: 0.18, blue: 0.33, alpha: 1.0)
        }
    }
}

// MARK: - Segment Range
public struct SegmentRange: Codable, Equatable {
    public var startMs: Int?
    public var endMs: Int?

    public init(startMs: Int? = nil, endMs: Int? = nil) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var normalizedStartMs: Int {
        max(startMs ?? 0, 0)
    }
}

// MARK: - Segment Draft
public struct SegmentDraft: Equatable {
    public var startMs: Int?
    public var endMs: Int?

    public init(startMs: Int? = nil, endMs: Int? = nil) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public static var empty: SegmentDraft {
        SegmentDraft(startMs: nil, endMs: nil)
    }

    public var isEmpty: Bool {
        startMs == nil && endMs == nil
    }
}

// MARK: - Timeline Density Track (Waveform & Spectral Flatness)
public struct TimelineDensityTrack: Equatable {
    public var label: String
    public var buckets: [Float]
    public var musicLikelihoodBuckets: [Float]?

    public init(label: String = "", buckets: [Float] = [], musicLikelihoodBuckets: [Float]? = nil) {
        self.label = label
        self.buckets = buckets
        self.musicLikelihoodBuckets = musicLikelihoodBuckets
    }

    public var hasContent: Bool {
        !label.isEmpty && !buckets.isEmpty
    }
}

// MARK: - Media Query
public struct MediaQuery {
    public var tmdbId: Int?
    public var imdbId: String?
    public var season: Int?
    public var episode: Int?
    public var durationMs: Int?

    public init(tmdbId: Int? = nil, imdbId: String? = nil, season: Int? = nil, episode: Int? = nil, durationMs: Int? = nil) {
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.season = season
        self.episode = episode
        self.durationMs = durationMs
    }
}

// MARK: - Submission Draft
public struct SubmissionDraft {
    public var tmdbId: Int
    public var imdbId: String?
    public var mediaType: MediaType
    public var segment: SegmentType
    public var season: Int?
    public var episode: Int?
    public var startMs: Int?
    public var endMs: Int?
    public var videoDurationMs: Int?

    public init(tmdbId: Int, imdbId: String? = nil, mediaType: MediaType, segment: SegmentType, season: Int? = nil, episode: Int? = nil, startMs: Int? = nil, endMs: Int? = nil, videoDurationMs: Int? = nil) {
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.mediaType = mediaType
        self.segment = segment
        self.season = season
        self.episode = episode
        self.startMs = startMs
        self.endMs = endMs
        self.videoDurationMs = videoDurationMs
    }
}

// MARK: - Usage Headers
public struct UsageHeaders {
    public var rateLimit: Int?
    public var rateRemaining: Int?
    public var rateResetSeconds: Int?
    public var usageLimit: Int?
    public var usageRemaining: Int?
    public var usageResetSeconds: Int?

    public var shortDescription: String {
        var chunks: [String] = []
        if let rem = rateRemaining, let lim = rateLimit {
            chunks.append("rate \(rem)/\(lim)")
        }
        if let rem = usageRemaining, let lim = usageLimit {
            chunks.append("usage \(rem)/\(lim)")
        }
        return chunks.isEmpty ? "No limit headers" : chunks.joined(separator: " • ")
    }
}

// MARK: - Auto Lookup Result
public struct AutoLookupResult: Identifiable {
    public var id: Int { tmdbId }
    public var tmdbId: Int
    public var imdbId: String?
    public var mediaType: MediaType
    public var season: Int?
    public var episode: Int?
    public var title: String
    public var matchedYear: Int?
    public var posterUrl: String?

    public init(tmdbId: Int, imdbId: String? = nil, mediaType: MediaType, season: Int? = nil, episode: Int? = nil, title: String, matchedYear: Int? = nil, posterUrl: String? = nil) {
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.mediaType = mediaType
        self.season = season
        self.episode = episode
        self.title = title
        self.matchedYear = matchedYear
        self.posterUrl = posterUrl
    }
}

// MARK: - Parsed Filename Hint
public struct ParsedFilenameHint {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?

    public var mediaTypeHint: MediaType {
        (season != nil || episode != nil) ? .tv : .movie
    }
}
