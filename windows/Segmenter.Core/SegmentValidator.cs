using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Segmenter.Core
{
    public class SegmentValidationError : Exception
    {
        public SegmentValidationError(string message) : base(message) { }
    }

    public class SegmentValidator
    {
        public const int MinDurationMs = 5_000;
        public const int MaxTimestampMs = 21_600_000;
        public const int MaxIntroDurationMs = 200_000;
        public const int MaxRecapDurationMs = 1_200_000;
        public const int MaxCreditsDurationMs = 1_800_000;
        public const int MaxPreviewDurationMs = 1_800_000;

        private static readonly Regex ImdbPattern = new Regex(@"^tt[0-9]{7,8}$");

        public static Dictionary<string, object?> MakeTheIntroDbSubmissionRequest(SubmissionDraft draft)
        {
            var imdbId = NormalizeImdb(draft.ImdbId);
            var hasTmdb = draft.TmdbId > 0;
            var hasImdb = imdbId != null && IsValidImdb(imdbId);

            if (!hasTmdb && !hasImdb)
            {
                throw new SegmentValidationError("At least TMDB ID or a valid IMDB ID must be provided");
            }

            if (draft.MediaType == MediaType.Movie)
            {
                if (draft.Season != null || draft.Episode != null)
                {
                    throw new SegmentValidationError("Season and episode must be empty for movie submissions");
                }
            }
            else if (draft.MediaType == MediaType.Tv)
            {
                if (draft.Season == null || draft.Season <= 0 || draft.Episode == null || draft.Episode <= 0)
                {
                    throw new SegmentValidationError("Season and episode are required for TV submissions");
                }
            }

            var validated = ValidateTheIntroDbRequest(draft);

            var payload = new Dictionary<string, object?>
            {
                { "type", ((MediaType)validated["type"]!).GetValue() },
                { "segment", ((SegmentType)validated["segment"]!).GetValue() },
                { "start_ms", validated["start_ms"] },
                { "tmdb_id", hasTmdb ? validated["tmdb_id"] : null }
            };

            if (validated.TryGetValue("season", out var s) && s != null)
                payload["season"] = s.ToString();
            if (validated.TryGetValue("episode", out var ep) && ep != null)
                payload["episode"] = ep.ToString();
            if (validated.TryGetValue("end_ms", out var end) && end != null)
                payload["end_ms"] = end;
            if (validated.TryGetValue("imdb_id", out var imdb) && imdb != null)
                payload["imdb_id"] = imdb;
            if (draft.VideoDurationMs != null)
                payload["video_duration_ms"] = draft.VideoDurationMs;

            return payload;
        }

        public static Dictionary<string, object?> MakeIntroDbSubmissionRequest(SubmissionDraft draft)
        {
            if (draft.MediaType != MediaType.Tv)
            {
                throw new SegmentValidationError("IntroDB supports TV episodes only");
            }

            var imdbId = NormalizeImdb(draft.ImdbId);
            if (string.IsNullOrEmpty(imdbId) || !IsValidImdb(imdbId))
            {
                throw new SegmentValidationError("Valid IMDB ID is required for IntroDB uploads");
            }

            if (draft.Season == null || draft.Season <= 0 || draft.Episode == null || draft.Episode <= 0)
            {
                throw new SegmentValidationError("Season and episode are required for IntroDB uploads");
            }

            var introDbSegment = ToIntroDbSegmentType(draft.Segment);
            if (string.IsNullOrEmpty(introDbSegment))
            {
                throw new SegmentValidationError($"IntroDB does not support {draft.Segment.DisplayName()} uploads");
            }

            var validated = ValidateTheIntroDbRequest(draft);
            if (!validated.TryGetValue("end_ms", out var endMs) || endMs == null)
            {
                throw new SegmentValidationError("IntroDB requires an explicit end timestamp");
            }

            return new Dictionary<string, object?>
            {
                { "segment_type", introDbSegment },
                { "imdb_id", imdbId },
                { "season", draft.Season },
                { "episode", draft.Episode },
                { "start_sec", Convert.ToDouble(validated["start_ms"]) / 1000.0 },
                { "end_sec", Convert.ToDouble(endMs) / 1000.0 },
                { "tvdb_id", null },
                { "tmdb_id", draft.TmdbId > 0 ? (int?)draft.TmdbId : null }
            };
        }

        private static string? ToIntroDbSegmentType(SegmentType segment)
        {
            return segment switch
            {
                SegmentType.Intro => "intro",
                SegmentType.Recap => "recap",
                SegmentType.Credits => "outro",
                _ => null
            };
        }

        private static Dictionary<string, object?> ValidateTheIntroDbRequest(SubmissionDraft draft)
        {
            return draft.Segment switch
            {
                SegmentType.Intro => ValidateIntroOrRecap(draft, MaxIntroDurationMs),
                SegmentType.Recap => ValidateIntroOrRecap(draft, MaxRecapDurationMs),
                SegmentType.Credits => ValidateCreditsOrPreview(draft, MaxCreditsDurationMs),
                SegmentType.Preview => ValidateCreditsOrPreview(draft, MaxPreviewDurationMs),
                _ => throw new SegmentValidationError("Unknown segment type")
            };
        }

        private static Dictionary<string, object?> ValidateIntroOrRecap(SubmissionDraft draft, int maxDurationMs)
        {
            var start = draft.StartMs;
            if (start == null)
            {
                if (draft.Segment == SegmentType.Intro)
                {
                    start = 0;
                }
                else
                {
                    throw new SegmentValidationError($"{draft.Segment.DisplayName()} start is required");
                }
            }
            else
            {
                start = Math.Max(start.Value, 0);
            }

            var end = draft.EndMs;
            if (end == null)
            {
                throw new SegmentValidationError($"{draft.Segment.DisplayName()} end is required");
            }

            AssertTimestampBounds(start.Value);
            AssertTimestampBounds(end.Value);

            if (end < start)
            {
                throw new SegmentValidationError("End must be greater than or equal to start");
            }

            var duration = end.Value - start.Value;
            if (duration != 0)
            {
                if (duration < MinDurationMs || duration > maxDurationMs)
                {
                    throw new SegmentValidationError(
                        $"{draft.Segment.DisplayName()} duration must be 0 or between " +
                        $"{MinDurationMs / 1000}s and {maxDurationMs / 1000}s"
                    );
                }
            }

            return new Dictionary<string, object?>
            {
                { "tmdb_id", draft.TmdbId },
                { "type", draft.MediaType },
                { "segment", draft.Segment },
                { "season", draft.Season },
                { "episode", draft.Episode },
                { "start_ms", start },
                { "end_ms", end },
                { "imdb_id", NormalizeImdb(draft.ImdbId) }
            };
        }

        private static Dictionary<string, object?> ValidateCreditsOrPreview(SubmissionDraft draft, int maxDurationMs)
        {
            var start = draft.StartMs;
            if (start == null)
            {
                throw new SegmentValidationError($"{draft.Segment.DisplayName()} start is required");
            }

            AssertTimestampBounds(start.Value);

            if (draft.Segment == SegmentType.Credits && start != 0 && start < MinDurationMs)
            {
                throw new SegmentValidationError($"Credits start must be 0 or at least {MinDurationMs / 1000}s");
            }

            var end = draft.EndMs;
            if (end == null && draft.Segment == SegmentType.Credits && draft.VideoDurationMs != null)
            {
                end = draft.VideoDurationMs;
            }

            if (end != null)
            {
                AssertTimestampBounds(end.Value);
                if (end <= start)
                {
                    throw new SegmentValidationError("End must be greater than start");
                }

                var duration = end.Value - start.Value;
                if (duration < MinDurationMs || duration > maxDurationMs)
                {
                    throw new SegmentValidationError(
                        $"{draft.Segment.DisplayName()} duration must be between " +
                        $"{MinDurationMs / 1000}s and {maxDurationMs / 1000}s"
                    );
                }
            }

            return new Dictionary<string, object?>
            {
                { "tmdb_id", draft.TmdbId },
                { "type", draft.MediaType },
                { "segment", draft.Segment },
                { "season", draft.Season },
                { "episode", draft.Episode },
                { "start_ms", start },
                { "end_ms", end },
                { "imdb_id", NormalizeImdb(draft.ImdbId) }
            };
        }

        private static void AssertTimestampBounds(int value)
        {
            if (value < 0 || value > MaxTimestampMs)
            {
                throw new SegmentValidationError($"Timestamp must be between 0 and {MaxTimestampMs}");
            }
        }

        private static string? NormalizeImdb(string? raw)
        {
            if (raw == null)
                return null;
            var trimmed = raw.Trim();
            return string.IsNullOrEmpty(trimmed) ? null : trimmed;
        }

        private static bool IsValidImdb(string imdb)
        {
            return ImdbPattern.IsMatch(imdb);
        }
    }
}
