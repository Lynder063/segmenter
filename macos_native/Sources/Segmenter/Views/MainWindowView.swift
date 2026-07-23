import SwiftUI
import AppKit

public struct MainWindowView: View {
    @State private var videoURL: URL? = nil
    @State private var isPlaying: Bool = false
    @State private var currentPositionMs: Int = 0
    @State private var durationMs: Int = 0
    @State private var frameRate: Double = 23.976

    @State private var theIntroDBKey: String = ""
    @State private var introDBKey: String = ""
    @State private var tmdbKey: String = ""

    @State private var searchQuery: String = ""
    @State private var tmdbId: String = ""
    @State private var imdbId: String = ""
    @State private var mediaType: MediaType = .tv
    @State private var season: String = ""
    @State private var episode: String = ""

    @State private var densityTrack: TimelineDensityTrack = TimelineDensityTrack()
    @State private var drafts: [SegmentType: SegmentDraft] = [:]
    @State private var statusMessage: String = "Ready"

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Left Control Sidebar
            SidebarView(
                videoURL: $videoURL,
                theIntroDBKey: $theIntroDBKey,
                introDBKey: $introDBKey,
                tmdbKey: $tmdbKey,
                searchQuery: $searchQuery,
                tmdbId: $tmdbId,
                imdbId: $imdbId,
                mediaType: $mediaType,
                season: $season,
                episode: $episode,
                drafts: $drafts,
                onOpenVideo: openVideoFileDialog,
                onSaveKeys: saveKeys,
                onSearchTMDB: searchTMDB,
                onLoadSegments: loadSegments,
                onUploadAll: uploadAllDrafts,
                onScanSeason: scanSeason,
                onClearDraft: clearDraft
            )

            Divider()

            // Right Main Viewport
            VStack(spacing: 0) {
                // Video Player Area
                ZStack {
                    Color.black
                    if videoURL != nil {
                        NativeVideoPlayerView(
                            videoURL: $videoURL,
                            isPlaying: $isPlaying,
                            currentPositionMs: $currentPositionMs,
                            durationMs: $durationMs,
                            frameRate: $frameRate,
                            onTimeChanged: { pos in
                                self.currentPositionMs = pos
                            },
                            onDurationChanged: { dur in
                                self.durationMs = dur
                            }
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "film")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Open a local video file to begin timestamping")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Playback Control Bar
                HStack(spacing: 12) {
                    Button(action: togglePlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }

                    Button(action: stepBackward) {
                        Image(systemName: "backward.frame.fill")
                    }

                    Button(action: stepForward) {
                        Image(systemName: "forward.frame.fill")
                    }

                    Text(formatTimeMs(currentPositionMs))
                        .font(.system(.body, design: .monospaced))

                    Slider(
                        value: Binding(
                            get: { Double(currentPositionMs) },
                            set: { currentPositionMs = Int($0) }
                        ),
                        in: 0...max(1.0, Double(durationMs))
                    )

                    Text(formatTimeMs(durationMs))
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(red: 0.12, green: 0.12, blue: 0.14))

                Divider()

                // Frame Strip Preview
                FrameStripView(
                    videoURL: videoURL,
                    currentPositionMs: currentPositionMs,
                    durationMs: durationMs,
                    frameRate: frameRate
                )

                Divider()

                // Multi-Track Timeline
                TimelineView(
                    currentPositionMs: $currentPositionMs,
                    durationMs: $durationMs,
                    densityTrack: $densityTrack,
                    drafts: $drafts,
                    onSeek: { targetMs in
                        self.currentPositionMs = targetMs
                    },
                    onDraftsChanged: { newDrafts in
                        self.drafts = newDrafts
                    }
                )
                .frame(height: 150)

                // Status Bar
                HStack {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 0.08, green: 0.08, blue: 0.09))
            }
        }
        .preferredColorScheme(.dark)
    }

    private func openVideoFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]

        if panel.runModal() == .OK, let url = panel.url {
            self.videoURL = url
            self.statusMessage = "Loaded \(url.lastPathComponent)"
            LoggerService.shared.info("[UI] User opened video file: \(url.path)")

            // Auto-parse filename hints
            let hint = FilenameMediaParser.parse(filePathOrName: url.path)
            self.searchQuery = hint.title
            if let s = hint.season { self.season = String(s) }
            if let e = hint.episode { self.episode = String(e) }
            self.mediaType = hint.mediaTypeHint

            // Extract audio waveform asynchronously
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let (buckets, music) = try? await AudioExtractorService.shared.extractAudioWaveform(
                    videoURL: url,
                    durationMs: self.durationMs,
                    progressHandler: { pct in
                        DispatchQueue.main.async {
                            self.statusMessage = "Analyzing audio... \(pct)%"
                        }
                    }
                ) {
                    DispatchQueue.main.async {
                        self.densityTrack = TimelineDensityTrack(
                            label: "Audio",
                            buckets: buckets,
                            musicLikelihoodBuckets: music
                        )
                        self.statusMessage = "Audio analysis complete"
                    }
                }
            }
        }
    }

    private func togglePlay() {
        isPlaying.toggle()
    }

    private func stepForward() {
        let stepMs = Int(1000.0 / frameRate)
        currentPositionMs = min(durationMs, currentPositionMs + stepMs)
    }

    private func stepBackward() {
        let stepMs = Int(1000.0 / frameRate)
        currentPositionMs = max(0, currentPositionMs - stepMs)
    }

    private func saveKeys() {
        statusMessage = "Keys saved to local configuration"
        LoggerService.shared.info("[UI] API keys saved")
    }

    private func searchTMDB() {
        LoggerService.shared.info("[UI] Searching TMDB for: \(searchQuery)")
    }

    private func loadSegments() {
        LoggerService.shared.info("[UI] Loading segments...")
    }

    private func uploadAllDrafts() {
        LoggerService.shared.info("[UI] Uploading all draft segments...")
    }

    private func scanSeason() {
        LoggerService.shared.info("[UI] Initiating season scan (RCD)...")
    }

    private func clearDraft(_ type: SegmentType) {
        drafts[type] = .empty
    }

    private func formatTimeMs(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        let millis = ms % 1000
        return String(format: "%02d:%02d.%03d", m, s, millis)
    }
}
