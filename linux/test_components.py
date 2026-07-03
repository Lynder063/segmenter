import unittest
from models import ParsedFilenameHint, MediaType, SegmentType, SubmissionDraft
from parser import FilenameMediaParser
from validator import SegmentValidator, SegmentValidationError

class TestFilenameMediaParser(unittest.TestCase):
    def test_parse_tv_standard(self):
        hint = FilenameMediaParser.parse("The.Show.S02E05.1080p.HEVC.mkv")
        self.assertEqual(hint.title, "The Show")
        self.assertEqual(hint.season, 2)
        self.assertEqual(hint.episode, 5)
        self.assertEqual(hint.media_type_hint, MediaType.TV)

    def test_parse_tv_alternate(self):
        hint = FilenameMediaParser.parse("Great_Show_3x12_720p_x264.mp4")
        self.assertEqual(hint.title, "Great Show")
        self.assertEqual(hint.season, 3)
        self.assertEqual(hint.episode, 12)
        self.assertEqual(hint.media_type_hint, MediaType.TV)

    def test_parse_movie(self):
        hint = FilenameMediaParser.parse("A.Beautiful.Mind.2001.Bluray.avi")
        self.assertEqual(hint.title, "A Beautiful Mind")
        self.assertEqual(hint.year, 2001)
        self.assertIsNone(hint.season)
        self.assertIsNone(hint.episode)
        self.assertEqual(hint.media_type_hint, MediaType.MOVIE)

class TestSegmentValidator(unittest.TestCase):
    def test_validate_movie_intro_error(self):
        # Movie cannot have season/episode
        draft = SubmissionDraft(
            tmdb_id=123,
            imdb_id="tt1234567",
            media_type=MediaType.MOVIE,
            segment=SegmentType.INTRO,
            season=1,
            episode=2,
            start_ms=0,
            end_ms=10000
        )
        with self.assertRaises(SegmentValidationError):
            SegmentValidator.make_the_introdb_submission_request(draft)

    def test_validate_duration_too_short(self):
        # Duration is 4000ms, less than min (5000ms)
        draft = SubmissionDraft(
            tmdb_id=123,
            imdb_id="tt1234567",
            media_type=MediaType.TV,
            segment=SegmentType.INTRO,
            season=1,
            episode=2,
            start_ms=0,
            end_ms=4000
        )
        with self.assertRaises(SegmentValidationError):
            SegmentValidator.make_the_introdb_submission_request(draft)

    def test_validate_credits_valid(self):
        draft = SubmissionDraft(
            tmdb_id=123,
            imdb_id="tt1234567",
            media_type=MediaType.TV,
            segment=SegmentType.CREDITS,
            season=1,
            episode=2,
            start_ms=10000,
            end_ms=30000,
            video_duration_ms=4500000
        )
        payload = SegmentValidator.make_the_introdb_submission_request(draft)
        self.assertEqual(payload["start_ms"], 10000)
        self.assertEqual(payload["end_ms"], 30000)
        self.assertEqual(payload["video_duration_ms"], 4500000)
        self.assertEqual(payload["season"], "1")
        self.assertEqual(payload["episode"], "2")

    def test_validate_intro_auto_start_zero(self):
        # Intro draft with no start_ms should automatically default to 0
        draft = SubmissionDraft(
            tmdb_id=123,
            imdb_id="tt1234567",
            media_type=MediaType.TV,
            segment=SegmentType.INTRO,
            season=1,
            episode=2,
            start_ms=None,
            end_ms=15000
        )
        payload = SegmentValidator.make_the_introdb_submission_request(draft)
        self.assertEqual(payload["start_ms"], 0)
        self.assertEqual(payload["end_ms"], 15000)

    def test_validate_credits_auto_end_duration(self):
        # Credits draft with no end_ms should automatically default to video_duration_ms
        draft = SubmissionDraft(
            tmdb_id=123,
            imdb_id="tt1234567",
            media_type=MediaType.TV,
            segment=SegmentType.CREDITS,
            season=1,
            episode=2,
            start_ms=20000,
            end_ms=None,
            video_duration_ms=600000
        )
        payload = SegmentValidator.make_the_introdb_submission_request(draft)
        self.assertEqual(payload["start_ms"], 20000)
        self.assertEqual(payload["end_ms"], 600000)

if __name__ == "__main__":
    unittest.main()
