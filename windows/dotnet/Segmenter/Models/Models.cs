using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Segmenter.Models
{
    public enum MediaType
    {
        Movie,
        Tv
    }

    public static class MediaTypeExtensions
    {
        public static string GetValue(this MediaType type)
        {
            return type == MediaType.Movie ? "movie" : "tv";
        }

        public static string GetDisplayName(this MediaType type)
        {
            return type == MediaType.Movie ? "Movie" : "TV";
        }

        public static MediaType Parse(string value)
        {
            if (string.Equals(value, "movie", StringComparison.OrdinalIgnoreCase))
                return MediaType.Movie;
            return MediaType.Tv;
        }
    }

    public enum SegmentType
    {
        Intro,
        Recap,
        Credits,
        Preview
    }

    public static class SegmentTypeExtensions
    {
        public static string GetValue(this SegmentType type)
        {
            return type.ToString().ToLowerInvariant();
        }

        public static string GetDisplayName(this SegmentType type)
        {
            return type.ToString();
        }

        public static string GetHexColor(this SegmentType type)
        {
            return type switch
            {
                SegmentType.Intro => "#007aff",    // Blue
                SegmentType.Recap => "#ff9500",    // Orange
                SegmentType.Credits => "#34c759",  // Green
                SegmentType.Preview => "#ff2d55",  // Pink
                _ => "#8e8e93"
            };
        }
    }

    public class SegmentRange
    {
        public int? StartMs { get; set; }
        public int? EndMs { get; set; }

        public int NormalizedStartMs => Math.Max(StartMs ?? 0, 0);

        public SegmentRange() { }

        public SegmentRange(int? startMs, int? endMs)
        {
            StartMs = startMs;
            EndMs = endMs;
        }
    }

    public class SegmentDraft
    {
        public int? StartMs { get; set; }
        public int? EndMs { get; set; }

        public SegmentDraft() { }

        public SegmentDraft(int? startMs, int? endMs)
        {
            StartMs = startMs;
            EndMs = endMs;
        }

        public static SegmentDraft Empty() => new SegmentDraft(null, null);

        [JsonIgnore]
        public bool IsEmpty => StartMs == null && EndMs == null;
    }

    public class TimelineDensityTrack
    {
        public string Label { get; set; } = string.Empty;
        public List<float> Buckets { get; set; } = new List<float>();
        public List<float>? MusicLikelihoodBuckets { get; set; }

        public static TimelineDensityTrack Empty() => new TimelineDensityTrack();

        [JsonIgnore]
        public bool HasContent => !string.IsNullOrEmpty(Label) && Buckets != null && Buckets.Count > 0;
    }

    public class MediaQuery
    {
        public int? TmdbId { get; set; }
        public string? ImdbId { get; set; }
        public int? Season { get; set; }
        public int? Episode { get; set; }
        public int? DurationMs { get; set; }
    }

    public class SubmissionDraft
    {
        public int TmdbId { get; set; }
        public string? ImdbId { get; set; }
        public MediaType MediaType { get; set; }
        public SegmentType Segment { get; set; }
        public int? Season { get; set; }
        public int? Episode { get; set; }
        public int? StartMs { get; set; }
        public int? EndMs { get; set; }
        public int? VideoDurationMs { get; set; }
    }

    public class UsageHeaders
    {
        public int? RateLimit { get; set; }
        public int? RateRemaining { get; set; }
        public int? RateResetSeconds { get; set; }
        public int? UsageLimit { get; set; }
        public int? UsageRemaining { get; set; }
        public int? UsageResetSeconds { get; set; }

        [JsonIgnore]
        public string ShortDescription
        {
            get
            {
                var chunks = new List<string>();
                if (RateRemaining != null && RateLimit != null)
                {
                    chunks.Add($"rate {RateRemaining}/{RateLimit}");
                }
                if (UsageRemaining != null && UsageLimit != null)
                {
                    chunks.Add($"usage {UsageRemaining}/{UsageLimit}");
                }
                if (chunks.Count == 0)
                {
                    return "No limit headers";
                }
                return string.Join(" • ", chunks);
            }
        }

        public static UsageHeaders FromHeaders(IEnumerable<KeyValuePair<string, IEnumerable<string>>> headers)
        {
            var usage = new UsageHeaders();
            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            foreach (var h in headers)
            {
                dict[h.Key] = string.Join(",", h.Value);
            }

            int? GetInt(string key)
            {
                if (dict.TryGetValue(key, out var val) && int.TryParse(val, out var res))
                {
                    return res;
                }
                return null;
            }

            usage.RateLimit = GetInt("X-RateLimit-Limit");
            usage.RateRemaining = GetInt("X-RateLimit-Remaining");
            usage.RateResetSeconds = GetInt("X-RateLimit-Reset");
            usage.UsageLimit = GetInt("X-UsageLimit-Limit");
            usage.UsageRemaining = GetInt("X-UsageLimit-Remaining");
            usage.UsageResetSeconds = GetInt("X-UsageLimit-Reset");

            return usage;
        }
    }

    public enum SubmissionStatus
    {
        Pending,
        Accepted,
        Rejected
    }

    public class AutoLookupResult
    {
        public int TmdbId { get; set; }
        public string? ImdbId { get; set; }
        public MediaType MediaType { get; set; }
        public int? Season { get; set; }
        public int? Episode { get; set; }
        public string Title { get; set; } = string.Empty;
        public int? MatchedYear { get; set; }
        public string? PosterUrl { get; set; }
    }

    public class ParsedFilenameHint
    {
        public string Title { get; set; } = string.Empty;
        public int? Year { get; set; }
        public int? Season { get; set; }
        public int? Episode { get; set; }
        public int? TvdbId { get; set; }

        [JsonIgnore]
        public MediaType MediaTypeHint => (Season != null || Episode != null) ? MediaType.Tv : MediaType.Movie;
    }
}
