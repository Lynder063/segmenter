from enum import Enum
from dataclasses import dataclass
from typing import Optional, List, Dict, Any

class MediaType(Enum):
    MOVIE = "movie"
    TV = "tv"

    @property
    def display_name(self) -> str:
        return "Movie" if self == MediaType.MOVIE else "TV"

class SegmentType(Enum):
    INTRO = "intro"
    RECAP = "recap"
    CREDITS = "credits"
    PREVIEW = "preview"

    @property
    def display_name(self) -> str:
        return self.value.capitalize()

    @property
    def hex_color(self) -> str:
        # Standard vibrant colors matching SwiftUI's default palette
        if self == SegmentType.INTRO:
            return "#007aff"  # Blue
        elif self == SegmentType.RECAP:
            return "#ff9500"  # Orange
        elif self == SegmentType.CREDITS:
            return "#34c759"  # Green
        elif self == SegmentType.PREVIEW:
            return "#ff2d55"  # Pink
        return "#8e8e93"

@dataclass
class SegmentRange:
    start_ms: Optional[int] = None
    end_ms: Optional[int] = None

    @property
    def normalized_start_ms(self) -> int:
        return max(self.start_ms or 0, 0)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SegmentRange":
        return cls(
            start_ms=data.get("start_ms"),
            end_ms=data.get("end_ms")
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "start_ms": self.start_ms,
            "end_ms": self.end_ms
        }

@dataclass
class SegmentDraft:
    start_ms: Optional[int] = None
    end_ms: Optional[int] = None

    @classmethod
    def empty(cls) -> "SegmentDraft":
        return cls(start_ms=None, end_ms=None)

    def is_empty(self) -> bool:
        return self.start_ms is None and self.end_ms is None

@dataclass
class TimelineDensityTrack:
    label: str
    buckets: List[float]
    music_likelihood_buckets: Optional[List[float]] = None

    @classmethod
    def empty(cls) -> "TimelineDensityTrack":
        return cls(label="", buckets=[])

    @property
    def has_content(self) -> bool:
        return bool(self.label and self.buckets)

@dataclass
class MediaQuery:
    tmdb_id: Optional[int] = None
    imdb_id: Optional[str] = None
    season: Optional[int] = None
    episode: Optional[int] = None
    duration_ms: Optional[int] = None

@dataclass
class SubmissionDraft:
    tmdb_id: int
    imdb_id: Optional[str]
    media_type: MediaType
    segment: SegmentType
    season: Optional[int] = None
    episode: Optional[int] = None
    start_ms: Optional[int] = None
    end_ms: Optional[int] = None
    video_duration_ms: Optional[int] = None

@dataclass
class UsageHeaders:
    rate_limit: Optional[int] = None
    rate_remaining: Optional[int] = None
    rate_reset_seconds: Optional[int] = None
    usage_limit: Optional[int] = None
    usage_remaining: Optional[int] = None
    usage_reset_seconds: Optional[int] = None

    @property
    def short_description(self) -> str:
        chunks = []
        if self.rate_remaining is not None and self.rate_limit is not None:
            chunks.append(f"rate {self.rate_remaining}/{self.rate_limit}")
        if self.usage_remaining is not None and self.usage_limit is not None:
            chunks.append(f"usage {self.usage_remaining}/{self.usage_limit}")
        if not chunks:
            return "No limit headers"
        return " • ".join(chunks)

    @classmethod
    def from_headers(cls, headers) -> "UsageHeaders":
        # Extracts custom limit headers from HTTP response headers
        # Handles headers case-insensitively
        h_dict = {k.lower(): v for k, v in headers.items()}
        
        def get_int(key):
            val = h_dict.get(key.lower())
            try:
                return int(val) if val is not None else None
            except (ValueError, TypeError):
                return None

        return cls(
            rate_limit=get_int("X-RateLimit-Limit"),
            rate_remaining=get_int("X-RateLimit-Remaining"),
            rate_reset_seconds=get_int("X-RateLimit-Reset"),
            usage_limit=get_int("X-UsageLimit-Limit"),
            usage_remaining=get_int("X-UsageLimit-Remaining"),
            usage_reset_seconds=get_int("X-UsageLimit-Reset")
        )

class SubmissionStatus(Enum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    REJECTED = "rejected"

@dataclass
class AutoLookupResult:
    tmdb_id: int
    imdb_id: Optional[str]
    media_type: MediaType
    season: Optional[int]
    episode: Optional[int]
    title: str
    matched_year: Optional[int] = None
    poster_url: Optional[str] = None

@dataclass
class ParsedFilenameHint:
    title: str
    year: Optional[int] = None
    season: Optional[int] = None
    episode: Optional[int] = None

    @property
    def media_type_hint(self) -> MediaType:
        return MediaType.TV if (self.season is not None or self.episode is not None) else MediaType.MOVIE
