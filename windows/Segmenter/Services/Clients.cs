using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Segmenter.Models;

namespace Segmenter.Services
{
    public class APIClientException : Exception
    {
        public int? StatusCode { get; }
        public UsageHeaders? Usage { get; }

        public APIClientException(int? statusCode, string message, UsageHeaders? usage = null)
            : base(message)
        {
            StatusCode = statusCode;
            Usage = usage;
        }
    }

    public class TheIntroDBClient
    {
        private readonly string _baseUrl;
        private static readonly HttpClient HttpClient = new HttpClient();
        private readonly object _lock = new object();
        private double _lastRateLimitReset = 0.0;
        private int _rateLimitRemaining = 9999;
        private const int MaxAttempts = 3;

        static TheIntroDBClient()
        {
            HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
        }

        public TheIntroDBClient(string baseUrl = "https://api.theintrodb.org/v3")
        {
            _baseUrl = baseUrl;
        }

        private async Task WaitForRateLimitAsync()
        {
            double waitSeconds = 0;
            lock (_lock)
            {
                double now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                double timeUntilReset = _lastRateLimitReset - now;
                if (_rateLimitRemaining <= 1 && timeUntilReset > 0)
                {
                    waitSeconds = timeUntilReset;
                }
            }

            if (waitSeconds > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(waitSeconds));
            }
        }

        private void UpdateRateLimit(UsageHeaders? usage)
        {
            if (usage == null) return;
            lock (_lock)
            {
                if (usage.RateRemaining != null)
                {
                    _rateLimitRemaining = usage.RateRemaining.Value;
                }
                if (usage.RateResetSeconds != null)
                {
                    _lastRateLimitReset = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + usage.RateResetSeconds.Value;
                }
            }
        }

        public async Task<(JsonNode Payload, UsageHeaders Usage)> FetchMediaAsync(MediaQuery query, string? apiKey)
        {
            await WaitForRateLimitAsync();

            var queryParams = new List<string>();
            if (query.TmdbId != null) queryParams.Add($"tmdb_id={query.TmdbId}");
            if (!string.IsNullOrEmpty(query.ImdbId)) queryParams.Add($"imdb_id={Uri.EscapeDataString(query.ImdbId.Trim())}");
            if (query.Season != null) queryParams.Add($"season={query.Season}");
            if (query.Episode != null) queryParams.Add($"episode={query.Episode}");
            if (query.DurationMs != null) queryParams.Add($"duration_ms={query.DurationMs}");

            string url = $"{_baseUrl}/media";
            if (queryParams.Count > 0)
            {
                url += "?" + string.Join("&", queryParams);
            }

            var (data, headers, status) = await PerformWithRetryAsync(() =>
            {
                var req = new HttpRequestMessage(HttpMethod.Get, url);
                if (!string.IsNullOrWhiteSpace(apiKey))
                {
                    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());
                    req.Headers.Add("X-API-Key", apiKey.Trim());
                }
                return req;
            });

            var usage = UsageHeaders.FromHeaders(headers);
            UpdateRateLimit(usage);

            if (status >= 200 && status < 300)
            {
                var json = JsonNode.Parse(data) ?? new JsonObject();
                return (json, usage);
            }
            else
            {
                throw ParseError(status, data, usage);
            }
        }

        public async Task<(JsonNode Payload, UsageHeaders Usage)> SubmitAsync(Dictionary<string, object?> requestBody, string apiKey)
        {
            await WaitForRateLimitAsync();

            string url = $"{_baseUrl}/submit";
            string jsonBody = JsonSerializer.Serialize(requestBody);

            var (data, headers, status) = await PerformWithRetryAsync(() =>
            {
                var req = new HttpRequestMessage(HttpMethod.Post, url);
                req.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());
                req.Headers.Add("X-API-Key", apiKey.Trim());
                return req;
            });

            var usage = UsageHeaders.FromHeaders(headers);
            UpdateRateLimit(usage);

            if (status >= 200 && status < 300)
            {
                var json = JsonNode.Parse(data) ?? new JsonObject();
                return (json, usage);
            }
            else
            {
                throw ParseError(status, data, usage);
            }
        }

        private async Task<(byte[] Data, HttpResponseHeaders Headers, int Status)> PerformWithRetryAsync(Func<HttpRequestMessage> requestFactory)
        {
            Exception? lastError = null;
            for (int attempt = 0; attempt < MaxAttempts; attempt++)
            {
                try
                {
                    using var req = requestFactory();
                    using var response = await HttpClient.SendAsync(req);
                    var data = await response.Content.ReadAsByteArrayAsync();
                    var headers = response.Headers;
                    var status = (int)response.StatusCode;

                    if ((status == 429 || status == 503) && attempt < MaxAttempts - 1)
                    {
                        await Task.Delay((int)Math.Pow(2, attempt) * 100);
                        continue;
                    }

                    return (data, headers, status);
                }
                catch (HttpRequestException e)
                {
                    lastError = e;
                    if (attempt < MaxAttempts - 1)
                    {
                        await Task.Delay((int)Math.Pow(2, attempt) * 100);
                    }
                }
                catch (Exception e)
                {
                    lastError = e;
                    if (attempt < MaxAttempts - 1)
                    {
                        await Task.Delay((int)Math.Pow(2, attempt) * 100);
                    }
                }
            }
            throw new APIClientException(null, $"Request failed: {lastError?.Message}", null);
        }

        private APIClientException ParseError(int status, byte[] data, UsageHeaders usage)
        {
            string rawMsg = Encoding.UTF8.GetString(data).Trim();
            try
            {
                var json = JsonNode.Parse(rawMsg);
                if (json != null)
                {
                    string err = json["error"]?.ToString() ?? "Error";
                    string? details = json["details"]?.ToString();
                    string msg = !string.IsNullOrEmpty(details) ? $"{err}: {details}" : err;
                    return new APIClientException(status, msg, usage);
                }
            }
            catch { }
            
            if (string.IsNullOrEmpty(rawMsg))
            {
                rawMsg = $"HTTP status code {status}";
            }
            return new APIClientException(status, rawMsg, usage);
        }
    }

    public class IntroDBClient
    {
        private readonly string _baseUrl;
        private static readonly HttpClient HttpClient = new HttpClient();
        private const int MaxAttempts = 3;

        static IntroDBClient()
        {
            HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
        }

        public IntroDBClient(string baseUrl = "https://api.introdb.app")
        {
            _baseUrl = baseUrl;
        }

        public async Task<(JsonNode Payload, UsageHeaders Usage)> FetchSegmentsAsync(string imdbId, int season, int episode, string? apiKey)
        {
            string url = $"{_baseUrl}/segments?imdb_id={Uri.EscapeDataString(imdbId)}&season={season}&episode={episode}";

            var (data, headers, status) = await PerformWithRetryAsync(() =>
            {
                var req = new HttpRequestMessage(HttpMethod.Get, url);
                if (!string.IsNullOrWhiteSpace(apiKey))
                {
                    req.Headers.Add("X-API-Key", apiKey.Trim());
                }
                return req;
            });

            var usage = UsageHeaders.FromHeaders(headers);

            if (status >= 200 && status < 300)
            {
                var json = JsonNode.Parse(data) ?? new JsonObject();
                return (json, usage);
            }
            else
            {
                throw ParseError(status, data, usage);
            }
        }

        public async Task<(JsonNode Payload, UsageHeaders Usage)> SubmitAsync(Dictionary<string, object?> requestBody, string apiKey)
        {
            string url = $"{_baseUrl}/submit";
            string jsonBody = JsonSerializer.Serialize(requestBody);

            var (data, headers, status) = await PerformWithRetryAsync(() =>
            {
                var req = new HttpRequestMessage(HttpMethod.Post, url);
                req.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
                req.Headers.Add("X-API-Key", apiKey.Trim());
                return req;
            });

            var usage = UsageHeaders.FromHeaders(headers);

            if (status >= 200 && status < 300)
            {
                var json = JsonNode.Parse(data) ?? new JsonObject();
                return (json, usage);
            }
            else
            {
                throw ParseError(status, data, usage);
            }
        }

        private async Task<(byte[] Data, HttpResponseHeaders Headers, int Status)> PerformWithRetryAsync(Func<HttpRequestMessage> requestFactory)
        {
            Exception? lastError = null;
            for (int attempt = 0; attempt < MaxAttempts; attempt++)
            {
                try
                {
                    using var req = requestFactory();
                    using var response = await HttpClient.SendAsync(req);
                    var data = await response.Content.ReadAsByteArrayAsync();
                    var headers = response.Headers;
                    var status = (int)response.StatusCode;

                    if ((status == 429 || status == 503) && attempt < MaxAttempts - 1)
                    {
                        await Task.Delay((int)Math.Pow(2, attempt) * 100);
                        continue;
                    }

                    return (data, headers, status);
                }
                catch (Exception e)
                {
                    lastError = e;
                    if (attempt < MaxAttempts - 1)
                    {
                        await Task.Delay((int)Math.Pow(2, attempt) * 100);
                    }
                }
            }
            throw new APIClientException(null, $"Request failed: {lastError?.Message}", null);
        }

        private APIClientException ParseError(int status, byte[] data, UsageHeaders usage)
        {
            string rawMsg = Encoding.UTF8.GetString(data).Trim();
            try
            {
                var json = JsonNode.Parse(rawMsg);
                if (json != null)
                {
                    string err = json["error"]?.ToString() ?? "Error";
                    string? details = json["details"]?.ToString();
                    string msg = !string.IsNullOrEmpty(details) ? $"{err}: {details}" : err;
                    return new APIClientException(status, msg, usage);
                }
            }
            catch { }

            if (string.IsNullOrEmpty(rawMsg))
            {
                rawMsg = $"HTTP status code {status}";
            }
            return new APIClientException(status, rawMsg, usage);
        }
    }

    public class TMDBClient
    {
        private readonly string _baseUrl;
        private readonly string _imageBaseUrl = "https://image.tmdb.org/t/p/";
        private static readonly HttpClient HttpClient = new HttpClient();

        static TMDBClient()
        {
            HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
        }

        public TMDBClient(string baseUrl = "https://api.themoviedb.org/3")
        {
            _baseUrl = baseUrl;
        }

        public async Task<List<AutoLookupResult>> ResolveHintsAsync(ParsedFilenameHint hint, string apiKey, int limit = 6)
        {
            string cleanedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanedKey))
            {
                throw new Exception("TMDB API key is missing");
            }
            if (string.IsNullOrWhiteSpace(hint.Title))
            {
                return new List<AutoLookupResult>();
            }

            if (int.TryParse(hint.Title.Trim(), out int directId))
            {
                var directResult = await FetchByIdAsync(directId, hint.MediaTypeHint, cleanedKey);
                if (directResult != null)
                {
                    directResult.Season = hint.Season;
                    directResult.Episode = hint.Episode;
                    return new List<AutoLookupResult> { directResult };
                }
            }
            if (hint.TvdbId != null)
            {
                var tvdbResult = await FetchByExternalIdAsync(hint.TvdbId.Value, "tvdb_id", hint.MediaTypeHint, cleanedKey);
                if (tvdbResult != null)
                {
                    tvdbResult.Season = hint.Season;
                    tvdbResult.Episode = hint.Episode;
                    return new List<AutoLookupResult> { tvdbResult };
                }
            }

            string endpoint = hint.MediaTypeHint == MediaType.Movie ? "search/movie" : "search/tv";
            string yearQueryName = hint.MediaTypeHint == MediaType.Movie ? "year" : "first_air_date_year";

            string url = $"{_baseUrl}/{endpoint}?query={Uri.EscapeDataString(hint.Title)}&include_adult=false";
            if (hint.Year != null)
            {
                url += $"&{yearQueryName}={hint.Year}";
            }

            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cleanedKey);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            try
            {
                using var response = await HttpClient.SendAsync(req);
                if (!response.IsSuccessStatusCode)
                {
                    string body = await response.Content.ReadAsStringAsync();
                    throw new Exception($"TMDB request failed ({(int)response.StatusCode}): {body}");
                }

                string responseText = await response.Content.ReadAsStringAsync();
                var json = JsonNode.Parse(responseText);
                var results = json?["results"]?.AsArray();
                if (results == null) return new List<AutoLookupResult>();

                var mappedResults = new List<AutoLookupResult>();
                foreach (var item in results.Take(limit))
                {
                    if (item == null) continue;
                    int tmdbId = item["id"]?.GetValue<int>() ?? 0;
                    string title = item["title"]?.ToString() ?? item["name"]?.ToString() ?? "Untitled";
                    string? dateStr = item["release_date"]?.ToString() ?? item["first_air_date"]?.ToString();
                    int? year = (dateStr != null && dateStr.Length >= 4 && int.TryParse(dateStr.Substring(0, 4), out var y)) ? y : null;
                    string? posterPath = item["poster_path"]?.ToString();
                    string? posterUrl = GetPosterUrl(posterPath);

                    mappedResults.Add(new AutoLookupResult
                    {
                        TmdbId = tmdbId,
                        ImdbId = null,
                        MediaType = hint.MediaTypeHint,
                        Season = hint.Season,
                        Episode = hint.Episode,
                        Title = title,
                        MatchedYear = year,
                        PosterUrl = posterUrl
                    });
                }

                return mappedResults;
            }
            catch (Exception e)
            {
                throw new Exception($"TMDB request failed: {e.Message}");
            }
        }

        public async Task<List<AutoLookupResult>> SearchAsync(string title, MediaType mediaType, string apiKey, int limit = 10)
        {
            string cleanedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanedKey))
            {
                throw new Exception("TMDB API key is missing");
            }
            if (string.IsNullOrWhiteSpace(title))
            {
                return new List<AutoLookupResult>();
            }

            if (int.TryParse(title.Trim(), out int directId))
            {
                var directResult = await FetchByIdAsync(directId, mediaType, cleanedKey);
                if (directResult != null)
                {
                    return new List<AutoLookupResult> { directResult };
                }
            }

            string endpoint = mediaType == MediaType.Movie ? "search/movie" : "search/tv";
            string url = $"{_baseUrl}/{endpoint}?query={Uri.EscapeDataString(title)}&include_adult=false";

            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cleanedKey);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            try
            {
                using var response = await HttpClient.SendAsync(req);
                if (!response.IsSuccessStatusCode)
                {
                    string body = await response.Content.ReadAsStringAsync();
                    throw new Exception($"TMDB request failed ({(int)response.StatusCode}): {body}");
                }

                string responseText = await response.Content.ReadAsStringAsync();
                var json = JsonNode.Parse(responseText);
                var results = json?["results"]?.AsArray();
                if (results == null) return new List<AutoLookupResult>();

                var mappedResults = new List<AutoLookupResult>();
                foreach (var item in results.Take(limit))
                {
                    if (item == null) continue;
                    int tmdbId = item["id"]?.GetValue<int>() ?? 0;
                    string name = item["title"]?.ToString() ?? item["name"]?.ToString() ?? "Untitled";
                    string? dateStr = item["release_date"]?.ToString() ?? item["first_air_date"]?.ToString();
                    int? year = (dateStr != null && dateStr.Length >= 4 && int.TryParse(dateStr.Substring(0, 4), out var y)) ? y : null;
                    string? posterPath = item["poster_path"]?.ToString();
                    string? posterUrl = GetPosterUrl(posterPath);

                    mappedResults.Add(new AutoLookupResult
                    {
                        TmdbId = tmdbId,
                        ImdbId = null,
                        MediaType = mediaType,
                        Season = null,
                        Episode = null,
                        Title = name,
                        MatchedYear = year,
                        PosterUrl = posterUrl
                    });
                }

                return mappedResults;
            }
            catch (Exception e)
            {
                throw new Exception($"TMDB request failed: {e.Message}");
            }
        }

        public async Task<string?> FetchImdbIdAsync(MediaType mediaType, int tmdbId, string apiKey)
        {
            string pathPrefix = mediaType == MediaType.Movie ? "movie" : "tv";
            string url = $"{_baseUrl}/{pathPrefix}/{tmdbId}/external_ids?language=en-US";

            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            using var response = await HttpClient.SendAsync(req);
            if (!response.IsSuccessStatusCode) return null;

            string text = await response.Content.ReadAsStringAsync();
            var json = JsonNode.Parse(text);
            return json?["imdb_id"]?.ToString();
        }

        private async Task<AutoLookupResult?> FetchByIdAsync(int id, MediaType mediaType, string apiKey)
        {
            string endpoint = mediaType == MediaType.Movie ? $"movie/{id}" : $"tv/{id}";
            string url = $"{_baseUrl}/{endpoint}";

            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            try
            {
                using var response = await HttpClient.SendAsync(req);
                if (!response.IsSuccessStatusCode) return null;

                string responseText = await response.Content.ReadAsStringAsync();
                var item = JsonNode.Parse(responseText);
                if (item == null) return null;

                int tmdbId = item["id"]?.GetValue<int>() ?? 0;
                if (tmdbId == 0) return null;

                string name = item["title"]?.ToString() ?? item["name"]?.ToString() ?? "Untitled";
                string? dateStr = item["release_date"]?.ToString() ?? item["first_air_date"]?.ToString();
                int? year = (dateStr != null && dateStr.Length >= 4 && int.TryParse(dateStr.Substring(0, 4), out var y)) ? y : null;
                string? posterPath = item["poster_path"]?.ToString();
                string? posterUrl = GetPosterUrl(posterPath);

                return new AutoLookupResult
                {
                    TmdbId = tmdbId,
                    ImdbId = null,
                    MediaType = mediaType,
                    Season = null,
                    Episode = null,
                    Title = name,
                    MatchedYear = year,
                    PosterUrl = posterUrl
                };
            }
            catch
            {
                return null;
            }
        }

        private async Task<AutoLookupResult?> FetchByExternalIdAsync(int externalId, string externalSource, MediaType mediaType, string apiKey)
        {
            string url = $"{_baseUrl}/find/{externalId}?external_source={externalSource}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            try
            {
                using var response = await HttpClient.SendAsync(req);
                if (!response.IsSuccessStatusCode) return null;

                string responseText = await response.Content.ReadAsStringAsync();
                var json = JsonNode.Parse(responseText);
                if (json == null) return null;

                string arrayName = mediaType == MediaType.Movie ? "movie_results" : "tv_results";
                var results = json[arrayName]?.AsArray();
                if (results == null || results.Count == 0) return null;

                var item = results[0];
                if (item == null) return null;

                int tmdbId = item["id"]?.GetValue<int>() ?? 0;
                if (tmdbId == 0) return null;

                string name = item["title"]?.ToString() ?? item["name"]?.ToString() ?? "Untitled";
                string? dateStr = item["release_date"]?.ToString() ?? item["first_air_date"]?.ToString();
                int? year = (dateStr != null && dateStr.Length >= 4 && int.TryParse(dateStr.Substring(0, 4), out var y)) ? y : null;
                string? posterPath = item["poster_path"]?.ToString();
                string? posterUrl = GetPosterUrl(posterPath);

                return new AutoLookupResult
                {
                    TmdbId = tmdbId,
                    ImdbId = null,
                    MediaType = mediaType,
                    Season = null,
                    Episode = null,
                    Title = name,
                    MatchedYear = year,
                    PosterUrl = posterUrl
                };
            }
            catch
            {
                return null;
            }
        }

        private string? GetPosterUrl(string? path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            string cleanPath = path.StartsWith("/") ? path.Substring(1) : path;
            return $"{_imageBaseUrl}w154/{cleanPath}";
        }
    }
}
