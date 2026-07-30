using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using Segmenter.Models;

namespace Segmenter.Services
{
    public static class FilenameMediaParser
    {
        private static readonly HashSet<string> NoiseTokens = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "480p", "576p", "720p", "1080p", "2160p",
            "x264", "x265", "h264", "h265", "hevc",
            "webrip", "web", "webdl", "bluray", "brrip",
            "hdrip", "dvdrip", "remux", "proper", "repack",
            "mkv", "mp4", "mov", "m4v", "avi"
        };

        private static readonly Regex StandardSeRegex = new Regex(@"\bS(\d{1,4})E(\d{1,4})\b", RegexOptions.IgnoreCase);
        private static readonly Regex AlternateSeRegex = new Regex(@"\b(\d{1,4})x(\d{1,4})\b", RegexOptions.IgnoreCase);
        private static readonly Regex YearRegex = new Regex(@"\b(19\d{2}|20\d{2})\b");

        private static readonly Regex TvdbIdRegex = new Regex(@"tvdb(?:id)?[-]?(\d+)", RegexOptions.IgnoreCase);

        public static ParsedFilenameHint ParsePath(string pathStr)
        {
            if (string.IsNullOrEmpty(pathStr))
                return new ParsedFilenameHint();

            string filename = Path.GetFileNameWithoutExtension(pathStr);
            var hint = Parse(filename);

            var tvdbMatch = TvdbIdRegex.Match(pathStr);
            if (tvdbMatch.Success && int.TryParse(tvdbMatch.Groups[1].Value, out int tvdbId))
            {
                hint.TvdbId = tvdbId;
            }

            return hint;
        }

        public static ParsedFilenameHint Parse(string rawName)
        {
            if (string.IsNullOrEmpty(rawName))
                return new ParsedFilenameHint();

            string working = rawName.Replace('.', ' ').Replace('_', ' ').Replace('-', ' ');

            // Extract season and episode
            int? season = null;
            int? episode = null;
            string? seMatchText = null;

            var match = StandardSeRegex.Match(working);
            if (match.Success)
            {
                season = int.Parse(match.Groups[1].Value);
                episode = int.Parse(match.Groups[2].Value);
                seMatchText = match.Value;
            }
            else
            {
                match = AlternateSeRegex.Match(working);
                if (match.Success)
                {
                    season = int.Parse(match.Groups[1].Value);
                    episode = int.Parse(match.Groups[2].Value);
                    seMatchText = match.Value;
                }
            }

            if (!string.IsNullOrEmpty(seMatchText))
            {
                // Case-insensitive removal of matched SxxExx
                working = Regex.Replace(working, Regex.Escape(seMatchText), " ", RegexOptions.IgnoreCase);
            }

            // Extract year
            int? year = null;
            var yearMatch = YearRegex.Match(working);
            if (yearMatch.Success)
            {
                year = int.Parse(yearMatch.Groups[1].Value);
                working = working.Replace(yearMatch.Value, " ");
            }

            // Normalize title
            string title = NormalizeTitle(working);

            return new ParsedFilenameHint
            {
                Title = !string.IsNullOrEmpty(title) ? title : rawName,
                Year = year,
                Season = season,
                Episode = episode
            };
        }

        private static string NormalizeTitle(string inputStr)
        {
            // Keep only alphanumeric characters and spaces
            string cleaned = Regex.Replace(inputStr, @"[^\w\s]", " ");
            // Collapse multiple spaces and trim
            string compact = Regex.Replace(cleaned, @"\s+", " ").Trim();

            // Split into tokens and filter noise
            var tokens = compact.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var filteredTokens = new List<string>();

            foreach (var t in tokens)
            {
                if (!NoiseTokens.Contains(t))
                {
                    filteredTokens.Add(t);
                }
            }

            return string.Join(" ", filteredTokens);
        }
    }
}
