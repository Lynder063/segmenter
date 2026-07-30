using System;
using System.Collections.Generic;
using LibVLCSharp.Shared;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Segmenter.Models;
using Segmenter.Services;
using Wpf.Ui.Controls;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;
using MessageBoxResult = System.Windows.MessageBoxResult;

namespace Segmenter
{
    public partial class MainWindow : FluentWindow
    {
        // Core state
        private string _selectedVideoPath = string.Empty;
        private long _videoDurationMs = 0;
        private double _frameRate = 23.976;
        private bool _isSliderDragging = false;
        private bool _isMediaOpened = false;
        private bool _isPlaying = false;               // true only when video is actively playing
        private double _previousVolume = 0.5;
        // CancellationToken for audio analysis – cancelled when a new video is loaded
        private CancellationTokenSource _audioCts = new CancellationTokenSource();

        // VLC fields
        private LibVLC _libVLC;
        private LibVLCSharp.Shared.MediaPlayer _mediaPlayer;

        private Dictionary<SegmentType, List<SegmentRange>> _serverSegments = new Dictionary<SegmentType, List<SegmentRange>>();
        private Dictionary<SegmentType, List<SegmentDraft>> _localDrafts = new Dictionary<SegmentType, List<SegmentDraft>>();
        private TimelineDensityTrack _audioTrack = TimelineDensityTrack.Empty();

        // API clients
        private readonly TheIntroDBClient _theIntroDbClient = new TheIntroDBClient();
        private readonly IntroDBClient _introDbClient = new IntroDBClient();
        private readonly TMDBClient _tmdbClient = new TMDBClient();

        // State lists
        private List<AutoLookupResult> _currentLookupResults = new List<AutoLookupResult>();
        private AutoLookupResult? _selectedMetadata = null;

        // Timers
        private readonly DispatcherTimer _playheadTimer;
        private readonly DispatcherTimer _lookupDebounceTimer;

        // Undo/Redo Stack
        private readonly List<Dictionary<SegmentType, List<SegmentDraft>>> _undoStack = new List<Dictionary<SegmentType, List<SegmentDraft>>>();
        private int _undoIndex = -1;

        // Keys Config File Path
        private readonly string _keysConfigPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Segmenter", "keys.json"
        );

        public MainWindow()
        {
            string libvlcPath = Path.Combine(AppContext.BaseDirectory, "libvlc", "win-x64");
            Core.Initialize(libvlcPath);
            _libVLC = new LibVLC();
            _mediaPlayer = new LibVLCSharp.Shared.MediaPlayer(_libVLC);
            _mediaPlayer.LengthChanged += OnMediaPlayerLengthChanged;
            _mediaPlayer.EncounteredError += OnMediaPlayerError;

            InitializeComponent();
            VideoView.MediaPlayer = _mediaPlayer;

            // Set up timeline and drafts
            ResetDrafts();

            // Setup Playhead Update Timer
            _playheadTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(50)
            };
            _playheadTimer.Tick += PlayheadTimer_Tick;

            // Setup Debounce Timer for Lookups
            _lookupDebounceTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(300)
            };
            _lookupDebounceTimer.Tick += async (s, e) =>
            {
                _lookupDebounceTimer.Stop();
                if (_selectedMetadata != null && string.IsNullOrEmpty(_selectedMetadata.ImdbId))
                {
                    try
                    {
                        StatusText("Fetching IMDb ID...");
                        _selectedMetadata.ImdbId = await _tmdbClient.FetchImdbIdAsync(_selectedMetadata.MediaType, _selectedMetadata.TmdbId, TmdbTokenInput.Password);
                        
                        // Update UI with newly fetched IMDb ID
                        MetadataInfoText.Text = $"Title: {_selectedMetadata.Title}\n" +
                                               $"TMDB ID: {_selectedMetadata.TmdbId}\n" +
                                               $"IMDB ID: {_selectedMetadata.ImdbId ?? "N/A"}\n" +
                                               $"Season: {_selectedMetadata.Season?.ToString() ?? "N/A"}\n" +
                                               $"Episode: {_selectedMetadata.Episode?.ToString() ?? "N/A"}";
                    }
                    catch
                    {
                        _selectedMetadata.ImdbId = null;
                    }
                }
                _ = FetchServerSegmentsAsync();
            };

            // Load API Keys after the window is fully loaded to prevent WPF-UI template binding overwrite
            Loaded += (s, e) => LoadApiKeys();

            // Display GPU Status
            GpuStatusText.Text = $"🟢 GPU: {GpuDetector.GpuName} ({GpuDetector.GpuBackend})";

            // Push initial undo state
            PushUndo();

            // Hook Global Keyboard Shortcuts (WPF style)
            PreviewKeyDown += MainWindow_PreviewKeyDown;

            // Hook window state events for logging and stability
            Activated += (s, e) =>
            {
                Log.Write("[DEBUG] Window Activated.");
                // Only resume if the user was actually playing before deactivation
                if (_isMediaOpened && _isPlaying)
                {
                    Log.Write("[DEBUG] Resuming playback after re-activation.");
                    _mediaPlayer.Play();
                    _playheadTimer.Start();
                    PlayPauseBtn.Icon = new SymbolIcon(SymbolRegular.Pause24);
                }
            };
            Deactivated += (s, e) =>
            {
                Log.Write("[DEBUG] Window Deactivated.");
                // Always stop the timer and pause the player when we lose focus.
                // _isPlaying is intentionally NOT changed – it tracks user intent,
                // not the momentary hardware play state.
                if (_isMediaOpened)
                {
                    Log.Write("[DEBUG] Pausing player on deactivation.");
                    _mediaPlayer.SetPause(true);
                    _playheadTimer.Stop();
                }
            };
            LostFocus += (s, e) => Log.Write("[DEBUG] Window LostFocus.");
            GotFocus += (s, e) => Log.Write("[DEBUG] Window GotFocus.");
        }

        private void ResetDrafts()
        {
            _serverSegments = Enum.GetValues(typeof(SegmentType))
                .Cast<SegmentType>()
                .ToDictionary(t => t, t => new List<SegmentRange>());

            _localDrafts = Enum.GetValues(typeof(SegmentType))
                .Cast<SegmentType>()
                .ToDictionary(t => t, t => new List<SegmentDraft> { SegmentDraft.Empty() });
        }

        private Dictionary<SegmentType, List<SegmentDraft>> CopyDrafts(Dictionary<SegmentType, List<SegmentDraft>> src)
        {
            return src.ToDictionary(
                kv => kv.Key,
                kv => kv.Value.Select(d => new SegmentDraft(d.StartMs, d.EndMs)).ToList()
            );
        }

        private void PushUndo()
        {
            if (_undoIndex < _undoStack.Count - 1)
            {
                _undoStack.RemoveRange(_undoIndex + 1, _undoStack.Count - 1 - _undoIndex);
            }
            _undoStack.Add(CopyDrafts(_localDrafts));
            _undoIndex = _undoStack.Count - 1;
        }

        private void Undo()
        {
            if (_undoIndex > 0)
            {
                _undoIndex--;
                _localDrafts = CopyDrafts(_undoStack[_undoIndex]);
                UpdateTimelineWidget();
                UpdateInputs();
                StatusText("Undo action executed", false);
            }
        }

        private void Redo()
        {
            if (_undoIndex < _undoStack.Count - 1)
            {
                _undoIndex++;
                _localDrafts = CopyDrafts(_undoStack[_undoIndex]);
                UpdateTimelineWidget();
                UpdateInputs();
                StatusText("Redo action executed", false);
            }
        }

        private void PlayheadTimer_Tick(object? sender, EventArgs e)
        {
            if (_isMediaOpened && !_isSliderDragging && true)
            {
                long posMs = _mediaPlayer.Time;
                if (posMs < 0) posMs = 0;
                if (_videoDurationMs > 0 && posMs > _videoDurationMs) posMs = _videoDurationMs;
                
                Timeline.CurrentTimeMs = posMs;
                FrameStrip.UpdatePosition(posMs);

                TimeLabel.Text = FormatTime(posMs);
                PositionSlider.Value = posMs;
            }
        }

        private string FormatTime(long ms)
        {
            // Clamp to zero to avoid negative display if position drifts slightly below 0
            if (ms < 0) ms = 0;
            // Guard against massive values that cause TimeSpan overflow
            if (ms > 359999999) ms = 359999999;
            
            var ts = TimeSpan.FromMilliseconds(ms);
            // Include hours only when needed, always show MM:SS.mmm
            if (ts.TotalHours >= 1.0)
                return $"{(int)ts.TotalHours:00}:{ts.Minutes:00}:{ts.Seconds:00}.{ts.Milliseconds:000}";
            return $"{ts.Minutes:00}:{ts.Seconds:00}.{ts.Milliseconds:000}";
        }

        private void UpdateTimelineWidget()
        {
            Timeline.ServerSegments = _serverSegments;
            Timeline.Drafts = _localDrafts;
            Timeline.AudioTrack = _audioTrack;
            Timeline.DurationMs = Math.Max(_videoDurationMs, 60000);
            Timeline.CurrentTimeMs = _mediaPlayer.Time;
            Timeline.InvalidateMeasure();
            Timeline.InvalidateVisual();
        }

        private void UpdateInputs()
        {
            IntroStartInput.Text = FormatTimeInput(_localDrafts[SegmentType.Intro][0].StartMs);
            IntroEndInput.Text = FormatTimeInput(_localDrafts[SegmentType.Intro][0].EndMs);

            RecapStartInput.Text = FormatTimeInput(_localDrafts[SegmentType.Recap][0].StartMs);
            RecapEndInput.Text = FormatTimeInput(_localDrafts[SegmentType.Recap][0].EndMs);

            CreditsStartInput.Text = FormatTimeInput(_localDrafts[SegmentType.Credits][0].StartMs);
            CreditsEndInput.Text = FormatTimeInput(_localDrafts[SegmentType.Credits][0].EndMs);

            PreviewStartInput.Text = FormatTimeInput(_localDrafts[SegmentType.Preview][0].StartMs);
            PreviewEndInput.Text = FormatTimeInput(_localDrafts[SegmentType.Preview][0].EndMs);
        }

        private string FormatTimeInput(int? ms)
        {
            if (ms == null) return string.Empty;
            return FormatTime(ms.Value);
        }

        private int? ParseTimeInput(string text)
        {
            text = text.Trim();
            if (string.IsNullOrEmpty(text)) return null;

            try
            {
                if (int.TryParse(text, out var rawMs)) return rawMs;

                var parts = text.Split(':');
                if (parts.Length < 2 || parts.Length > 3) return null;

                string secPart = parts[parts.Length - 1];
                var secSub = secPart.Split('.');
                int sec = int.Parse(secSub[0]);

                int millis = 0;
                if (secSub.Length == 2)
                {
                    string fraction = secSub[1].PadRight(3, '0').Substring(0, 3);
                    millis = int.Parse(fraction);
                }

                int mins = int.Parse(parts[parts.Length - 2]);
                int hours = parts.Length == 3 ? int.Parse(parts[0]) : 0;

                return (((hours * 60 + mins) * 60) + sec) * 1000 + millis;
            }
            catch
            {
                return null;
            }
        }

        private void StatusText(string text, bool isError = false)
        {
            StatusMessageText.Text = text;
            StatusMessageText.Foreground = isError 
                ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 69, 58)) // Red
                : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(56, 189, 248)); // Blue
        }

        private void LoadApiKeys()
        {
            Log.Write("[DEBUG] LoadApiKeys invoked.");
            try
            {
                if (File.Exists(_keysConfigPath))
                {
                    string json = File.ReadAllText(_keysConfigPath);
                    Log.Write($"[DEBUG] Read keys JSON: {json}");
                    var keys = JsonSerializer.Deserialize<Dictionary<string, string>>(json);
                    if (keys != null)
                    {
                        // Unsubscribe temporarily to prevent immediate save loops during loading
                        TheIntroDbTokenInput.PasswordChanged -= OnApiKeysChanged;
                        IntroDbApiKeyInput.PasswordChanged -= OnApiKeysChanged;
                        TmdbTokenInput.PasswordChanged -= OnApiKeysChanged;

                        if (keys.TryGetValue("theintrodb", out var token)) TheIntroDbTokenInput.Password = token;
                        if (keys.TryGetValue("introdb", out var key)) IntroDbApiKeyInput.Password = key;
                        if (keys.TryGetValue("tmdb", out var tmdb)) TmdbTokenInput.Password = tmdb;

                        TheIntroDbTokenInput.PasswordChanged += OnApiKeysChanged;
                        IntroDbApiKeyInput.PasswordChanged += OnApiKeysChanged;
                        TmdbTokenInput.PasswordChanged += OnApiKeysChanged;

                        Log.Write("[DEBUG] API keys successfully loaded into password boxes.");
                    }
                }
                else
                {
                    Log.Write($"[DEBUG] Keys config file not found at: {_keysConfigPath}");
                }
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] LoadApiKeys failed: {ex.Message}");
            }
        }

        private void SaveApiKeys()
        {
            Log.Write("[DEBUG] SaveApiKeys invoked.");
            try
            {
                var keys = new Dictionary<string, string>
                {
                    { "theintrodb", TheIntroDbTokenInput.Password },
                    { "introdb", IntroDbApiKeyInput.Password },
                    { "tmdb", TmdbTokenInput.Password }
                };
                string dir = Path.GetDirectoryName(_keysConfigPath)!;
                Directory.CreateDirectory(dir);
                string json = JsonSerializer.Serialize(keys);
                File.WriteAllText(_keysConfigPath, json);
                Log.Write($"[DEBUG] Saved keys to {_keysConfigPath}. JSON: {json}");
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] SaveApiKeys failed: {ex.Message}");
            }
        }

        // ==========================================
        // UI HANDLERS
        // ==========================================

        private void LoadVideo(string filePath)
        {
            _selectedVideoPath = filePath;
            Log.Write($"[DEBUG] LoadVideo. Selected file: {_selectedVideoPath}");
            VideoPathText.Text = Path.GetFileName(_selectedVideoPath);

            // Detach and clean up old player entirely to prevent decoding crashes
            if (_mediaPlayer != null)
            {
                _mediaPlayer.LengthChanged -= OnMediaPlayerLengthChanged;
                _mediaPlayer.EncounteredError -= OnMediaPlayerError;
                
                var oldPlayer = _mediaPlayer;
                VideoView.MediaPlayer = null;
                
                // Dispose asynchronously because Stop() can block
                Task.Run(() => {
                    oldPlayer.Stop();
                    oldPlayer.Dispose();
                });
            }

            _isMediaOpened = false;
            _playheadTimer.Stop();

            StatusText($"Loading video: {Path.GetFileName(_selectedVideoPath)}");
            
            // Create a brand new MediaPlayer for the new video
            _mediaPlayer = new LibVLCSharp.Shared.MediaPlayer(_libVLC);
            _mediaPlayer.LengthChanged += OnMediaPlayerLengthChanged;
            _mediaPlayer.EncounteredError += OnMediaPlayerError;
            VideoView.MediaPlayer = _mediaPlayer;

            // Use Uri to ensure UNC paths and special characters are handled perfectly by VLC
            var uri = new Uri(_selectedVideoPath).AbsoluteUri;
            _mediaPlayer.Media = new Media(_libVLC, uri, FromType.FromLocation);
            _mediaPlayer.Volume = 0; // Mute temporarily to avoid audio bursts during load
            _mediaPlayer.Play(); // Trigger load
        }

        private async void OnOpenVideoClicked(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFileDialog
            {
                Filter = "Video Files|*.mp4;*.mkv;*.avi;*.mov;*.m4v;*.webm|All Files|*.*"
            };

            if (dialog.ShowDialog() == true)
            {
                LoadVideo(dialog.FileName);
            }
            await Task.CompletedTask;
        }

        private void OnMediaPlayerLengthChanged(object? sender, MediaPlayerLengthChangedEventArgs e)
        {
            if (e.Length <= 0) return; // Ignore initial unparsed length
            
            Dispatcher.BeginInvoke(() =>
            {
                if (_isMediaOpened) return; // run once per file
                
                Log.Write($"[DEBUG] OnMediaPlayerLengthChanged triggered. Length: {e.Length}ms");
                _isMediaOpened = true;
                _isPlaying = false; // Start paused – user must press Play
                
                // Delay the pause slightly to allow VLC to render the very first frame
                Task.Delay(150).ContinueWith(_ =>
                {
                    Dispatcher.BeginInvoke(() => {
                        if (!_isPlaying && _mediaPlayer != null)
                        {
                            _mediaPlayer.SetPause(true);
                            _mediaPlayer.Volume = (int)VolumeSlider.Value; // Restore volume
                        }
                    });
                });
                
                _videoDurationMs = e.Length;
                Log.Write($"[DEBUG] OnMediaPlayerLengthChanged. Set duration to: {_videoDurationMs}ms");

                DurationLabel.Text = FormatTime(_videoDurationMs);
                PositionSlider.Maximum = _videoDurationMs;

                // Try to get real framerate via ffprobe
                _ = Task.Run(async () =>
                {
                    double fps = await FfprobeFrameRateAsync(_selectedVideoPath);
                    Dispatcher.BeginInvoke(() =>
                    {
                        _frameRate = fps;
                        Log.Write($"[DEBUG] Frame rate set to: {_frameRate:F3} fps");
                        FrameStrip.SetVideoContext(_selectedVideoPath, _videoDurationMs, _frameRate);
                    });
                });

                Timeline.VideoDurationMs = _videoDurationMs;
                Timeline.DurationMs = _videoDurationMs;

                // Load Frame Strip with default fps first (ffprobe will update later)
                FrameStrip.SetVideoContext(_selectedVideoPath, _videoDurationMs, _frameRate);
                FrameStrip.UpdatePosition(0);

                // DO NOT start the playhead timer here. Timer starts only when user clicks Play.
                PlayPauseBtn.Icon = new SymbolIcon(SymbolRegular.Play24);

                _mediaPlayer.Time = 1;

                // Update UI immediately with hardcoded 0
                TimeLabel.Text = FormatTime(0);
                PositionSlider.Value = 0;
                Timeline.CurrentTimeMs = 0;
                Log.Write($"[DEBUG] OnMediaPlayerLengthChanged: reset position to 0.");

                UpdateTimelineWidget();

                StatusText($"Loaded: {Path.GetFileName(_selectedVideoPath)}");

                // Discord RPC – video loaded state
                DiscordRpcService.SetVideoLoaded(_selectedVideoPath, GetFormattedShowName());

                // Cancel any in-progress audio analysis from a previous video
                _audioCts.Cancel();
                _audioCts = new CancellationTokenSource();
                _ = RunAudioAnalysisAsync(_audioCts.Token);

                AutoLookupMedia();
            });
        }

        /// <summary>Calls ffprobe to get the real framerate of the video file.</summary>
        private static async Task<double> FfprobeFrameRateAsync(string videoPath)
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "ffprobe",
                    Arguments = $"-v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 \"{videoPath}\"",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = System.Diagnostics.Process.Start(psi)!;
                string output = await proc.StandardOutput.ReadToEndAsync();
                await proc.WaitForExitAsync();

                // Output is like "30000/1001" or "25/1"
                var parts = output.Trim().Split('/');
                if (parts.Length == 2
                    && double.TryParse(parts[0], out double num)
                    && double.TryParse(parts[1], out double den)
                    && den > 0)
                {
                    return num / den;
                }
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG] FfprobeFrameRateAsync failed: {ex.Message}");
            }
            return 23.976; // safe fallback
        }

        private void OnMediaPlayerError(object? sender, EventArgs e)
        {
            Dispatcher.BeginInvoke(() =>
            {
                StatusText($"Failed to load media via VLC engine.", true);
                MessageBox.Show($"Failed to load media via VLC engine. Make sure the file isn't corrupted.", "Media Load Error", MessageBoxButton.OK, MessageBoxImage.Error);
            });
        }

        private async Task RunAudioAnalysisAsync(CancellationToken token)
        {
            Log.Write($"[DEBUG] RunAudioAnalysisAsync started for video: {_selectedVideoPath}");
            StatusText("Analyzing audio track waveform (FFT)...");
            DiscordRpcService.SetAnalyzing(_selectedVideoPath);
            AsyncProgressBar.Visibility = Visibility.Visible;
            AsyncProgressBar.Value = 0;
            TaskbarProgress.ProgressState = System.Windows.Shell.TaskbarItemProgressState.Normal;
            TaskbarProgress.ProgressValue = 0;

            try
            {
                _audioTrack = await AudioExtractor.ExtractAudioTrackAsync(
                    _selectedVideoPath,
                    (int)_videoDurationMs,
                    // BeginInvoke is non-blocking – avoids any dispatcher deadlock
                    pct => Dispatcher.BeginInvoke(() =>
                    {
                        AsyncProgressBar.Value = pct;
                        TaskbarProgress.ProgressValue = pct / 100.0;
                    }),
                    token
                );

                Log.Write($"[DEBUG] Audio analysis result: Label='{_audioTrack.Label}', Buckets={_audioTrack.Buckets?.Count ?? 0}, HasContent={_audioTrack.HasContent}");
                UpdateTimelineWidget();
                Log.Write("[DEBUG] UpdateTimelineWidget called after audio analysis. Timeline should now show waveform.");
                StatusText("Audio analysis completed!");
                // Discord RPC – back to video loaded state after analysis
                DiscordRpcService.SetVideoLoaded(_selectedVideoPath, GetFormattedShowName());
            }
            catch (OperationCanceledException)
            {
                Log.Write("[DEBUG] RunAudioAnalysisAsync cancelled (new video loaded).");
                // Silently swallow – this is expected when user opens a new file
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] RunAudioAnalysisAsync failed: {ex}");
                StatusText($"Audio analysis failed: {ex.Message}", true);
            }
            finally
            {
                // Only hide progress if this is still the current video's analysis
                if (!token.IsCancellationRequested)
                {
                    AsyncProgressBar.Visibility = Visibility.Collapsed;
                    TaskbarProgress.ProgressState = System.Windows.Shell.TaskbarItemProgressState.None;
                }
            }
        }

        private void OnPlayPauseClicked(object sender, RoutedEventArgs e)
        {
            TogglePlay();
        }

        private void TogglePlay()
        {
            Log.Write($"[DEBUG] TogglePlay called. _isMediaOpened={_isMediaOpened}, _isPlaying={_isPlaying}");
            if (!_isMediaOpened) return;

            try
            {
                if (_isPlaying)
                {
                    // --- Pause ---
                    _isPlaying = false;
                    _mediaPlayer.SetPause(true);
                    _playheadTimer.Stop();
                    PlayPauseBtn.Icon = new SymbolIcon(SymbolRegular.Play24);

                    // Snap to nearest frame boundary
                    long pos = _mediaPlayer.Time;
                    long snapped = SnapToFrame(pos);
                    _mediaPlayer.Time = snapped;
                    Log.Write($"[DEBUG] TogglePlay: Paused. Snapped to {snapped}ms.");
                    DiscordRpcService.SetPaused(_selectedVideoPath, snapped, _videoDurationMs, GetFormattedShowName());
                }
                else
                {
                    // --- Play ---
                    _isPlaying = true;
                    _mediaPlayer.Play();
                    _playheadTimer.Start();
                    PlayPauseBtn.Icon = new SymbolIcon(SymbolRegular.Pause24);
                    Log.Write("[DEBUG] TogglePlay: Playing.");
                    long curPos = _mediaPlayer.Time;
                    DiscordRpcService.SetPlaying(_selectedVideoPath, curPos, _videoDurationMs, GetFormattedShowName());
                }
            }
            catch (Exception ex)
            {
                Log.Write($"[DEBUG ERROR] TogglePlay crashed: {ex}");
                _isPlaying = false; // Safety reset
            }
        }

        private long SnapToFrame(long posMs)
        {
            double fd = 1000.0 / _frameRate;
            long frameIdx = (long)Math.Round(posMs / fd);
            return (long)Math.Round(frameIdx * fd);
        }

        private void OnStepBackwardClicked(object sender, RoutedEventArgs e)
        {
            StepFrame(-1);
        }

        private void OnStepForwardClicked(object sender, RoutedEventArgs e)
        {
            StepFrame(1);
        }

        private void StepFrame(int count)
        {
            if (!_isMediaOpened) return;
            double fd = 1000.0 / _frameRate;
            long newPos = (long)(_mediaPlayer.Time + count * fd);
            _mediaPlayer.Time = Math.Max(0, Math.Min(newPos, _videoDurationMs));
            
            // Force update UI
            PlayheadTimer_Tick(null, null);
        }

        private void OnSliderMouseDown(object sender, MouseButtonEventArgs e)
        {
            _isSliderDragging = true;
        }

        private void OnSliderMouseUp(object sender, MouseButtonEventArgs e)
        {
            _isSliderDragging = false;
            _mediaPlayer.Time = (long)PositionSlider.Value;
            PlayheadTimer_Tick(null, null);
        }

        private void OnSliderValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_isSliderDragging)
            {
                TimeLabel.Text = FormatTime((long)PositionSlider.Value);
            }
        }

        private void OnVolumeSliderValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_mediaPlayer != null)
            {
                double volume = VolumeSlider.Value / 100.0;
                _mediaPlayer.Volume = (int)(volume * 100);

                if (VolumeBtn != null)
                {
                    if (volume <= 0.0)
                    {
                        VolumeBtn.Icon = new SymbolIcon(SymbolRegular.SpeakerMute24);
                    }
                    else if (volume < 0.4)
                    {
                        VolumeBtn.Icon = new SymbolIcon(SymbolRegular.Speaker024);
                    }
                    else if (volume < 0.8)
                    {
                        VolumeBtn.Icon = new SymbolIcon(SymbolRegular.Speaker124);
                    }
                    else
                    {
                        VolumeBtn.Icon = new SymbolIcon(SymbolRegular.Speaker224);
                    }
                }
            }
        }

        private void OnVolumeMuteToggle(object sender, RoutedEventArgs e)
        {
            if (_mediaPlayer == null || VolumeSlider == null || VolumeBtn == null) return;

            if (_mediaPlayer.Volume > 0)
            {
                _previousVolume = _mediaPlayer.Volume / 100.0;
                VolumeSlider.Value = 0;
            }
            else
            {
                VolumeSlider.Value = _previousVolume * 100.0;
            }
        }

        // ==========================================
        // TIMELINE EVENTS
        // ==========================================

        private void OnTimelineSeek(long ms)
        {
            if (!_isMediaOpened) return;
            if (ms < 0) ms = 0;
            if (_videoDurationMs > 0 && ms > _videoDurationMs) ms = _videoDurationMs;
            
            _mediaPlayer.Time = ms;
            PlayheadTimer_Tick(null, null);

            // Resync Discord RPC progress bar or pause state
            if (_isPlaying)
            {
                DiscordRpcService.SetPlaying(_selectedVideoPath, ms, _videoDurationMs, GetFormattedShowName());
            }
            else
            {
                DiscordRpcService.SetPaused(_selectedVideoPath, ms, _videoDurationMs, GetFormattedShowName());
            }
        }

        private void OnTimelineDraftCreated(SegmentType type, long start, long end)
        {
            PushUndo();
            _localDrafts[type][0].StartMs = (int)start;
            _localDrafts[type][0].EndMs = (int)end;
            UpdateTimelineWidget();
            UpdateInputs();
        }

        private void OnTimelineDraftStartDragged(SegmentType type, int idx, long ms)
        {
            _localDrafts[type][idx].StartMs = (int)ms;
            UpdateTimelineWidget();
            UpdateInputs();
        }

        private void OnTimelineDraftEndDragged(SegmentType type, int idx, long ms)
        {
            _localDrafts[type][idx].EndMs = (int)ms;
            UpdateTimelineWidget();
            UpdateInputs();
        }

        private void OnTimelineDraftMoved(SegmentType srcType, int idx, SegmentType dstType, long start, long end)
        {
            PushUndo();
            
            // If dragging between rows, remove from src and overwrite dst
            if (srcType != dstType)
            {
                _localDrafts[srcType][idx].StartMs = null;
                _localDrafts[srcType][idx].EndMs = null;
            }

            _localDrafts[dstType][0].StartMs = (int)start;
            _localDrafts[dstType][0].EndMs = (int)end;

            UpdateTimelineWidget();
            UpdateInputs();
        }

        private void OnTimelineDragBegan()
        {
            // Pause playback during visual drags without changing _isPlaying intent
            // (so when drag ends, user can resume if they choose)
            if (_isPlaying)
            {
                TogglePlay();
            }
        }

        private void OnTimelineDragEnded()
        {
            PushUndo();
        }

        private void OnFrameStripSeek(long ms)
        {
            OnTimelineSeek(ms);
        }

        private void OnZoomChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (Timeline != null)
            {
                Timeline.Zoom = ZoomSlider.Value;
            }
        }

        // ==========================================
        // SEGMENT INPUT HANDLERS
        // ==========================================

        private void UpdateDraftFromInputs(SegmentType type, string startText, string endText)
        {
            int? start = ParseTimeInput(startText);
            int? end = ParseTimeInput(endText);

            if (_localDrafts[type][0].StartMs != start || _localDrafts[type][0].EndMs != end)
            {
                PushUndo();
                _localDrafts[type][0].StartMs = start;
                _localDrafts[type][0].EndMs = end;
                UpdateTimelineWidget();
            }
        }

        private void OnIntroInputLostFocus(object sender, RoutedEventArgs e) => UpdateDraftFromInputs(SegmentType.Intro, IntroStartInput.Text, IntroEndInput.Text);
        private void OnRecapInputLostFocus(object sender, RoutedEventArgs e) => UpdateDraftFromInputs(SegmentType.Recap, RecapStartInput.Text, RecapEndInput.Text);
        private void OnCreditsInputLostFocus(object sender, RoutedEventArgs e) => UpdateDraftFromInputs(SegmentType.Credits, CreditsStartInput.Text, CreditsEndInput.Text);
        private void OnPreviewInputLostFocus(object sender, RoutedEventArgs e) => UpdateDraftFromInputs(SegmentType.Preview, PreviewStartInput.Text, PreviewEndInput.Text);

        private void OnSetIntroStartClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Intro][0].StartMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }
        private void OnSetIntroEndClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Intro][0].EndMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }

        private void OnSetRecapStartClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Recap][0].StartMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }
        private void OnSetRecapEndClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Recap][0].EndMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }

        private void OnSetCreditsStartClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Credits][0].StartMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }
        private void OnSetCreditsEndClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Credits][0].EndMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }

        private void OnSetPreviewStartClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Preview][0].StartMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }
        private void OnSetPreviewEndClicked(object? sender, RoutedEventArgs? e) { _localDrafts[SegmentType.Preview][0].EndMs = (int)_mediaPlayer.Time; PushUndo(); UpdateTimelineWidget(); UpdateInputs(); }

        private void OnClearIntroClicked(object sender, RoutedEventArgs e) { ClearDraft(SegmentType.Intro); }
        private void OnClearRecapClicked(object sender, RoutedEventArgs e) { ClearDraft(SegmentType.Recap); }
        private void OnClearCreditsClicked(object sender, RoutedEventArgs e) { ClearDraft(SegmentType.Credits); }
        private void OnClearPreviewClicked(object sender, RoutedEventArgs e) { ClearDraft(SegmentType.Preview); }

        private void ClearDraft(SegmentType type)
        {
            PushUndo();
            _localDrafts[type][0].StartMs = null;
            _localDrafts[type][0].EndMs = null;
            UpdateTimelineWidget();
            UpdateInputs();
        }

        // ==========================================
        // METADATA & API INTEGRATION
        // ==========================================

        private void OnNumberValidation(object sender, TextCompositionEventArgs e)
        {
            e.Handled = !int.TryParse(e.Text, out _);
        }

        private void OnApiKeysChanged(object sender, RoutedEventArgs e)
        {
            SaveApiKeys();
        }

        private void AutoLookupMedia()
        {
            if (string.IsNullOrEmpty(_selectedVideoPath)) return;

            string filename = Path.GetFileNameWithoutExtension(_selectedVideoPath);
            var hint = FilenameMediaParser.Parse(filename);

            SearchTitleInput.Text = hint.Title;
            LookupYearInput.Text = hint.Year?.ToString() ?? string.Empty;
            LookupSeasonInput.Text = hint.Season?.ToString() ?? string.Empty;
            LookupEpisodeInput.Text = hint.Episode?.ToString() ?? string.Empty;

            _ = PerformLookupAsync(hint);
        }

        private void OnAutoLookupClicked(object sender, RoutedEventArgs e)
        {
            AutoLookupMedia();
        }

        private void OnSearchTitleClicked(object sender, RoutedEventArgs e)
        {
            TriggerSearch();
        }

        private void OnSearchTitleKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter) TriggerSearch();
        }

        private void TriggerSearch()
        {
            int? year = int.TryParse(LookupYearInput.Text, out var y) ? y : null;
            int? season = int.TryParse(LookupSeasonInput.Text, out var s) ? s : null;
            int? episode = int.TryParse(LookupEpisodeInput.Text, out var ep) ? ep : null;

            var hint = new ParsedFilenameHint
            {
                Title = SearchTitleInput.Text,
                Year = year,
                Season = season,
                Episode = episode
            };

            _ = PerformLookupAsync(hint);
        }

        private string? GetFormattedShowName()
        {
            if (_selectedMetadata == null) return null;
            
            string name = _selectedMetadata.Title;
            if (_selectedMetadata.MediaType == Segmenter.Models.MediaType.Movie && _selectedMetadata.MatchedYear.HasValue)
            {
                return $"{name} ({_selectedMetadata.MatchedYear.Value})";
            }
            if (_selectedMetadata.MediaType == Segmenter.Models.MediaType.Tv)
            {
                if (_selectedMetadata.Season.HasValue && _selectedMetadata.Episode.HasValue)
                    return $"{name} (S{_selectedMetadata.Season.Value:D2}E{_selectedMetadata.Episode.Value:D2})";
                if (_selectedMetadata.Season.HasValue)
                    return $"{name} (Season {_selectedMetadata.Season.Value})";
            }
            return name;
        }

        private async Task PerformLookupAsync(ParsedFilenameHint hint)
        {
            StatusText("Looking up media on TMDb...");
            try
            {
                var results = await _tmdbClient.ResolveHintsAsync(hint, TmdbTokenInput.Password);
                _currentLookupResults = results;

                LookupResultsCombo.Items.Clear();
                foreach (var r in results)
                {
                    string yearStr = r.MatchedYear != null ? $" ({r.MatchedYear})" : string.Empty;
                    string typeStr = r.MediaType.GetDisplayName();
                    LookupResultsCombo.Items.Add($"{r.Title}{yearStr} [{typeStr}]");
                }

                if (results.Count > 0)
                {
                    LookupResultsCombo.SelectedIndex = 0;
                }
                else
                {
                    PosterImage.Source = null;
                    MetadataInfoText.Text = "No matches found on TMDb.";
                    StatusText("TMDb search complete (no results)");
                }
            }
            catch (Exception ex)
            {
                StatusText($"TMDb lookup failed: {ex.Message}", true);
            }
        }

        private void OnLookupResultSelected(object sender, SelectionChangedEventArgs e)
        {
            int idx = LookupResultsCombo.SelectedIndex;
            if (idx >= 0 && idx < _currentLookupResults.Count)
            {
                _selectedMetadata = _currentLookupResults[idx];
                MetadataInfoText.Text = $"Title: {_selectedMetadata.Title}\n" +
                                       $"TMDB ID: {_selectedMetadata.TmdbId}\n" +
                                       $"IMDB ID: {_selectedMetadata.ImdbId ?? "N/A"}\n" +
                                       $"Season: {_selectedMetadata.Season?.ToString() ?? "N/A"}\n" +
                                       $"Episode: {_selectedMetadata.Episode?.ToString() ?? "N/A"}";

                if (!string.IsNullOrEmpty(_selectedMetadata.PosterUrl))
                {
                    try
                    {
                        PosterImage.Source = new BitmapImage(new Uri(_selectedMetadata.PosterUrl));
                    }
                    catch
                    {
                        PosterImage.Source = null;
                    }
                }
                else
                {
                    PosterImage.Source = null;
                }

                // Debounce server segments fetch
                _lookupDebounceTimer.Stop();
                _lookupDebounceTimer.Start();
            }
        }

        private async Task FetchServerSegmentsAsync()
        {
            if (_selectedMetadata == null) return;
            StatusText("Fetching existing segments from database...");

            try
            {
                // Clear server segments
                _serverSegments = Enum.GetValues(typeof(SegmentType))
                    .Cast<SegmentType>()
                    .ToDictionary(t => t, t => new List<SegmentRange>());

                // 1. Fetch from TheIntroDB
                var query = new MediaQuery
                {
                    TmdbId = _selectedMetadata.TmdbId,
                    ImdbId = _selectedMetadata.ImdbId,
                    Season = _selectedMetadata.Season,
                    Episode = _selectedMetadata.Episode,
                    DurationMs = (int)_videoDurationMs
                };

                try
                {
                    var (payload, usage) = await _theIntroDbClient.FetchMediaAsync(query, TheIntroDbTokenInput.Password);
                    ApiLimitsText.Text = usage.ShortDescription;

                    // Parse TheIntroDB segments
                    var segments = payload["segments"]?.AsArray();
                    if (segments != null)
                    {
                        foreach (var s in segments)
                        {
                            if (s == null) continue;
                            string typeStr = s["segment"]?.ToString() ?? string.Empty;
                            if (Enum.TryParse<SegmentType>(typeStr, true, out var segType))
                            {
                                int start = s["start_ms"]?.GetValue<int>() ?? 0;
                                int? end = s["end_ms"]?.GetValue<int>();
                                _serverSegments[segType].Add(new SegmentRange(start, end));
                            }
                        }
                    }
                }
                catch (APIClientException ex)
                {
                    // 404 is normal for missing database items
                    if (ex.StatusCode != 404) throw;
                }

                // 2. Fetch from IntroDB (TV episodes only)
                if (_selectedMetadata.MediaType == Segmenter.Models.MediaType.Tv && !string.IsNullOrEmpty(_selectedMetadata.ImdbId) && _selectedMetadata.Season != null && _selectedMetadata.Episode != null)
                {
                    try
                    {
                        var (payload, _) = await _introDbClient.FetchSegmentsAsync(
                            _selectedMetadata.ImdbId,
                            _selectedMetadata.Season.Value,
                            _selectedMetadata.Episode.Value,
                            IntroDbApiKeyInput.Password
                        );

                        // Parse IntroDB segments
                        var segments = payload["segments"]?.AsArray();
                        if (segments != null)
                        {
                            foreach (var s in segments)
                            {
                                if (s == null) continue;
                                string typeStr = s["segment_type"]?.ToString() ?? string.Empty;
                                SegmentType? segType = null;
                                if (typeStr == "intro") segType = SegmentType.Intro;
                                else if (typeStr == "recap") segType = SegmentType.Recap;
                                else if (typeStr == "outro") segType = SegmentType.Credits;

                                if (segType != null)
                                {
                                    double startSec = s["start_sec"]?.GetValue<double>() ?? 0;
                                    double endSec = s["end_sec"]?.GetValue<double>() ?? 0;
                                    _serverSegments[segType.Value].Add(new SegmentRange((int)(startSec * 1000), (int)(endSec * 1000)));
                                }
                            }
                        }
                    }
                    catch (APIClientException ex)
                    {
                        if (ex.StatusCode != 404) throw;
                    }
                }

                UpdateTimelineWidget();
                StatusText("Fetched existing segments successfully!");
            }
            catch (Exception ex)
            {
                StatusText($"Failed to fetch segments: {ex.Message}", true);
            }
        }

        private async void OnUploadIntroClicked(object sender, RoutedEventArgs e) => await UploadSegmentAsync(SegmentType.Intro);
        private async void OnUploadRecapClicked(object sender, RoutedEventArgs e) => await UploadSegmentAsync(SegmentType.Recap);
        private async void OnUploadCreditsClicked(object sender, RoutedEventArgs e) => await UploadSegmentAsync(SegmentType.Credits);
        private async void OnUploadPreviewClicked(object sender, RoutedEventArgs e) => await UploadSegmentAsync(SegmentType.Preview);

        private async Task UploadSegmentAsync(SegmentType type)
        {
            if (_selectedMetadata == null)
            {
                MessageBox.Show("Please lookup and select TMDb/IMDb metadata before uploading.", "Metadata Missing", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var draft = _localDrafts[type][0];
            if (draft.IsEmpty)
            {
                MessageBox.Show($"Concept draft for {type.GetDisplayName()} is empty.", "Draft Empty", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var subDraft = new SubmissionDraft
            {
                TmdbId = _selectedMetadata.TmdbId,
                ImdbId = _selectedMetadata.ImdbId,
                MediaType = _selectedMetadata.MediaType,
                Segment = type,
                Season = _selectedMetadata.Season,
                Episode = _selectedMetadata.Episode,
                StartMs = draft.StartMs,
                EndMs = draft.EndMs <= 0 ? (int)_videoDurationMs : draft.EndMs,
                VideoDurationMs = (int)_videoDurationMs
            };

            StatusText($"Uploading {type.GetDisplayName()} segment...");
            AsyncProgressBar.Visibility = Visibility.Visible;
            AsyncProgressBar.Value = 50;

            try
            {
                // 1. Upload to TheIntroDB
                var theIntroDbPayload = SegmentValidator.MakeTheIntroDbSubmissionRequest(subDraft);
                string theIntroDbKey = TheIntroDbTokenInput.Password;
                if (string.IsNullOrWhiteSpace(theIntroDbKey))
                {
                    throw new Exception("TheIntroDB Access Token is required for uploading.");
                }

                var (_, usage) = await _theIntroDbClient.SubmitAsync(theIntroDbPayload, theIntroDbKey);
                ApiLimitsText.Text = usage.ShortDescription;

                // 2. Upload to IntroDB (TV episodes only, and only for Intro/Recap/Outro)
                if (subDraft.MediaType == Segmenter.Models.MediaType.Tv && (type == SegmentType.Intro || type == SegmentType.Recap || type == SegmentType.Credits))
                {
                    string introDbKey = IntroDbApiKeyInput.Password;
                    if (!string.IsNullOrWhiteSpace(introDbKey))
                    {
                        var introDbPayload = SegmentValidator.MakeIntroDbSubmissionRequest(subDraft);
                        await _introDbClient.SubmitAsync(introDbPayload, introDbKey);
                    }
                }

                StatusText($"{type.GetDisplayName()} segment uploaded successfully!");
                MessageBox.Show($"{type.GetDisplayName()} segment uploaded successfully!", "Upload Complete", MessageBoxButton.OK, MessageBoxImage.Information);
                
                // Refresh server segments
                _ = FetchServerSegmentsAsync();
            }
            catch (SegmentValidationError ex)
            {
                StatusText($"Validation failed: {ex.Message}", true);
                MessageBox.Show(ex.Message, "Validation Error", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            catch (Exception ex)
            {
                StatusText($"Upload failed: {ex.Message}", true);
                MessageBox.Show($"Upload failed: {ex.Message}", "Upload Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                AsyncProgressBar.Visibility = Visibility.Collapsed;
            }
        }

        private async void OnUploadAllClicked(object sender, RoutedEventArgs e)
        {
            if (_selectedMetadata == null)
            {
                MessageBox.Show("Please lookup and select TMDb/IMDb metadata before uploading.", "Metadata Missing", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            int count = 0;
            foreach (SegmentType type in Enum.GetValues(typeof(SegmentType)))
            {
                if (!_localDrafts[type][0].IsEmpty)
                {
                    try
                    {
                        await UploadSegmentAsync(type);
                        count++;
                    }
                    catch { }
                }
            }

            if (count == 0)
            {
                MessageBox.Show("No active concept drafts found to upload.", "Upload All", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }

        private void OnUndoClicked(object sender, RoutedEventArgs e) => Undo();
        private void OnRedoClicked(object sender, RoutedEventArgs e) => Redo();

        private void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            Log.Write($"[DEBUG] Key pressed: {e.Key}, SystemKey: {e.SystemKey}, Modifiers: {Keyboard.Modifiers}");
            // Global Keyboard Shortcuts matching Python
            if (e.Key == Key.Space && !(Keyboard.FocusedElement is System.Windows.Controls.TextBox || Keyboard.FocusedElement is Wpf.Ui.Controls.TextBox || Keyboard.FocusedElement is System.Windows.Controls.PasswordBox || Keyboard.FocusedElement is Wpf.Ui.Controls.PasswordBox))
            {
                TogglePlay();
                e.Handled = true;
            }
            else if (e.Key == Key.Left && Keyboard.Modifiers == ModifierKeys.None)
            {
                StepFrame(-1);
                e.Handled = true;
            }
            else if (e.Key == Key.Right && Keyboard.Modifiers == ModifierKeys.None)
            {
                StepFrame(1);
                e.Handled = true;
            }
            else if (e.Key == Key.I && Keyboard.Modifiers == ModifierKeys.None)
            {
                OnSetIntroStartClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.I && Keyboard.Modifiers == ModifierKeys.Shift)
            {
                OnSetIntroEndClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.R && Keyboard.Modifiers == ModifierKeys.None)
            {
                OnSetRecapStartClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.R && Keyboard.Modifiers == ModifierKeys.Shift)
            {
                OnSetRecapEndClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.None)
            {
                OnSetCreditsStartClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Shift)
            {
                OnSetCreditsEndClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.P && Keyboard.Modifiers == ModifierKeys.None)
            {
                OnSetPreviewStartClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.P && Keyboard.Modifiers == ModifierKeys.Shift)
            {
                OnSetPreviewEndClicked(null, null);
                e.Handled = true;
            }
            else if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control)
            {
                Undo();
                e.Handled = true;
            }
            else if (e.Key == Key.Y && Keyboard.Modifiers == ModifierKeys.Control)
            {
                Redo();
                e.Handled = true;
            }
        }

        private void OnScanDirectoryClicked(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFolderDialog
            {
                Title = "Select Season Directory for RCD Scan"
            };

            if (dialog.ShowDialog() == true)
            {
                string videoDir = dialog.FolderName;
                
                // Open RCD Scan Progress Dialog
                var rcdDialog = new RcdProgressDialog(videoDir, this);
                rcdDialog.Owner = this;
                if (rcdDialog.ShowDialog() == true)
                {
                    // Import results into current loaded video if matching
                    var results = rcdDialog.Results;
                    if (results != null && !string.IsNullOrEmpty(_selectedVideoPath))
                    {
                        string currentVideoName = Path.GetFileName(_selectedVideoPath);
                        if (results.TryGetValue(currentVideoName, out var detections))
                        {
                            PushUndo();
                            
                            // Map RCD detections
                            // By standard convention: RCD detects intros at the beginning and outros/credits at the end
                            // Clean existing drafts
                            foreach (var type in Enum.GetValues(typeof(SegmentType)).Cast<SegmentType>())
                            {
                                _localDrafts[type][0].StartMs = null;
                                _localDrafts[type][0].EndMs = null;
                            }

                            foreach (var det in detections)
                            {
                                int startMs = (int)(det.Start * 1000);
                                int endMs = (int)(det.End * 1000);
                                double centerPct = ((det.Start + det.End) / 2.0) / (_videoDurationMs / 1000.0);

                                if (centerPct < 0.25)
                                {
                                    // Intro or Recap
                                    _localDrafts[SegmentType.Intro][0].StartMs = startMs;
                                    _localDrafts[SegmentType.Intro][0].EndMs = endMs;
                                }
                                else if (centerPct > 0.75)
                                {
                                    // Credits
                                    _localDrafts[SegmentType.Credits][0].StartMs = startMs;
                                    _localDrafts[SegmentType.Credits][0].EndMs = endMs;
                                }
                            }

                            UpdateTimelineWidget();
                            UpdateInputs();
                            StatusText("Imported RCD detections successfully!");
                        }
                    }
                }
            }
        }

        private void Window_DragOver(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                e.Effects = DragDropEffects.Copy;
            }
            else
            {
                e.Effects = DragDropEffects.None;
            }
            e.Handled = true;
        }

        private void Window_Drop(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
                if (files.Length > 0)
                {
                    string file = files[0];
                    Log.Write($"[DEBUG] Window_Drop triggered. File: {file}");
                    string ext = Path.GetExtension(file).ToLower();
                    if (ext == ".mp4" || ext == ".mkv" || ext == ".avi" || ext == ".mov" || ext == ".m4v" || ext == ".webm")
                    {
                        LoadVideo(file);
                    }
                    else
                    {
                        Log.Write($"[DEBUG WARNING] Dragged file has unsupported extension: {ext}");
                    }
                }
            }
        }
    }
}
