using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Segmenter.Controls
{
    public partial class FrameStripControl : UserControl
    {
        public event Action<long>? SeekRequested;

        private string _videoPath = string.Empty;
        private long _durationMs = 0;
        private long _currentTimeMs = 0;
        private double _frameRate = 23.976;

        private string _temporalMode = "coarse"; // "coarse" or "fine"
        private long? _focusedTimeMs = null;
        private const int HalfCount = 6; // 13 cells total

        private readonly Dictionary<long, BitmapSource> _cache = new Dictionary<long, BitmapSource>();
        private readonly Dictionary<long, long> _accessTimes = new Dictionary<long, long>();
        private readonly HashSet<long> _pendingRequests = new HashSet<long>();
        private readonly SemaphoreSlim _ffmpegSemaphore = new SemaphoreSlim(4);
        private readonly DispatcherTimer _reloadTimer;
        private readonly List<FrameThumbCell> _cells = new List<FrameThumbCell>();

        // Throttle UpdatePosition during playback to at most 4 calls/second
        private long _lastPositionUpdateTick = 0;
        private const long ThrottleIntervalTicks = 10_000_000 / 4; // 250 ms in ticks

        public FrameStripControl()
        {
            InitializeComponent();

            _reloadTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(200)
            };
            _reloadTimer.Tick += (s, e) =>
            {
                _reloadTimer.Stop();
                _ = LoadVisibleThumbnailsAsync();
            };

            // Initialize cells
            for (int i = 0; i < HalfCount * 2 + 1; i++)
            {
                var cell = new FrameThumbCell();
                cell.Clicked += OnCellClicked;
                ThumbnailsGrid.Children.Add(cell);
                _cells.Add(cell);
            }
        }

        public void SetVideoContext(string videoPath, long durationMs, double frameRate)
        {
            _videoPath = videoPath;
            _durationMs = durationMs;
            _frameRate = frameRate > 0 ? frameRate : 23.976;

            _cache.Clear();
            _accessTimes.Clear();
            _pendingRequests.Clear();
            _temporalMode = "coarse";
            _focusedTimeMs = null;
            UpdateModeLabel();

            if (durationMs > 0)
            {
                UpdatePosition(_currentTimeMs);
            }
        }

        public void UpdatePosition(long currentTimeMs, bool isStepping = false)
        {
            // During regular playback (not user-driven stepping), throttle to 4 updates/s.
            // Without throttling, the 20ms timer fires 50×/s, restarting _reloadTimer every
            // call and preventing FFmpeg thumbnail processes from ever being dispatched.
            if (!isStepping)
            {
                long now = DateTime.UtcNow.Ticks;
                if (now - _lastPositionUpdateTick < ThrottleIntervalTicks) return;
                _lastPositionUpdateTick = now;
            }
            _currentTimeMs = currentTimeMs;

            if (isStepping)
            {
                _temporalMode = "fine";
                _focusedTimeMs = SnapToFineFrame(currentTimeMs);
            }

            UpdateModeLabel();

            var timestamps = CalculateTimestamps();

            for (int i = 0; i < timestamps.Count; i++)
            {
                long ms = timestamps[i];
                var cell = _cells[i];
                cell.SetTime(ms);

                if (_cache.TryGetValue(ms, out var cachedImg))
                {
                    cell.SetThumbnail(cachedImg);
                    _accessTimes[ms] = Stopwatch.GetTimestamp();
                }
                else
                {
                    cell.SetThumbnail(null);
                }

                // Highlight playhead matching cell
                bool isCurr = false;
                if (_temporalMode == "coarse")
                {
                    isCurr = (i == HalfCount);
                }
                else
                {
                    isCurr = Math.Abs(ms - currentTimeMs) < (500.0 / _frameRate);
                }
                cell.SetCurrent(isCurr);
            }

            _reloadTimer.Stop();
            _reloadTimer.Start();
        }

        public void SetTemporalMode(string mode)
        {
            if (mode == "coarse" || mode == "fine")
            {
                _temporalMode = mode;
                if (mode == "coarse")
                {
                    _focusedTimeMs = null;
                }
                UpdateModeLabel();
            }
        }

        private void UpdateModeLabel()
        {
            if (ModeBadge == null || ModeBadgeText == null || ModeDetailText == null) return;

            string fpsText = $"{_frameRate:F2}";
            if (_temporalMode == "coarse")
            {
                ModeBadgeText.Text = "Overview";
                ModeBadge.Background = new SolidColorBrush(Color.FromRgb(30, 41, 59));
                ModeBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(56, 189, 248));
                long stepMs = CoarseStepMs();
                ModeDetailText.Text = $"step = {stepMs} ms, fps {fpsText}";
            }
            else
            {
                ModeBadgeText.Text = "Single Frames";
                ModeBadge.Background = new SolidColorBrush(Color.FromRgb(6, 78, 59));
                ModeBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(52, 211, 153));
                ModeDetailText.Text = $"1 frame step, fps {fpsText}";
            }
        }

        private long CoarseStepMs()
        {
            double seconds = 6.0 / Math.Max(_frameRate, 1.0);
            return Math.Max(1, (long)Math.Round(seconds * 1000.0));
        }

        private long SnapToFineFrame(long ms)
        {
            double seconds = ms / 1000.0;
            long frameIdx = (long)Math.Round(seconds * _frameRate);
            double snappedSec = frameIdx / _frameRate;
            return Math.Max(0, Math.Min((long)Math.Round(snappedSec * 1000.0), _durationMs));
        }

        private List<long> CalculateTimestamps()
        {
            var timestamps = new List<long>();
            long anchor = _focusedTimeMs ?? _currentTimeMs;

            if (_temporalMode == "coarse")
            {
                long step = CoarseStepMs();
                long anchorCoarse = (anchor / step) * step;
                for (int i = 0; i < HalfCount * 2 + 1; i++)
                {
                    long raw = anchorCoarse + (i - HalfCount) * step;
                    timestamps.Add(Math.Max(0, Math.Min(raw, _durationMs)));
                }
            }
            else
            {
                double frameDurationMs = 1000.0 / _frameRate;
                long centerIdx = (long)Math.Round(anchor / frameDurationMs);
                for (int i = 0; i < HalfCount * 2 + 1; i++)
                {
                    long idx = centerIdx + (i - HalfCount);
                    long raw = (long)Math.Round(idx * frameDurationMs);
                    timestamps.Add(Math.Max(0, Math.Min(raw, _durationMs)));
                }
            }

            return timestamps;
        }

        private async Task LoadVisibleThumbnailsAsync()
        {
            if (string.IsNullOrEmpty(_videoPath)) return;

            var timestamps = CalculateTimestamps();

            // Load closest to center first
            var sortedTimestamps = timestamps
                .OrderBy(ms => Math.Abs(timestamps.IndexOf(ms) - HalfCount))
                .ToList();

            foreach (long ms in sortedTimestamps)
            {
                if (_cache.ContainsKey(ms) || _pendingRequests.Contains(ms))
                {
                    continue;
                }

                _pendingRequests.Add(ms);
                _ = ExtractFrameThumbnailAsync(ms);
            }
            await Task.CompletedTask;
        }

        private string GetCacheDirectory()
        {
            if (string.IsNullOrEmpty(_videoPath)) return string.Empty;
            
            byte[] hashBytes = SHA256.HashData(Encoding.UTF8.GetBytes(_videoPath));
            string hash = BitConverter.ToString(hashBytes).Replace("-", "").Substring(0, 16);
            string cacheDir = Path.Combine(Path.GetTempPath(), "Segmenter", "Thumbnails", hash);
            
            if (!Directory.Exists(cacheDir))
            {
                Directory.CreateDirectory(cacheDir);
            }
            return cacheDir;
        }

        private async Task ExtractFrameThumbnailAsync(long ms)
        {
            Log.Write($"[DEBUG] ExtractFrameThumbnailAsync request for {ms}ms. Queue count: {_pendingRequests.Count}");
            
            try
            {
                string cacheDir = GetCacheDirectory();
                string cacheFile = string.IsNullOrEmpty(cacheDir) ? string.Empty : Path.Combine(cacheDir, $"{ms}.jpg");
                byte[] jpegData = Array.Empty<byte>();

                if (!string.IsNullOrEmpty(cacheFile) && File.Exists(cacheFile))
                {
                    try
                    {
                        jpegData = await File.ReadAllBytesAsync(cacheFile);
                    }
                    catch { }
                }

                if (jpegData.Length == 0)
                {
                    await _ffmpegSemaphore.WaitAsync();
                    try
                    {
                        double seconds = ms / 1000.0;

                        var process = new Process
                        {
                            StartInfo = new ProcessStartInfo
                            {
                                FileName = "ffmpeg",
                                Arguments = $"-y -ss {seconds.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)} -i \"{_videoPath}\" -vframes 1 -s 96x54 -f image2 -vcodec mjpeg -",
                                RedirectStandardOutput = true,
                                RedirectStandardError = false,
                                UseShellExecute = false,
                                CreateNoWindow = true
                            }
                        };

                        Log.Write($"[DEBUG] ExtractFrameThumbnailAsync. Spawning FFmpeg for {ms}ms: {process.StartInfo.FileName} {process.StartInfo.Arguments}");
                        process.Start();

                        using var memoryStream = new MemoryStream();
                        using var stdout = process.StandardOutput.BaseStream;
                        await stdout.CopyToAsync(memoryStream);
                        process.WaitForExit();

                        jpegData = memoryStream.ToArray();

                        if (jpegData.Length > 0 && !string.IsNullOrEmpty(cacheFile))
                        {
                            try
                            {
                                await File.WriteAllBytesAsync(cacheFile, jpegData);
                            }
                            catch { } // Ignore cache write errors
                        }
                    }
                    finally
                    {
                        _ffmpegSemaphore.Release();
                    }
                }

                if (jpegData.Length > 0)
                {
                    Dispatcher.Invoke(() =>
                    {
                        try
                        {
                            var bitmap = new BitmapImage();
                            bitmap.BeginInit();
                            bitmap.StreamSource = new MemoryStream(jpegData);
                            bitmap.CacheOption = BitmapCacheOption.OnLoad;
                            bitmap.EndInit();
                            bitmap.Freeze();

                            if (_cache.Count > 300)
                            {
                                var keysToRemove = _cache.OrderBy(kvp => _accessTimes.TryGetValue(kvp.Key, out long t) ? t : 0)
                                                         .Take(50)
                                                         .Select(kvp => kvp.Key)
                                                         .ToList();
                                foreach (var k in keysToRemove)
                                {
                                    _cache.Remove(k);
                                    _accessTimes.Remove(k);
                                }
                            }

                            _cache[ms] = bitmap;
                            _accessTimes[ms] = Stopwatch.GetTimestamp();

                            var currentTimestamps = CalculateTimestamps();
                            for (int i = 0; i < currentTimestamps.Count; i++)
                            {
                                if (Math.Abs(currentTimestamps[i] - ms) <= 5)
                                {
                                    _cells[i].SetThumbnail(bitmap);
                                }
                            }
                        }
                        catch { }
                    });
                }
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] FrameStrip error for {ms}ms: {ex.Message}");
            }
            finally
            {
                _pendingRequests.Remove(ms);
            }
        }

        private void OnCellClicked(long ms)
        {
            _temporalMode = "fine";
            _focusedTimeMs = SnapToFineFrame(ms);
            UpdateModeLabel();
            SeekRequested?.Invoke(ms);
        }
    }

    public class FrameThumbCell : Border
    {
        public Image ThumbnailImage { get; }
        public TextBlock TimeLabel { get; }
        public long TimeMs { get; private set; }
        public bool IsCurrent { get; private set; }

        public event Action<long>? Clicked;

        public FrameThumbCell()
        {
            BorderThickness = new Thickness(1);
            BorderBrush = new SolidColorBrush(Color.FromRgb(28, 28, 31));
            CornerRadius = new CornerRadius(4);
            Background = new SolidColorBrush(Color.FromRgb(11, 11, 13));
            Margin = new Thickness(1);

            var grid = new Grid
            {
                Background = Brushes.Black
            };
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            ThumbnailImage = new Image
            {
                Stretch = Stretch.Uniform,
                Margin = new Thickness(1)
            };
            Grid.SetRow(ThumbnailImage, 0);
            grid.Children.Add(ThumbnailImage);

            TimeLabel = new TextBlock
            {
                Text = "00:00.000",
                FontSize = 9,
                FontFamily = new FontFamily("Consolas"),
                Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 176)),
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 1, 0, 1)
            };
            Grid.SetRow(TimeLabel, 1);
            grid.Children.Add(TimeLabel);

            Child = grid;

            MouseEnter += (s, e) => { if (!IsCurrent) BorderBrush = new SolidColorBrush(Color.FromRgb(80, 80, 91)); };
            MouseLeave += (s, e) => { if (!IsCurrent) BorderBrush = new SolidColorBrush(Color.FromRgb(28, 28, 31)); };
            MouseLeftButtonDown += (s, e) => Clicked?.Invoke(TimeMs);
        }

        public void SetTime(long ms)
        {
            TimeMs = ms;
            var ts = TimeSpan.FromMilliseconds(ms);
            TimeLabel.Text = $"{ts.Minutes:00}:{ts.Seconds:00}.{ts.Milliseconds:000}";
        }

        public void SetThumbnail(ImageSource? image)
        {
            ThumbnailImage.Source = image;
        }

        public void SetCurrent(bool isCurrent)
        {
            IsCurrent = isCurrent;
            if (isCurrent)
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(0, 122, 255)); // Blue
                BorderThickness = new Thickness(1.5);
                TimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(0, 122, 255));
                TimeLabel.FontWeight = FontWeights.Bold;
            }
            else
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(28, 28, 31));
                BorderThickness = new Thickness(1);
                TimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(160, 160, 176));
                TimeLabel.FontWeight = FontWeights.Normal;
            }
        }
    }
}
