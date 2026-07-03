import re
from typing import Dict, Any, Optional
from models import SubmissionDraft, MediaType, SegmentType

class SegmentValidationError(Exception):
    pass

class SegmentValidator:
    MIN_DURATION_MS = 5_000
    MAX_TIMESTAMP_MS = 21_600_000
    MAX_INTRO_DURATION_MS = 200_000
    MAX_RECAP_DURATION_MS = 1_200_000
    MAX_CREDITS_DURATION_MS = 1_800_000
    MAX_PREVIEW_DURATION_MS = 1_800_000

    IMDB_PATTERN = re.compile(r"^tt[0-9]{7,8}$")

    @classmethod
    def make_the_introdb_submission_request(cls, draft: SubmissionDraft) -> Dict[str, Any]:
        imdb_id = cls._normalize_imdb(draft.imdb_id)
        has_tmdb = draft.tmdb_id is not None and draft.tmdb_id > 0
        has_imdb = imdb_id is not None and cls._is_valid_imdb(imdb_id)

        if not has_tmdb and not has_imdb:
            raise SegmentValidationError("At least TMDB ID or a valid IMDB ID must be provided")

        if draft.media_type == MediaType.MOVIE:
            if draft.season is not None or draft.episode is not None:
                raise SegmentValidationError("Season and episode must be empty for movie submissions")
        elif draft.media_type == MediaType.TV:
            if draft.season is None or draft.season <= 0 or draft.episode is None or draft.episode <= 0:
                raise SegmentValidationError("Season and episode are required for TV submissions")

        validated = cls._validated_the_introdb_request(draft)
        
        # Build payload matching TheIntroDBSubmissionRequest Swift struct
        payload = {
            "type": validated["type"].value,
            "segment": validated["segment"].value,
            "start_ms": validated["start_ms"],
        }
        if has_tmdb:
            payload["tmdb_id"] = validated["tmdb_id"]
        else:
            payload["tmdb_id"] = None

        if validated.get("season") is not None:
            payload["season"] = str(validated["season"])
        if validated.get("episode") is not None:
            payload["episode"] = str(validated["episode"])
        if validated.get("end_ms") is not None:
            payload["end_ms"] = validated["end_ms"]
        if validated.get("imdb_id") is not None:
            payload["imdb_id"] = validated["imdb_id"]
        if getattr(draft, "video_duration_ms", None) is not None:
            payload["video_duration_ms"] = draft.video_duration_ms

        return payload

    @classmethod
    def make_introdb_submission_request(cls, draft: SubmissionDraft) -> Dict[str, Any]:
        if draft.media_type != MediaType.TV:
            raise SegmentValidationError("IntroDB supports TV episodes only")

        imdb_id = cls._normalize_imdb(draft.imdb_id)
        if not imdb_id or not cls._is_valid_imdb(imdb_id):
            raise SegmentValidationError("Valid IMDB ID is required for IntroDB uploads")

        if draft.season is None or draft.season <= 0 or draft.episode is None or draft.episode <= 0:
            raise SegmentValidationError("Season and episode are required for IntroDB uploads")

        introdb_segment = cls._to_introdb_segment_type(draft.segment)
        if not introdb_segment:
            raise SegmentValidationError(f"IntroDB does not support {draft.segment.display_name} uploads")

        # Create validated range
        validated = cls._validated_the_introdb_request(draft)
        end_ms = validated.get("end_ms")
        if end_ms is None:
            raise SegmentValidationError("IntroDB requires an explicit end timestamp")

        return {
            "segment_type": introdb_segment,
            "imdb_id": imdb_id,
            "season": draft.season,
            "episode": draft.episode,
            "start_sec": float(validated["start_ms"]) / 1000.0,
            "end_sec": float(end_ms) / 1000.0,
            "tvdb_id": None,
            "tmdb_id": draft.tmdb_id if draft.tmdb_id > 0 else None
        }

    @classmethod
    def _to_introdb_segment_type(cls, segment: SegmentType) -> Optional[str]:
        if segment == SegmentType.INTRO:
            return "intro"
        elif segment == SegmentType.RECAP:
            return "recap"
        elif segment == SegmentType.CREDITS:
            return "outro"
        return None

    @classmethod
    def _validated_the_introdb_request(cls, draft: SubmissionDraft) -> Dict[str, Any]:
        if draft.segment == SegmentType.INTRO:
            return cls._validate_intro_or_recap(draft, cls.MAX_INTRO_DURATION_MS)
        elif draft.segment == SegmentType.RECAP:
            return cls._validate_intro_or_recap(draft, cls.MAX_RECAP_DURATION_MS)
        elif draft.segment == SegmentType.CREDITS:
            return cls._validate_credits_or_preview(draft, cls.MAX_CREDITS_DURATION_MS)
        elif draft.segment == SegmentType.PREVIEW:
            return cls._validate_credits_or_preview(draft, cls.MAX_PREVIEW_DURATION_MS)
        raise SegmentValidationError("Unknown segment type")

    @classmethod
    def _validate_intro_or_recap(cls, draft: SubmissionDraft, max_duration_ms: int) -> Dict[str, Any]:
        start = draft.start_ms
        if start is None:
            if draft.segment == SegmentType.INTRO:
                start = 0
            else:
                raise SegmentValidationError(f"{draft.segment.display_name} start is required")
        else:
            start = max(start, 0)

        end = draft.end_ms
        if end is None:
            raise SegmentValidationError(f"{draft.segment.display_name} end is required")

        cls._assert_timestamp_bounds(start)
        cls._assert_timestamp_bounds(end)

        if end < start:
            raise SegmentValidationError("End must be greater than or equal to start")

        duration = end - start
        if duration != 0:
            if duration < cls.MIN_DURATION_MS or duration > max_duration_ms:
                raise SegmentValidationError(
                    f"{draft.segment.display_name} duration must be 0 or between "
                    f"{cls.MIN_DURATION_MS // 1000}s and {max_duration_ms // 1000}s"
                )

        return {
            "tmdb_id": draft.tmdb_id,
            "type": draft.media_type,
            "segment": draft.segment,
            "season": draft.season,
            "episode": draft.episode,
            "start_ms": start,
            "end_ms": end,
            "imdb_id": cls._normalize_imdb(draft.imdb_id)
        }

    @classmethod
    def _validate_credits_or_preview(cls, draft: SubmissionDraft, max_duration_ms: int) -> Dict[str, Any]:
        start = draft.start_ms
        if start is None:
            raise SegmentValidationError(f"{draft.segment.display_name} start is required")

        cls._assert_timestamp_bounds(start)

        if draft.segment == SegmentType.CREDITS and start != 0 and start < cls.MIN_DURATION_MS:
            raise SegmentValidationError(f"Credits start must be 0 or at least {cls.MIN_DURATION_MS // 1000}s")

        end = draft.end_ms
        if end is None and draft.segment == SegmentType.CREDITS and draft.video_duration_ms is not None:
            end = draft.video_duration_ms

        if end is not None:
            cls._assert_timestamp_bounds(end)
            if end <= start:
                raise SegmentValidationError("End must be greater than start")

            duration = end - start
            if duration < cls.MIN_DURATION_MS or duration > max_duration_ms:
                raise SegmentValidationError(
                    f"{draft.segment.display_name} duration must be between "
                    f"{cls.MIN_DURATION_MS // 1000}s and {max_duration_ms // 1000}s"
                )

        return {
            "tmdb_id": draft.tmdb_id,
            "type": draft.media_type,
            "segment": draft.segment,
            "season": draft.season,
            "episode": draft.episode,
            "start_ms": start,
            "end_ms": end,
            "imdb_id": cls._normalize_imdb(draft.imdb_id)
        }

    @classmethod
    def _assert_timestamp_bounds(cls, value: int):
        if value < 0 or value > cls.MAX_TIMESTAMP_MS:
            raise SegmentValidationError(f"Timestamp must be between 0 and {cls.MAX_TIMESTAMP_MS}")

    @classmethod
    def _normalize_imdb(cls, raw: Optional[str]) -> Optional[str]:
        if raw is None:
            return None
        trimmed = raw.strip()
        return trimmed if trimmed else None

    @classmethod
    def _is_valid_imdb(cls, imdb: str) -> bool:
        return bool(cls.IMDB_PATTERN.match(imdb))
