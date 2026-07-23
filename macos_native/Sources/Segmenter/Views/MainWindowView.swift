import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

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
                onJumpToSegment: jumpToSegment,
                onClearDraft: clearDraft
            )

            Divider()

            // Right Main Viewport
            VStack(spacing: 0) {
                // Video Player Area (LibVLC Engine for 100% MKV, x265, HEVC, DTS, AC3 support)
                ZStack {
                    Color.black
                    if videoURL != nil {
                        VLCVideoPlayerView(
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
                            Text("Open a local video file (MKV, MP4, AVI, MOV) to begin timestamping")
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
        .onAppear {
            loadKeychainKeys()
        }
    }

    private func loadKeychainKeys() {
        if let key = KeychainService.shared.loadKey(forAccount: "theintrodb_key") {
            theIntroDBKey = key
        }
        if let key = KeychainService.shared.loadKey(forAccount: "introdb_key") {
            introDBKey = key
        }
        if let key = KeychainService.shared.loadKey(forAccount: "tmdb_key") {
            tmdbKey = key
        }
    }

    private func saveKeys() {
        _ = KeychainService.shared.saveKey(theIntroDBKey, forAccount: "theintrodb_key")
        _ = KeychainService.shared.saveKey(introDBKey, forAccount: "introdb_key")
        _ = KeychainService.shared.saveKey(tmdbKey, forAccount: "tmdb_key")

        statusMessage = "API Keys saved securely to macOS Keychain"
        LoggerService.shared.info("[UI] API keys saved to macOS Keychain")
    }

    private func jumpToSegment(_ type: SegmentType) {
        if let draft = drafts[type], let start = draft.startMs {
            self.currentPositionMs = start
            self.statusMessage = "Jumped playhead to \(type.displayName) start (\(formatTimeMs(start)))"
        }
    }


    private func openVideoFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true

        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item]
        if let mkvType = UTType(filenameExtension: "mkv") { types.append(mkvType) }
        if let matroskaType = UTType("public.matroska-video") { types.append(matroskaType) }
        if let aviType = UTType(filenameExtension: "avi") { types.append(aviType) }
        if let webmType = UTType(filenameExtension: "webm") { types.append(webmType) }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, let rawUrl = panel.url {
            // Set videoURL IMMEDIATELY — instant LibVLC 0ms playback start!
            self.videoURL = rawUrl
            self.statusMessage = "Loaded \(rawUrl.lastPathComponent)"
            LoggerService.shared.info("[UI] User opened video file with LibVLC engine: \(rawUrl.path)")

            // Auto-parse filename hints
            let hint = FilenameMediaParser.parse(filePathOrName: rawUrl.path)
            self.searchQuery = hint.title
            if let s = hint.season { self.season = String(s) }
            if let e = hint.episode { self.episode = String(e) }
            self.mediaType = hint.mediaTypeHint

            Task.detached(priority: .userInitiated) {
                // 1. Inspect metadata via ffprobe/AVFoundation in background
                let initialDur = self.durationMs
                var currentDurMs = initialDur

                if let meta = await FFmpegService.shared.inspectMedia(url: rawUrl) {
                    if meta.durationMs > 0 { currentDurMs = meta.durationMs }
                    await MainActor.run {
                        if meta.durationMs > 0 { self.durationMs = meta.durationMs }
                        if meta.frameRate > 0 { self.frameRate = meta.frameRate }
                    }
                }

                // 2. Extract audio waveform in background thread (<0.3s)
                let targetDuration = currentDurMs > 0 ? currentDurMs : 1800_000
                if let (buckets, music) = try? await AudioExtractorService.shared.extractAudioWaveform(
                    videoURL: rawUrl,
                    durationMs: targetDuration,
                    progressHandler: { pct in
                        DispatchQueue.main.async {
                            self.statusMessage = "Analyzing audio... \(pct)%"
                        }
                    }
                ) {
                    await MainActor.run {
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Season Directory to Fingerprint (RCD)"

        if panel.runModal() == .OK, let dirURL = panel.url {
            LoggerService.shared.info("[UI] Initiating season scan (RCD) for directory: \(dirURL.path)")
            self.statusMessage = "Starting season fingerprinting scan..."

            Task {
                do {
                    let results = try await RCDEngineService.shared.scanSeason(directoryURL: dirURL) { statusMsg, pct in
                        DispatchQueue.main.async {
                            self.statusMessage = "\(statusMsg) (\(pct)%)"
                        }
                    }

                    await MainActor.run {
                        self.statusMessage = "Season scan complete! Found matches for \(results.count) episodes"

                        // Apply detected timestamps to current draft if current video matches
                        if let currentName = self.videoURL?.lastPathComponent,
                           let matches = results[currentName], let first = matches.first {
                            let startMs = Int(first.startSec * 1000.0)
                            let endMs = Int(first.endSec * 1000.0)
                            self.drafts[.intro] = SegmentDraft(startMs: startMs, endMs: endMs)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "Season scan error: \(error.localizedDescription)"
                    }
                }
            }
        }
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
