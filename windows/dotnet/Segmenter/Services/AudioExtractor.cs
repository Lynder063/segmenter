using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Segmenter.Models;

namespace Segmenter.Services
{
    public class AudioExtractor
    {
        public static async Task<TimelineDensityTrack> ExtractAudioTrackAsync(
            string videoPath,
            int durationMs,
            Action<int> progressCallback,
            CancellationToken cancellationToken = default)
        {
            if (durationMs <= 0)
                throw new ArgumentException("Invalid video duration");

            cancellationToken.ThrowIfCancellationRequested();

            double durationSec = durationMs / 1000.0;
            int sampleRate = 8000;

            // Clamp bucket count: 120 min, 2400 max, one bucket per 250ms
            int bucketCount = Math.Max(120, Math.Min(2400, durationMs / 250));

            Log.Write($"[DEBUG] ExtractAudioTrackAsync. Video: {videoPath}, Duration: {durationMs}ms, Buckets: {bucketCount}");

            // ---------------------------------------------------------------
            // Phase 1: FFmpeg PCM extraction
            // ---------------------------------------------------------------
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "ffmpeg",
                    Arguments = $"-y -threads 2 -i \"{videoPath}\" -f s16le -ac 1 -ar {sampleRate} -",
                    RedirectStandardOutput = true,
                    RedirectStandardError = false,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            Log.Write($"[DEBUG] ExtractAudioTrackAsync. Spawning FFmpeg: {process.StartInfo.FileName} {process.StartInfo.Arguments}");

            var samples = new List<short>((int)(durationSec * sampleRate));

            try
            {
                process.Start();
                Log.Write("[DEBUG] ExtractAudioTrackAsync. FFmpeg process started successfully.");

                var stdoutStream = process.StandardOutput.BaseStream;
                byte[] buffer = new byte[16000]; // 1 second of audio at 8kHz/16-bit
                int expectedTotalSamples = (int)(durationSec * sampleRate);

                await Task.Run(async () =>
                {
                    while (true)
                    {
                        cancellationToken.ThrowIfCancellationRequested();

                        int bytesRead = await stdoutStream.ReadAsync(buffer, 0, buffer.Length, cancellationToken).ConfigureAwait(false);
                        if (bytesRead <= 0) break;

                        for (int i = 0; i + 1 < bytesRead; i += 2)
                            samples.Add(BitConverter.ToInt16(buffer, i));

                        if (expectedTotalSamples > 0)
                        {
                            int pct = (int)Math.Min((double)samples.Count / expectedTotalSamples * 55.0, 55.0);
                            progressCallback(pct);
                        }
                    }
                }, cancellationToken);

                process.WaitForExit();
            }
            catch (OperationCanceledException)
            {
                Log.Write("[DEBUG] ExtractAudioTrackAsync: Cancelled. Killing FFmpeg process.");
                try { process.Kill(); } catch { }
                throw;
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] Audio extraction failed: {ex}");
                try { process.Kill(); } catch { }
                throw new Exception($"FFmpeg extraction failed: {ex.Message}", ex);
            }

            if (samples.Count == 0)
                throw new Exception("No audio samples extracted – FFmpeg may have failed or video has no audio.");

            Log.Write($"[DEBUG] ExtractAudioTrackAsync completed. Loaded {samples.Count} audio samples.");
            progressCallback(60);

            // ---------------------------------------------------------------
            // Phase 2 & 3: Waveform + FFT – run entirely on threadpool thread
            // ---------------------------------------------------------------
            var result = await Task.Run(() =>
            {
                cancellationToken.ThrowIfCancellationRequested();

                // --- 2a. Waveform peak buckets (sequential) ---
                Log.Write("[DEBUG] ExtractAudioTrackAsync: Calculating waveform peak buckets...");
                float[] waveformBuckets = new float[bucketCount];
                int samplesPerBucket = Math.Max(1, samples.Count / bucketCount);

                for (int i = 0; i < bucketCount; i++)
                {
                    int startIdx = i * samplesPerBucket;
                    int endIdx = Math.Min(startIdx + samplesPerBucket, samples.Count);
                    if (startIdx >= samples.Count) break;

                    int maxPeak = 0;
                    for (int j = startIdx; j < endIdx; j++)
                    {
                        int absVal = Math.Abs(samples[j]);
                        if (absVal > maxPeak) maxPeak = absVal;
                    }
                    waveformBuckets[i] = maxPeak;
                }

                // Normalize
                float maxWave = waveformBuckets.Length > 0 ? waveformBuckets.Max() : 1f;
                if (maxWave > 0)
                    for (int i = 0; i < bucketCount; i++)
                        waveformBuckets[i] /= maxWave;

                progressCallback(70);
                Log.Write("[DEBUG] ExtractAudioTrackAsync: Waveform done. Starting FFT...");

                // --- 2b. FFT spectral flatness (sequential, reusable buffers) ---
                int fftSize = 4096;
                int halfFft = fftSize / 2;

                // Hanning window (computed once)
                double[] hanningWin = new double[fftSize];
                for (int i = 0; i < fftSize; i++)
                    hanningWin[i] = 0.5 * (1.0 - Math.Cos(2.0 * Math.PI * i / (fftSize - 1)));

                double binWidth = (double)sampleRate / fftSize;
                int binStart = (int)Math.Max(0, Math.Round(80.0 / binWidth));
                int binEnd   = (int)Math.Min(fftSize / 2, Math.Round(3000.0 / binWidth));
                int binCount = Math.Max(1, binEnd - binStart);

                // Reusable buffers – allocated once, zeroed per iteration
                double[] real      = new double[fftSize];
                double[] imag      = new double[fftSize];
                double[] powerSpec = new double[fftSize / 2];

                float[] musicBuckets = new float[bucketCount];

                Log.Write($"[DEBUG] ExtractAudioTrackAsync: Running sequential FFT for {bucketCount} buckets (fftSize={fftSize})...");

                for (int i = 0; i < bucketCount; i++)
                {
                    if (i % 100 == 0) cancellationToken.ThrowIfCancellationRequested();

                    double pct    = (double)i / bucketCount;
                    double timeSec = pct * durationSec;
                    int cs        = (int)(timeSec * sampleRate);
                    int startIdx  = cs - halfFft;

                    Array.Clear(real, 0, fftSize);
                    Array.Clear(imag, 0, fftSize);

                    double sumAbs = 0;
                    int count = 0;

                    for (int j = 0; j < fftSize; j++)
                    {
                        int idx = startIdx + j;
                        if (idx >= 0 && idx < samples.Count)
                        {
                            double v = samples[idx];
                            real[j] = v * hanningWin[j];
                            sumAbs += Math.Abs(v);
                            count++;
                        }
                    }

                    if (count < 256)
                    {
                        musicBuckets[i] = 0f;
                        continue;
                    }

                    Fft.Transform(real, imag);

                    for (int j = 0; j < fftSize / 2; j++)
                        powerSpec[j] = real[j] * real[j] + imag[j] * imag[j];

                    double logSum = 0, ariSum = 0;
                    const double eps = 1e-10;
                    for (int j = binStart; j < binEnd; j++)
                    {
                        double p = powerSpec[j];
                        logSum += Math.Log(p + eps);
                        ariSum += p;
                    }

                    double geoMean   = Math.Exp(logSum / binCount);
                    double ariMean   = ariSum / binCount;
                    double flatness  = geoMean / (ariMean + eps);
                    double musicScore = 1.0 - flatness;

                    double avgAbs = sumAbs / count;
                    double energy = Math.Min(1.0, avgAbs / 200.0);
                    double val    = musicScore * energy;

                    if (double.IsNaN(val) || double.IsInfinity(val)) val = 0.0;
                    musicBuckets[i] = (float)Math.Clamp(val, 0.0, 1.0);

                    // Report progress in 5% steps during FFT (from 70 to 90)
                    if (i % Math.Max(1, bucketCount / 20) == 0)
                    {
                        int prog = 70 + (int)(20.0 * i / bucketCount);
                        progressCallback(prog);
                    }
                }

                Log.Write("[DEBUG] ExtractAudioTrackAsync: FFT complete. Smoothing...");
                progressCallback(92);

                var smoothedMusic = SmoothBuckets(musicBuckets, radius: 2);

                progressCallback(100);
                Log.Write("[DEBUG] ExtractAudioTrackAsync: All done.");

                return new TimelineDensityTrack
                {
                    Label = "Audio Waveform",
                    Buckets = waveformBuckets.ToList(),
                    MusicLikelihoodBuckets = smoothedMusic
                };
            }, cancellationToken);

            return result;
        }

        private static List<float> SmoothBuckets(float[] arr, int radius)
        {
            int n = arr.Length;
            if (n == 0 || radius <= 0) return arr.ToList();

            float[] smoothed = new float[n];
            for (int i = 0; i < n; i++)
            {
                float weightSum = 0, valueSum = 0;
                for (int k = -radius; k <= radius; k++)
                {
                    int idx = i + k;
                    if (idx >= 0 && idx < n)
                    {
                        float w = radius + 1 - Math.Abs(k);
                        valueSum += arr[idx] * w;
                        weightSum += w;
                    }
                }
                smoothed[i] = weightSum > 0 ? Math.Clamp(valueSum / weightSum, 0f, 1f) : 0f;
            }
            return smoothed.ToList();
        }
    }

    public static class Fft
    {
        public static void Transform(double[] real, double[] imag)
        {
            int n = real.Length;
            if ((n & (n - 1)) != 0) throw new ArgumentException("FFT size must be a power of 2");

            // Bit-reversal permutation
            int j = 0;
            for (int i = 0; i < n; i++)
            {
                if (i < j)
                {
                    (real[i], real[j]) = (real[j], real[i]);
                    (imag[i], imag[j]) = (imag[j], imag[i]);
                }
                int bit = n >> 1;
                while (j >= bit) { j -= bit; bit >>= 1; }
                j += bit;
            }

            // Cooley-Tukey decimation-in-time
            for (int len = 2; len <= n; len <<= 1)
            {
                double angle = -2.0 * Math.PI / len;
                double wr = Math.Cos(angle);
                double wi = Math.Sin(angle);

                for (int i = 0; i < n; i += len)
                {
                    double ur = 1.0, ui = 0.0;
                    int half = len >> 1;
                    for (int k = 0; k < half; k++)
                    {
                        int a = i + k, b = i + k + half;
                        double tr = real[b] * ur - imag[b] * ui;
                        double ti = real[b] * ui + imag[b] * ur;
                        real[b] = real[a] - tr; imag[b] = imag[a] - ti;
                        real[a] += tr;           imag[a] += ti;
                        double nur = ur * wr - ui * wi;
                        ui = ur * wi + ui * wr;
                        ur = nur;
                    }
                }
            }
        }
    }
}
