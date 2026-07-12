using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Tasks;
using Segmenter.Models;

namespace Segmenter.Services
{
    public class RcdEngine
    {
        public static async Task<Dictionary<string, List<(double Start, double End)>>> DetectAsync(
            string videoDir,
            string featureVectorFunction,
            Action<int, string, string> progressCallback,
            int framejump = 3,
            int percentile = 10,
            int resizeWidth = 320,
            int videoStartThresholdPercentile = 20,
            int videoEndThresholdSeconds = 15,
            int minDetectionSizeSeconds = 15)
        {
            progressCallback(-1, "info", "Starting detection in C#...");
            progressCallback(-1, "info", $"Framejump: {framejump}");
            progressCallback(-1, "info", $"Video width: {resizeWidth}");
            progressCallback(-1, "info", $"Feature vector type: {featureVectorFunction}");

            // Cache directory
            string cacheDir = Path.Combine(Path.GetTempPath(), "introstamp_rcd_cache", $"resized{resizeWidth}", $"{featureVectorFunction}_feature_vectors_framejump{framejump}");
            Directory.CreateDirectory(cacheDir);

            // Scan video files and sort naturally
            var videoExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".flv", ".webm" };
            var videos = Directory.GetFiles(videoDir)
                .Where(f => videoExtensions.Contains(Path.GetExtension(f)))
                .Select(Path.GetFileName)
                .Where(f => f != null)
                .Cast<string>()
                .OrderBy(f => f, new NaturalStringComparer())
                .ToList();

            if (videos.Count == 0)
            {
                progressCallback(-1, "error", "No video files found in the directory.");
                return new Dictionary<string, List<(double Start, double End)>>();
            }

            progressCallback(-1, "info", $"Found {videos.Count} videos. Extracting feature vectors...");

            var allVectors = new List<float[][]>();
            var videoFramerates = new List<double>();
            var videoDurations = new List<double>();

            for (int i = 0; i < videos.Count; i++)
            {
                string videoName = videos[i];
                string fullPath = Path.Combine(videoDir, videoName);

                // Get metadata
                var (fps, duration) = GetVideoMetadata(fullPath);
                videoFramerates.Add(fps);
                videoDurations.Add(duration);

                string cacheFile = Path.Combine(cacheDir, videoName + ".json");
                float[][] vectors;

                if (File.Exists(cacheFile))
                {
                    progressCallback(i, "cached", $"Loading cached vectors for: {videoName}");
                    string json = await File.ReadAllTextAsync(cacheFile);
                    vectors = JsonSerializer.Deserialize<float[][]>(json) ?? Array.Empty<float[]>();
                }
                else
                {
                    progressCallback(i, "processing", $"Extracting features for: {videoName} ({fps:F2} fps, {duration:F1}s)");
                    vectors = await ExtractFeaturesAsync(fullPath, fps, duration, framejump, resizeWidth, msg => progressCallback(i, "processing", msg));
                    
                    // Cache to disk
                    string json = JsonSerializer.Serialize(vectors);
                    await File.WriteAllTextAsync(cacheFile, json);
                }

                allVectors.Add(vectors);
            }

            progressCallback(-1, "info", "Querying episodes using vectorized SIMD L2 search...");
            var allDetections = new Dictionary<string, List<(double Start, double End)>>();

            for (int i = 0; i < videos.Count; i++)
            {
                string videoName = videos[i];
                progressCallback(i, "comparing", $"Querying {videoName}...");

                float[][] query = allVectors[i];
                if (query.Length == 0)
                {
                    allDetections[videoName] = new List<(double, double)>();
                    continue;
                }

                // Build "rest" database
                var restList = new List<float[]>();
                for (int j = 0; j < videos.Count; j++)
                {
                    if (j == i) continue;
                    restList.AddRange(allVectors[j]);
                }
                float[][] rest = restList.ToArray();

                if (rest.Length == 0)
                {
                    allDetections[videoName] = new List<(double, double)>();
                    continue;
                }

                // Calculate L2 distances
                float[] distances = QueryWithSimd(query, rest);

                // Find threshold at percentile
                float threshold = GetPercentile(distances, percentile);

                // Find below-threshold segments
                bool[] belowThreshold = new bool[distances.Length];
                for (int j = 0; j < distances.Length; j++)
                {
                    belowThreshold[j] = distances[j] < threshold;
                }

                double fps = videoFramerates[i];
                double framesPerSecond = fps / framejump;

                // Merge gaps (within 10 seconds)
                int lookahead = (int)Math.Round(framesPerSecond * 10);
                belowThreshold = FillGaps(belowThreshold, lookahead);

                // Find contiguous blocks
                var blocks = new List<(int Start, int End)>();
                int startIdx = -1;
                for (int j = 0; j < belowThreshold.Length; j++)
                {
                    if (belowThreshold[j])
                    {
                        if (startIdx == -1) startIdx = j;
                    }
                    else
                    {
                        if (startIdx != -1)
                        {
                            blocks.Add((startIdx, j - 1));
                            startIdx = -1;
                        }
                    }
                }
                if (startIdx != -1)
                {
                    blocks.Add((startIdx, belowThreshold.Length - 1));
                }

                var detectedBeginning = new List<(double Start, double End)>();
                var detectedEnd = new List<(double Start, double End)>();

                foreach (var block in blocks)
                {
                    double startSec = block.Start / framesPerSecond;
                    double endSec = block.End / framesPerSecond;
                    double blockDuration = endSec - startSec;

                    bool occursAtBeginning = block.End < distances.Length * (videoStartThresholdPercentile / 100.0);
                    bool endsAtTheEnd = block.End > distances.Length - videoEndThresholdSeconds * framesPerSecond;

                    if (blockDuration >= minDetectionSizeSeconds && (occursAtBeginning || endsAtTheEnd))
                    {
                        if (occursAtBeginning)
                        {
                            detectedBeginning.Add((startSec, endSec));
                        }
                        else
                        {
                            detectedEnd.Add((startSec, endSec));
                        }
                    }
                }

                var finalDetections = GetTwoLongestTimestamps(detectedBeginning).Concat(detectedEnd).ToList();
                allDetections[videoName] = finalDetections;

                progressCallback(i, "done", $"Detections for {videoName}:");
                foreach (var det in finalDetections)
                {
                    progressCallback(i, "done", $"  {FormatTime(det.Start)} - {FormatTime(det.End)}");
                }
            }

            progressCallback(-1, "info", "Detection completed!");
            return allDetections;
        }

        private static async Task<float[][]> ExtractFeaturesAsync(string videoPath, double fps, double durationSec, int framejump, int resizeWidth, Action<string> logProgress)
        {
            // Stream frames from FFmpeg directly into memory
            // Output format: raw BGR24 at 320x180 (or 224x224 for CNN)
            int width = resizeWidth;
            int height = resizeWidth == 224 ? 224 : 180;
            int bytesPerFrame = width * height * 3;

            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "ffmpeg",
                    Arguments = $"-y -i \"{videoPath}\" -vf \"scale={width}:{height},select='not(mod(n,{framejump}))'\" -vsync 0 -f rawvideo -pix_fmt bgr24 -",
                    RedirectStandardOutput = true,
                    RedirectStandardError = false,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            var vectors = new List<float[]>();
            int frameCount = 0;
            DateTime lastLogTime = DateTime.UtcNow;

            try
            {
                process.Start();

                var stream = process.StandardOutput.BaseStream;
                byte[] buffer = new byte[bytesPerFrame];

                while (true)
                {
                    int totalRead = 0;
                    while (totalRead < bytesPerFrame)
                    {
                        int read = await stream.ReadAsync(buffer, totalRead, bytesPerFrame - totalRead);
                        if (read <= 0) break;
                        totalRead += read;
                    }

                    if (totalRead < bytesPerFrame) break; // End of video stream

                    // Compute BGR Color Histogram
                    float[] hist = CalculateColorHistogram(buffer, width, height);
                    vectors.Add(hist);

                    frameCount++;
                    if (frameCount % 200 == 0 || (DateTime.UtcNow - lastLogTime).TotalSeconds >= 3.0)
                    {
                        lastLogTime = DateTime.UtcNow;
                        double pct = Math.Min(100.0, (frameCount * framejump) / (fps * durationSec) * 100.0);
                        logProgress($"processed {frameCount} frames ({pct:F1}%)");
                    }
                }

                process.WaitForExit();
            }
            catch (Exception e)
            {
                throw new Exception($"FFmpeg feature extraction failed: {e.Message}");
            }

            return vectors.ToArray();
        }

        private static float[] CalculateColorHistogram(byte[] bgrFrame, int width, int height)
        {
            float[] hist = new float[300];
            int numPixels = width * height;

            for (int i = 0; i < numPixels; i++)
            {
                int bVal = bgrFrame[i * 3];
                int gVal = bgrFrame[i * 3 + 1];
                int rVal = bgrFrame[i * 3 + 2];

                int bBin = (bVal * 100) >> 8; // value * 100 / 256
                int gBin = (gVal * 100) >> 8;
                int rBin = (rVal * 100) >> 8;

                hist[bBin]++;
                hist[100 + gBin]++;
                hist[200 + rBin]++;
            }

            float normFactor = 1.0f / numPixels;
            for (int i = 0; i < 300; i++)
            {
                hist[i] *= normFactor;
            }

            return hist;
        }

        private static float[] QueryWithSimd(float[][] query, float[][] rest)
        {
            float[] results = new float[query.Length];

            Parallel.For(0, query.Length, i =>
            {
                float[] qVec = query[i];
                float minDst = float.MaxValue;

                for (int k = 0; k < rest.Length; k++)
                {
                    float dst = SqrDistance(qVec, rest[k]);
                    if (dst < minDst)
                    {
                        minDst = dst;
                    }
                }
                results[i] = minDst;
            });

            return results;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static float SqrDistance(float[] a, float[] b)
        {
            float sum = 0;
            int i = 0;
            int vectorSize = Vector<float>.Count;

            // SIMD Vectorized L2 search
            for (; i <= a.Length - vectorSize; i += vectorSize)
            {
                var va = new Vector<float>(a, i);
                var vb = new Vector<float>(b, i);
                var diff = va - vb;
                sum += Vector.Dot(diff, diff);
            }

            // Remainder
            for (; i < a.Length; i++)
            {
                float diff = a[i] - b[i];
                sum += diff * diff;
            }

            return sum;
        }

        private static float GetPercentile(float[] values, int percentile)
        {
            if (values == null || values.Length == 0) return 0f;
            var sorted = values.OrderBy(v => v).ToArray();
            int idx = (int)Math.Round((percentile / 100.0) * (sorted.Length - 1));
            return sorted[Math.Clamp(idx, 0, sorted.Length - 1)];
        }

        private static bool[] FillGaps(bool[] sequence, int lookahead)
        {
            int n = sequence.Length;
            bool[] result = (bool[])sequence.Clone();

            int i = 0;
            bool changeNeeded = false;
            int lookLeft = 0;
            var toChange = new List<int>();

            while (i < n)
            {
                lookLeft--;
                if (changeNeeded && lookLeft < 1)
                {
                    changeNeeded = false;
                }

                if (sequence[i])
                {
                    if (changeNeeded)
                    {
                        foreach (var idx in toChange)
                        {
                            result[idx] = true;
                        }
                    }
                    else
                    {
                        changeNeeded = true;
                    }
                    lookLeft = lookahead;
                    toChange.Clear();
                }
                else
                {
                    if (changeNeeded)
                    {
                        toChange.Add(i);
                    }
                }
                i++;
            }
            return result;
        }

        private static List<(double Start, double End)> GetTwoLongestTimestamps(List<(double Start, double End)> intervals)
        {
            if (intervals.Count <= 2) return intervals;
            return intervals.OrderByDescending(x => x.End - x.Start).Take(2).ToList();
        }

        private static (double Fps, double DurationSec) GetVideoMetadata(string videoPath)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "ffprobe",
                Arguments = $"-v error -select_streams v:0 -show_entries stream=r_frame_rate,duration -of csv=p=0 \"{videoPath}\"",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            try
            {
                using var process = Process.Start(startInfo);
                if (process != null)
                {
                    string output = process.StandardOutput.ReadToEnd().Trim();
                    process.WaitForExit();

                    var parts = output.Split(',');
                    if (parts.Length >= 2)
                    {
                        double fps = 23.976;
                        var fpsParts = parts[0].Split('/');
                        if (fpsParts.Length == 2 && double.TryParse(fpsParts[0], out var num) && double.TryParse(fpsParts[1], out var den) && den > 0)
                        {
                            fps = num / den;
                        }
                        else if (double.TryParse(parts[0], out var singleFps))
                        {
                            fps = singleFps;
                        }

                        double duration = 0;
                        double.TryParse(parts[1], out duration);

                        return (fps, duration);
                    }
                }
            }
            catch { }

            return (23.976, 0);
        }

        private static string FormatTime(double seconds)
        {
            var ts = TimeSpan.FromSeconds(seconds);
            return $"{ts.Minutes:02}:{ts.Seconds:02}.{ts.Milliseconds:000}";
        }
    }

    public class NaturalStringComparer : IComparer<string>
    {
        public int Compare(string? x, string? y)
        {
            if (x == null && y == null) return 0;
            if (x == null) return -1;
            if (y == null) return 1;

            return SafeNativeMethods.StrCmpLogicalW(x, y);
        }
    }

    internal static class SafeNativeMethods
    {
        [System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int StrCmpLogicalW(string psz1, string psz2);
    }
}
