using System;
using System.Threading;
using System.Threading.Tasks;
using DiscordRPC;
using DiscordRPC.Logging;

namespace Segmenter.Services
{
    /// <summary>
    /// Manages Discord Rich Presence for Segmenter.
    /// Call Initialize() on startup, Update*() on state changes, Dispose() on exit.
    ///
    /// To use Discord RPC you need a Discord Application ID.
    /// Create one at https://discord.com/developers/applications
    /// and set it in the DISCORD_APP_ID constant below.
    /// </summary>
    public static class DiscordRpcService
    {
        // ---------------------------------------------------------------
        // Replace this with your own Discord Application ID.
        // Create an app at https://discord.com/developers/applications
        // ---------------------------------------------------------------
        private const string DISCORD_APP_ID = "YOUR_DISCORD_APP_ID_HERE";

        private static DiscordRpcClient? _client;
        private static bool _initialized = false;

        // Cached last state so partial updates are possible
        private static string _currentDetails = "Idle";
        private static string _currentState = string.Empty;
        private static DateTime _sessionStart = DateTime.UtcNow;

        private static RichPresence? _queuedPresence;
        private static readonly object _rpcLock = new object();
        private static Timer? _debounceTimer;

        // ---------------------------------------------------------------
        // Lifecycle
        // ---------------------------------------------------------------

        public static void Initialize()
        {
            try
            {
                _client = new DiscordRpcClient(DISCORD_APP_ID)
                {
                    Logger = new NullLogger()
                };

                _client.OnReady += (sender, e) =>
                    Log.Write($"[Discord RPC] Connected as {e.User.Username}");

                _client.OnError += (sender, e) =>
                    Log.Write($"[Discord RPC] Error: {e.Message}");

                _client.OnConnectionFailed += (sender, e) =>
                    Log.Write($"[Discord RPC] Connection failed – Discord is probably not running.");

                _client.Initialize();
                _initialized = true;
                _sessionStart = DateTime.UtcNow;

                _debounceTimer = new Timer(OnDebounceTimer, null, Timeout.Infinite, Timeout.Infinite);

                SetIdle();
                Log.Write("[Discord RPC] Service initialized.");
            }
            catch (Exception ex)
            {
                Log.Write($"[Discord RPC] Initialize failed: {ex.Message}");
            }
        }

        public static void Dispose()
        {
            try
            {
                _debounceTimer?.Dispose();
                _debounceTimer = null;
                _client?.ClearPresence();
                _client?.Dispose();
                _client = null;
                _initialized = false;
                Log.Write("[Discord RPC] Service disposed.");
            }
            catch { }
        }

        // ---------------------------------------------------------------
        // Presence updates
        // ---------------------------------------------------------------

        /// <summary>No video loaded – show "Idle" state.</summary>
        public static void SetIdle()
        {
            UpdatePresence(
                details: "Idle",
                state: "Waiting for video...",
                largeImageKey: "segmenter_logo",
                largeImageText: "Segmenter",
                start: _sessionStart,
                end: null
            );
        }

        /// <summary>Video loaded but not playing.</summary>
        public static void SetVideoLoaded(string videoName, string? formattedShowName = null)
        {
            string details = formattedShowName != null ? formattedShowName : TruncateName(videoName, 60);
            string state = formattedShowName != null ? $"Editing: {TruncateName(videoName, 40)}" : "Editing Segments";
            
            UpdatePresence(
                details: details,
                state: state,
                largeImageKey: "segmenter_logo",
                largeImageText: "Segmenter – Ready",
                start: _sessionStart,
                end: null
            );
        }

        /// <summary>Video is playing.</summary>
        public static void SetPlaying(string videoName, long positionMs, long durationMs, string? formattedShowName = null)
        {
            string details = formattedShowName != null ? formattedShowName : TruncateName(videoName, 60);
            string state = formattedShowName != null ? $"▶ Segmenting: {TruncateName(videoName, 40)}" : "▶ Editing Segments";

            // Enable Discord's native progress bar by sending Start and End timestamps.
            var start = DateTime.UtcNow - TimeSpan.FromMilliseconds(positionMs);
            var end = start + TimeSpan.FromMilliseconds(durationMs);

            UpdatePresence(
                details: details,
                state: state,
                largeImageKey: "segmenter_logo",
                largeImageText: "Segmenter – Playing",
                start: start,
                end: end
            );
        }

        /// <summary>Video is paused.</summary>
        public static void SetPaused(string videoName, long positionMs, long durationMs, string? formattedShowName = null)
        {
            string details = formattedShowName != null ? formattedShowName : TruncateName(videoName, 60);
            string timeStr = FormatDuration(positionMs) + " / " + FormatDuration(durationMs);
            string state = formattedShowName != null ? $"⏸ Segmenting: {TruncateName(videoName, 30)} [{timeStr}]" : $"⏸ [{timeStr}]";

            UpdatePresence(
                details: details,
                state: state,
                largeImageKey: "segmenter_logo",
                largeImageText: "Segmenter – Paused",
                start: _sessionStart,
                end: null
            );
        }

        /// <summary>Audio analysis is running in the background.</summary>
        public static void SetAnalyzing(string videoName)
        {
            UpdatePresence(
                details: "Analyzing audio waveform...",
                state: $"🔊 {TruncateName(videoName, 60)}",
                largeImageKey: "segmenter_logo",
                largeImageText: "Segmenter – Analyzing",
                start: _sessionStart,
                end: null
            );
        }

        // ---------------------------------------------------------------
        // Private helpers
        // ---------------------------------------------------------------

        private static void UpdatePresence(
            string details,
            string state,
            string largeImageKey,
            string largeImageText,
            DateTime? start,
            DateTime? end)
        {
            if (!_initialized || _client == null) return;

            try
            {
                var presence = new RichPresence
                {
                    Details = details,
                    State = state,
                    Assets = new Assets
                    {
                        LargeImageKey = largeImageKey,
                        LargeImageText = largeImageText,
                        SmallImageKey = "segmenter_logo",
                        SmallImageText = "Video Segmenter"
                    },
                    Buttons = new DiscordRPC.Button[]
                    {
                        new DiscordRPC.Button { Label = "Download Segmenter", Url = "https://github.com/lynder063/segmenter" }
                    }
                };

                if (start.HasValue)
                {
                    if (presence.Timestamps == null) presence.Timestamps = new Timestamps();
                    presence.Timestamps.Start = start.Value;
                }

                if (end.HasValue)
                {
                    if (presence.Timestamps == null) presence.Timestamps = new Timestamps();
                    presence.Timestamps.End = end.Value;
                }

                lock (_rpcLock)
                {
                    _queuedPresence = presence;
                }
                
                // Debounce RPC calls by 500ms so we don't spam IPC when dragging the slider
                _debounceTimer?.Change(500, Timeout.Infinite);
            }
            catch (Exception ex)
            {
                Log.Write($"[Discord RPC] UpdatePresence failed: {ex.Message}");
            }
        }

        private static void OnDebounceTimer(object? stateObj)
        {
            if (!_initialized || _client == null) return;
            
            RichPresence? p = null;
            lock (_rpcLock)
            {
                p = _queuedPresence;
                _queuedPresence = null;
            }

            if (p != null)
            {
                try
                {
                    _client.SetPresence(p);
                }
                catch (Exception ex)
                {
                    Log.Write($"[Discord RPC] SetPresence failed: {ex.Message}");
                }
            }
        }

        private static string TruncateName(string name, int maxLen)
        {
            if (string.IsNullOrEmpty(name)) return name;
            // Strip path if full path provided
            int sepIdx = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
            if (sepIdx >= 0) name = name[(sepIdx + 1)..];
            // Strip extension
            int dotIdx = name.LastIndexOf('.');
            if (dotIdx > 0) name = name[..dotIdx];
            // Truncate
            if (name.Length > maxLen) name = name[..maxLen] + "…";
            return name;
        }

        private static string FormatDuration(long ms)
        {
            var ts = TimeSpan.FromMilliseconds(ms);
            if (ts.TotalHours >= 1)
                return $"{(int)ts.TotalHours}:{ts.Minutes:02}:{ts.Seconds:02}";
            return $"{ts.Minutes}:{ts.Seconds:02}";
        }
    }
}
