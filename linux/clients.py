import json
import time
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from typing import Optional, List, Dict, Any, Tuple
from models import (
    MediaType, SegmentType, SegmentRange, MediaQuery,
    SubmissionDraft, UsageHeaders, AutoLookupResult, ParsedFilenameHint
)

class APIClientError(Exception):
    def __init__(self, status_code: Optional[int], message: str, usage: Optional[UsageHeaders] = None):
        super().__init__(message)
        self.status_code = status_code
        self.message = message
        self.usage = usage

class TheIntroDBClient:
    def __init__(self, base_url: str = "https://api.theintrodb.org/v3"):
        self.base_url = base_url
        self.lock = Lock()
        self.last_rate_limit_reset = 0.0  # Unix timestamp
        self.rate_limit_remaining = 9999
        self.max_attempts = 3
        self.retryable_status_codes = {429, 503}

    def _wait_for_rate_limit(self):
        with self.lock:
            now = time.time()
            time_until_reset = self.last_rate_limit_reset - now
            if self.rate_limit_remaining <= 1 and time_until_reset > 0:
                time.sleep(time_until_reset)

    def _update_rate_limit(self, usage: Optional[UsageHeaders]):
        if not usage:
            return
        with self.lock:
            if usage.rate_remaining is not None:
                self.rate_limit_remaining = usage.rate_remaining
            if usage.rate_reset_seconds is not None:
                self.last_rate_limit_reset = time.time() + usage.rate_reset_seconds

    def fetch_media(self, query: MediaQuery, api_key: Optional[str]) -> Tuple[Dict[str, Any], UsageHeaders]:
        self._wait_for_rate_limit()

        params = {}
        if query.tmdb_id is not None:
            params["tmdb_id"] = str(query.tmdb_id)
        if query.imdb_id:
            params["imdb_id"] = query.imdb_id.strip()
        if query.season is not None:
            params["season"] = str(query.season)
        if query.episode is not None:
            params["episode"] = str(query.episode)
        if getattr(query, "duration_ms", None) is not None:
            params["duration_ms"] = str(query.duration_ms)

        url_parts = urllib.parse.urlparse(f"{self.base_url}/media")
        query_str = urllib.parse.urlencode(params)
        url = urllib.parse.urlunparse(
            (url_parts.scheme, url_parts.netloc, url_parts.path, url_parts.params, query_str, url_parts.fragment)
        )

        req = urllib.request.Request(url, method="GET")
        if api_key and api_key.strip():
            req.add_header("Authorization", f"Bearer {api_key.strip()}")

        data, headers, status = self._perform_with_retry(req)
        usage = UsageHeaders.from_headers(headers)
        self._update_rate_limit(usage)

        if 200 <= status < 300:
            payload = json.loads(data.decode("utf-8"))
            return payload, usage
        else:
            raise self._parse_error(status, data, usage)

    def submit(self, request_body: Dict[str, Any], api_key: str) -> Tuple[Dict[str, Any], UsageHeaders]:
        print(f"[TheIntroDBClient] Preparing to submit segment: {request_body.get('segment')} to {self.base_url}/submit")
        self._wait_for_rate_limit()

        url = f"{self.base_url}/submit"
        req_data = json.dumps(request_body).encode("utf-8")
        req = urllib.request.Request(url, data=req_data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {api_key.strip()}")

        print(f"[TheIntroDBClient] Executing HTTP POST to {url}...")
        data, headers, status = self._perform_with_retry(req)
        print(f"[TheIntroDBClient] Received HTTP status {status} from {url}")
        usage = UsageHeaders.from_headers(headers)
        self._update_rate_limit(usage)

        if 200 <= status < 300:
            payload = json.loads(data.decode("utf-8"))
            print(f"[TheIntroDBClient] Submission successful: {payload.get('ok') or payload}")
            return payload, usage
        else:
            err = self._parse_error(status, data, usage)
            print(f"[TheIntroDBClient] Submission failed with error: {str(err)}")
            raise err

    def _perform_with_retry(self, req: urllib.request.Request) -> Tuple[bytes, Dict[str, str], int]:
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        last_error = None
        for attempt in range(self.max_attempts):
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    return response.read(), dict(response.info()), response.status
            except urllib.error.HTTPError as e:
                status = e.code
                headers = dict(e.headers)
                data = e.read()
                last_error = APIClientError(status, "HTTP Error", UsageHeaders.from_headers(headers))
                if status in self.retryable_status_codes and attempt < self.max_attempts - 1:
                    time.sleep(pow(2, attempt) * 0.1)
                else:
                    return data, headers, status
            except Exception as e:
                last_error = e
                if attempt < self.max_attempts - 1:
                    time.sleep(pow(2, attempt) * 0.1)
                else:
                    raise APIClientError(None, f"Request failed: {str(e)}")
        raise last_error

    def _parse_error(self, status: int, data: bytes, usage: UsageHeaders) -> APIClientError:
        try:
            parsed = json.loads(data.decode("utf-8"))
            err = parsed.get("error", "Error")
            details = parsed.get("details")
            msg = f"{err}: {details}" if details else err
            return APIClientError(status, msg, usage)
        except Exception:
            raw_msg = data.decode("utf-8", errors="ignore").strip()
            if not raw_msg:
                raw_msg = f"HTTP status code {status}"
            return APIClientError(status, raw_msg, usage)


class IntroDBClient:
    def __init__(self, base_url: str = "https://api.introdb.app"):
        self.base_url = base_url
        self.max_attempts = 3
        self.retryable_status_codes = {429, 503}

    def fetch_segments(self, imdb_id: str, season: int, episode: int, api_key: Optional[str]) -> Tuple[Dict[str, Any], UsageHeaders]:
        params = {
            "imdb_id": imdb_id,
            "season": str(season),
            "episode": str(episode)
        }
        url_parts = urllib.parse.urlparse(f"{self.base_url}/segments")
        query_str = urllib.parse.urlencode(params)
        url = urllib.parse.urlunparse(
            (url_parts.scheme, url_parts.netloc, url_parts.path, url_parts.params, query_str, url_parts.fragment)
        )

        req = urllib.request.Request(url, method="GET")
        if api_key and api_key.strip():
            req.add_header("X-API-Key", api_key.strip())

        data, headers, status = self._perform_with_retry(req)
        usage = UsageHeaders.from_headers(headers)

        if 200 <= status < 300:
            payload = json.loads(data.decode("utf-8"))
            return payload, usage
        else:
            raise self._parse_error(status, data, usage)

    def submit(self, request_body: Dict[str, Any], api_key: str) -> Tuple[Dict[str, Any], UsageHeaders]:
        print(f"[IntroDBClient] Preparing to submit segment: {request_body.get('segment_type')} to {self.base_url}/submit")
        url = f"{self.base_url}/submit"
        req_data = json.dumps(request_body).encode("utf-8")
        req = urllib.request.Request(url, data=req_data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("X-API-Key", api_key.strip())

        print(f"[IntroDBClient] Executing HTTP POST to {url}...")
        data, headers, status = self._perform_with_retry(req)
        print(f"[IntroDBClient] Received HTTP status {status} from {url}")
        usage = UsageHeaders.from_headers(headers)

        if 200 <= status < 300:
            payload = json.loads(data.decode("utf-8"))
            print(f"[IntroDBClient] Submission successful: {payload}")
            return payload, usage
        else:
            err = self._parse_error(status, data, usage)
            print(f"[IntroDBClient] Submission failed with error: {str(err)}")
            raise err

    def _perform_with_retry(self, req: urllib.request.Request) -> Tuple[bytes, Dict[str, str], int]:
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        last_error = None
        for attempt in range(self.max_attempts):
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    return response.read(), dict(response.info()), response.status
            except urllib.error.HTTPError as e:
                status = e.code
                headers = dict(e.headers)
                data = e.read()
                last_error = APIClientError(status, "HTTP Error", UsageHeaders.from_headers(headers))
                if status in self.retryable_status_codes and attempt < self.max_attempts - 1:
                    time.sleep(pow(2, attempt) * 0.1)
                else:
                    return data, headers, status
            except Exception as e:
                last_error = e
                if attempt < self.max_attempts - 1:
                    time.sleep(pow(2, attempt) * 0.1)
                else:
                    raise APIClientError(None, f"Request failed: {str(e)}")
        raise last_error

    def _parse_error(self, status: int, data: bytes, usage: UsageHeaders) -> APIClientError:
        try:
            parsed = json.loads(data.decode("utf-8"))
            err = parsed.get("error", "Error")
            details = parsed.get("details")
            msg = f"{err}: {details}" if details else err
            return APIClientError(status, msg, usage)
        except Exception:
            raw_msg = data.decode("utf-8", errors="ignore").strip()
            if not raw_msg:
                raw_msg = f"HTTP status code {status}"
            return APIClientError(status, raw_msg, usage)


class TMDBClient:
    def __init__(self, base_url: str = "https://api.themoviedb.org/3"):
        self.base_url = base_url
        self.image_base_url = "https://image.tmdb.org/t/p/"

    def resolve_hints(self, hint: ParsedFilenameHint, api_key: str, limit: int = 6) -> List[AutoLookupResult]:
        cleaned_key = api_key.strip()
        if not cleaned_key:
            raise Exception("TMDB API key is missing")

        if not hint.title.strip():
            return []

        endpoint = "search/movie" if hint.media_type_hint == MediaType.MOVIE else "search/tv"
        year_query_name = "year" if hint.media_type_hint == MediaType.MOVIE else "first_air_date_year"

        # Construct request URL
        params = {
            "query": hint.title,
            "include_adult": "false"
        }
        if hint.year is not None:
            params[year_query_name] = str(hint.year)

        url_parts = urllib.parse.urlparse(f"{self.base_url}/{endpoint}")
        query_str = urllib.parse.urlencode(params)
        url = urllib.parse.urlunparse(
            (url_parts.scheme, url_parts.netloc, url_parts.path, url_parts.params, query_str, url_parts.fragment)
        )

        req = urllib.request.Request(url, method="GET")
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        req.add_header("Authorization", f"Bearer {cleaned_key}")
        req.add_header("Accept", "application/json")

        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore") or "TMDB request failed"
            raise Exception(f"TMDB request failed ({e.code}): {body}")
        except Exception as e:
            raise Exception(f"TMDB request failed: {str(e)}")

        results = payload.get("results", [])
        mapped_results = []
        
        for item in results[:max(1, limit)]:
            tmdb_id = item.get("id")
            title = item.get("title") or item.get("name") or "Untitled"
            date_str = item.get("release_date") or item.get("first_air_date")
            year = int(date_str[:4]) if date_str and len(date_str) >= 4 else None
            poster_path = item.get("poster_path")
            poster_url = self._poster_url(poster_path)

            mapped_results.append(
                AutoLookupResult(
                    tmdb_id=tmdb_id,
                    imdb_id=None,
                    media_type=hint.media_type_hint,
                    season=hint.season,
                    episode=hint.episode,
                    title=title,
                    matched_year=year,
                    poster_url=poster_url
                )
            )

        return self._enrich_with_imdb_ids(mapped_results, hint.media_type_hint, cleaned_key)

    def search(self, title: str, media_type: MediaType, api_key: str, limit: int = 10) -> List[AutoLookupResult]:
        cleaned_key = api_key.strip()
        if not cleaned_key:
            raise Exception("TMDB API key is missing")
        if not title.strip():
            return []

        endpoint = "search/movie" if media_type == MediaType.MOVIE else "search/tv"
        params = {
            "query": title,
            "include_adult": "false"
        }

        url_parts = urllib.parse.urlparse(f"{self.base_url}/{endpoint}")
        query_str = urllib.parse.urlencode(params)
        url = urllib.parse.urlunparse(
            (url_parts.scheme, url_parts.netloc, url_parts.path, url_parts.params, query_str, url_parts.fragment)
        )

        req = urllib.request.Request(url, method="GET")
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        req.add_header("Authorization", f"Bearer {cleaned_key}")
        req.add_header("Accept", "application/json")

        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore") or "TMDB request failed"
            raise Exception(f"TMDB request failed ({e.code}): {body}")
        except Exception as e:
            raise Exception(f"TMDB request failed: {str(e)}")

        results = payload.get("results", [])
        mapped_results = []
        
        for item in results[:max(1, limit)]:
            tmdb_id = item.get("id")
            name = item.get("title") or item.get("name") or "Untitled"
            date_str = item.get("release_date") or item.get("first_air_date")
            year = int(date_str[:4]) if date_str and len(date_str) >= 4 else None
            poster_path = item.get("poster_path")
            poster_url = self._poster_url(poster_path)

            mapped_results.append(
                AutoLookupResult(
                    tmdb_id=tmdb_id,
                    imdb_id=None,
                    media_type=media_type,
                    season=None,
                    episode=None,
                    title=name,
                    matched_year=year,
                    poster_url=poster_url
                )
            )

        return self._enrich_with_imdb_ids(mapped_results, media_type, cleaned_key)

    def _enrich_with_imdb_ids(self, results: List[AutoLookupResult], media_type: MediaType, api_key: str) -> List[AutoLookupResult]:
        if not results:
            return []

        # Run external id requests in parallel using thread pool
        with ThreadPoolExecutor(max_workers=min(len(results), 8)) as executor:
            futures = [
                executor.submit(self._fetch_imdb_id, media_type, r.tmdb_id, api_key)
                for r in results
            ]
            for r, fut in zip(results, futures):
                try:
                    r.imdb_id = fut.result()
                except Exception:
                    r.imdb_id = None
        return results

    def _fetch_imdb_id(self, media_type: MediaType, tmdb_id: int, api_key: str) -> Optional[str]:
        path_prefix = "movie" if media_type == MediaType.MOVIE else "tv"
        url = f"{self.base_url}/{path_prefix}/{tmdb_id}/external_ids?language=en-US"

        req = urllib.request.Request(url, method="GET")
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        req.add_header("Authorization", f"Bearer {api_key}")
        req.add_header("Accept", "application/json")

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                payload = json.loads(response.read().decode("utf-8"))
                return payload.get("imdb_id")
        except Exception:
            return None

    def _poster_url(self, path: Optional[str]) -> Optional[str]:
        if not path:
            return None
        clean_path = path[1:] if path.startswith("/") else path
        return f"{self.image_base_url}w154/{clean_path}"
