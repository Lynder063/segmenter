using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Segmenter.Models;

namespace Segmenter.Services
{
    public class SegmentValidationError : Exception
    {
        public SegmentValidationError(string message) : base(message) { }
    }

    public static class SegmentValidator
    {
        public const int MinDurationMs = 5_000;
        public const int MaxTimestampMs = 21_600_000;
        public const int MaxIntroDurationMs = 200_000;
        public const int MaxRecapDurationMs = 1_200_000;
        public const int MaxCreditsDurationMs = 1_800_000;
        public const int MaxPreviewDurationMs = 1_800_000;

        private static readonly Regex ImdbPattern = new Regex(@"^tt[0-9]{7,8}$", RegexOptions.Compiled);

        public static Dictionary<string, object?> MakeTheIntroDbSubmissionRequest(SubmissionDraft draft)
        {
            string? imdbId = NormalizeImdb(draft.ImdbId);
            bool hasTmdb = draft.TmdbId > 0;

            if (!hasTmdb)
            {
                throw new SegmentValidationError("TMDB ID is required for TheIntroDB submissions.");
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
                { "type", ((MediaType)validated["type"]).GetValue() },
                { "segment", ((SegmentType)validated["segment"]).GetValue() },
                { "start_ms", validated["start_ms"] },
                { "tmdb_id", validated["tmdb_id"] }
            };

            if (validated.ContainsKey("season") && validated["season"] != null)
            {
                payload["season"] = validated["season"]!.ToString();
            }
            if (validated.ContainsKey("episode") && validated["episode"] != null)
            {
                payload["episode"] = validated["episode"]!.ToString();
            }
            if (validated.ContainsKey("end_ms") && validated["end_ms"] != null)
            {
                payload["end_ms"] = validated["end_ms"];
            }
            if (validated.ContainsKey("imdb_id") && validated["imdb_id"] != null)
            {
                payload["imdb_id"] = validated["imdb_id"];
            }
            if (draft.VideoDurationMs != null)
            {
                if (draft.VideoDurationMs < 300_000 || draft.VideoDurationMs > 21_600_000)
                {
                    throw new SegmentValidationError("Video duration must be between 5 minutes and 6 hours.");
                }
                payload["video_duration_ms"] = draft.VideoDurationMs;
            }

            return payload;
        }

        public static Dictionary<string, object?> MakeIntroDbSubmissionRequest(SubmissionDraft draft)
        {
            if (draft.MediaType != MediaType.Tv)
            {
                throw new SegmentValidationError("IntroDB supports TV episodes only");
            }

            string? imdbId = NormalizeImdb(draft.ImdbId);
            if (string.IsNullOrEmpty(imdbId) || !IsValidImdb(imdbId))
            {
                throw new SegmentValidationError("Valid IMDB ID is required for IntroDB uploads");
            }

            if (draft.Season == null || draft.Season <= 0 || draft.Episode == null || draft.Episode <= 0)
            {
                throw new SegmentValidationError("Season and episode are required for IntroDB uploads");
            }

            string? introDbSegment = ToIntroDbSegmentType(draft.Segment);
            if (string.IsNullOrEmpty(introDbSegment))
            {
                throw new SegmentValidationError($"IntroDB does not support {draft.Segment.GetDisplayName()} uploads");
            }

            var validated = ValidateTheIntroDbRequest(draft);
            if (!validated.ContainsKey("end_ms") || validated["end_ms"] == null)
            {
                throw new SegmentValidationError("IntroDB requires an explicit end timestamp");
            }

            long startMs = Convert.ToInt64(validated["start_ms"]);
            long endMs = Convert.ToInt64(validated["end_ms"]);

            return new Dictionary<string, object?>
            {
                { "segment_type", introDbSegment },
                { "imdb_id", imdbId },
                { "season", draft.Season },
                { "episode", draft.Episode },
                { "start_sec", (double)startMs / 1000.0 },
                { "end_sec", (double)endMs / 1000.0 },
                { "tvdb_id", null },
                { "tmdb_id", draft.TmdbId > 0 ? (object)draft.TmdbId : null }
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
            int? startMs = draft.StartMs;
            
            if (draft.EndMs == null)
            {
                throw new SegmentValidationError($"{draft.Segment.GetDisplayName()} end is required");
            }
            int end = draft.EndMs.Value;

            if (startMs != null)
            {
                AssertTimestampBounds(startMs.Value);
            }
            AssertTimestampBounds(end);

            int startForCalc = startMs ?? 0;
            if (end < startForCalc)
            {
                throw new SegmentValidationError("End must be greater than or equal to start");
            }

            int duration = end - startForCalc;
            if (duration != 0)
            {
                if (duration < MinDurationMs || duration > maxDurationMs)
                {
                    throw new SegmentValidationError(
                        $"{draft.Segment.GetDisplayName()} duration must be 0 or between " +
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
                { "start_ms", startMs },
                { "end_ms", end },
                { "imdb_id", NormalizeImdb(draft.ImdbId) }
            };
        }

        private static Dictionary<string, object?> ValidateCreditsOrPreview(SubmissionDraft draft, int maxDurationMs)
        {
            if (draft.StartMs == null)
            {
                throw new SegmentValidationError($"{draft.Segment.GetDisplayName()} start is required");
            }
            int start = draft.StartMs.Value;

            AssertTimestampBounds(start);

            if (draft.Segment == SegmentType.Credits && start != 0 && start < MinDurationMs)
            {
                throw new SegmentValidationError($"Credits start must be 0 or at least {MinDurationMs / 1000}s");
            }

            int? end = draft.EndMs;
            
            if (end != null)
            {
                AssertTimestampBounds(end.Value);
                if (end.Value <= start)
                {
                    throw new SegmentValidationError("End must be greater than start");
                }

                int duration = end.Value - start;
                if (duration < MinDurationMs || duration > maxDurationMs)
                {
                    throw new SegmentValidationError(
                        $"{draft.Segment.GetDisplayName()} duration must be between " +
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
            if (raw == null) return null;
            string trimmed = raw.Trim();
            return trimmed.Length > 0 ? trimmed : null;
        }

        private static bool IsValidImdb(string imdb)
        {
            return ImdbPattern.IsMatch(imdb);
        }
    }
}
