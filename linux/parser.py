import re
from pathlib import Path
from models import ParsedFilenameHint

class FilenameMediaParser:
    NOISE_TOKENS = {
        "480p", "576p", "720p", "1080p", "2160p",
        "x264", "x265", "h264", "h265", "hevc",
        "webrip", "web", "webdl", "bluray", "brrip",
        "hdrip", "dvdrip", "remux", "proper", "repack",
        "mkv", "mp4", "mov", "m4v", "avi"
    }

    # Pre-compiled regex patterns
    STANDARD_SE_REGEX = re.compile(r"\bS(\d{1,4})E(\d{1,4})\b", re.IGNORECASE)
    ALTERNATE_SE_REGEX = re.compile(r"\b(\d{1,4})x(\d{1,4})\b", re.IGNORECASE)
    YEAR_REGEX = re.compile(r"\b(19\d{2}|20\d{2})\b")

    @classmethod
    def parse_path(cls, path_str: str) -> ParsedFilenameHint:
        path = Path(path_str)
        # deletingPathExtension().lastPathComponent equivalent
        filename = path.stem
        return cls.parse(filename)

    @classmethod
    def parse(cls, raw_name: str) -> ParsedFilenameHint:
        working = raw_name.replace(".", " ").replace("_", " ").replace("-", " ")

        # Extract season and episode
        season, episode, se_match_text = cls._extract_season_episode(working)
        if se_match_text:
            # Case-insensitive replacement
            working = re.sub(re.escape(se_match_text), " ", working, flags=re.IGNORECASE)

        # Extract year
        year = cls._extract_year(working)
        if year is not None:
            working = working.replace(str(year), " ")

        # Normalize title
        title = cls._normalize_title(working)

        return ParsedFilenameHint(
            title=title if title else raw_name,
            year=year,
            season=season,
            episode=episode
        )

    @classmethod
    def _normalize_title(cls, input_str: str) -> str:
        # Keep only alphanumeric characters and spaces
        cleaned = re.sub(r"[^\w\s]", " ", input_str)
        # Collapse multiple spaces and trim
        compact = re.sub(r"\s+", " ", cleaned).strip()

        # Split into tokens and filter noise
        tokens = compact.split(" ")
        filtered_tokens = [t for t in tokens if t.lower() not in cls.NOISE_TOKENS and t]

        return " ".join(filtered_tokens)

    @classmethod
    def _extract_year(cls, input_str: str) -> Optional[int]:
        match = cls.YEAR_REGEX.search(input_str)
        if match:
            return int(match.group(1))
        return None

    @classmethod
    def _extract_season_episode(cls, input_str: str) -> tuple[Optional[int], Optional[int], Optional[str]]:
        for regex in (cls.STANDARD_SE_REGEX, cls.ALTERNATE_SE_REGEX):
            match = regex.search(input_str)
            if match:
                season = int(match.group(1))
                episode = int(match.group(2))
                return season, episode, match.group(0)
        return None, None, None
