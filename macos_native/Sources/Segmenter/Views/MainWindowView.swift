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
                onSetSegmentStart: setSegmentStart,
                onSetSegmentEnd: setSegmentEnd,
                onJumpToSegment: jumpToSegment,
                onClearDraft: clearDraft
            )
            .frame(width: 320)
            .layoutPriority(1)

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
                    frameRate: frameRate,
                    onSeek: { targetMs in
                        self.currentPositionMs = targetMs
                    }
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
        .frame(minWidth: 1000, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            loadKeychainKeys()
            setupKeyboardMonitor()
        }
    }



    private func setSegmentStart(for type: SegmentType) {
        var draft = drafts[type] ?? SegmentDraft()
        draft.startMs = currentPositionMs
        drafts[type] = draft
        statusMessage = "Set \(type.displayName) start: \(formatTimeMs(currentPositionMs))"
    }

    private func setSegmentEnd(for type: SegmentType) {
        var draft = drafts[type] ?? SegmentDraft()
        draft.endMs = currentPositionMs
        drafts[type] = draft
        statusMessage = "Set \(type.displayName) end: \(formatTimeMs(currentPositionMs))"
    }

    private func setupKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                if event.keyCode == 53 || event.keyCode == 36 { // Escape (53) or Return (36)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return event
            }

            let isShift = event.modifierFlags.contains(.shift)
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch event.keyCode {
            case 53: // Escape key clears text focus
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            case 49: // Space
                togglePlay()
                return nil
            case 123: // Left Arrow
                stepBackward()
                return nil
            case 124: // Right Arrow
                stepForward()
                return nil
            default:
                break
            }


            switch char {
            case "i":
                if isShift { setSegmentEnd(for: .intro) } else { setSegmentStart(for: .intro) }
                return nil
            case "r":
                if isShift { setSegmentEnd(for: .recap) } else { setSegmentStart(for: .recap) }
                return nil
            case "c":
                if isShift { setSegmentEnd(for: .credits) } else { setSegmentStart(for: .credits) }
                return nil
            case "p":
                if isShift { setSegmentEnd(for: .preview) } else { setSegmentStart(for: .preview) }
                return nil
            case ",":
                stepBackward()
                return nil
            case ".":
                stepForward()
                return nil
            default:
                return event
            }
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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

            // Auto-load cached RCD segments if season autoscan was performed earlier
            loadCachedRCDSegments(for: rawUrl)


            let initialDur = self.durationMs

            Task.detached(priority: .userInitiated) {
                // 1. Inspect metadata via ffprobe/AVFoundation in background thread
                var currentDurMs = initialDur
                if let meta = await FFmpegService.shared.inspectMedia(url: rawUrl) {
                    if meta.durationMs > 0 { currentDurMs = meta.durationMs }
                    await MainActor.run {
                        if meta.durationMs > 0 { self.durationMs = meta.durationMs }
                        if meta.frameRate > 0 { self.frameRate = meta.frameRate }
                    }
                }

                // 2. Extract audio waveform in background thread (<0.3s)
                let (buckets, music) = await AudioExtractorService.shared.extractAudioWaveform(
                    videoURL: rawUrl,
                    durationMs: currentDurMs,
                    progressHandler: { pct in
                        DispatchQueue.main.async {
                            self.statusMessage = "Analyzing audio... \(pct)%"
                        }
                    }
                )

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
        let keyToUse = tmdbKey.trimmingCharacters(in: .whitespaces)
        guard !keyToUse.isEmpty else {
            statusMessage = "Error: TMDB API Key is missing. Enter TMDB Key in sidebar."
            return
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)
        let trimmedId = tmdbId.trimmingCharacters(in: .whitespaces)

        // If user provided a numeric TMDB ID directly in either field
        if let numericId = Int(trimmedId.isEmpty ? trimmedQuery : trimmedId) {
            statusMessage = "Fetching TMDB ID \(numericId)..."
            Task {
                do {
                    let result = try await TMDBClient.shared.fetchByTMDBId(tmdbId: numericId, mediaType: mediaType, apiKey: keyToUse)
                    await MainActor.run {
                        self.tmdbId = String(numericId)
                        if let imdb = result.imdbId {
                            self.imdbId = imdb
                        }
                        self.statusMessage = "Matched TMDB ID \(numericId): \(result.title)"
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "TMDB ID Error: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        guard !trimmedQuery.isEmpty else {
            statusMessage = "Please enter title or TMDB ID to search"
            return
        }

        statusMessage = "Searching TMDB for '\(trimmedQuery)'..."
        Task {
            do {
                let results = try await TMDBClient.shared.searchByTitle(query: trimmedQuery, mediaType: mediaType, apiKey: keyToUse)
                await MainActor.run {
                    if let first = results.first {
                        self.tmdbId = String(first.tmdbId)
                        if let imdb = first.imdbId {
                            self.imdbId = imdb
                        }
                        self.statusMessage = "Found '\(first.title)' (TMDB ID: \(first.tmdbId))"
                    } else {
                        self.statusMessage = "No TMDB results found for '\(trimmedQuery)'"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "TMDB Search Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadSegments() {
        guard let tmdbInt = Int(tmdbId.trimmingCharacters(in: .whitespaces)) else {
            statusMessage = "Error: Specify TMDB ID to load segments"
            return
        }

        let seasonNum = Int(season.trimmingCharacters(in: .whitespaces))
        let epNum = Int(episode.trimmingCharacters(in: .whitespaces))
        let imdbStr = imdbId.trimmingCharacters(in: .whitespaces)

        statusMessage = "Fetching segments from database..."
        let query = MediaQuery(
            tmdbId: tmdbInt,
            imdbId: imdbStr.isEmpty ? nil : imdbStr,
            season: seasonNum,
            episode: epNum,
            durationMs: durationMs > 0 ? durationMs : nil
        )

        let client = TheIntroDBClient()
        let apiKey = theIntroDBKey.isEmpty ? introDBKey : theIntroDBKey

        Task {
            do {
                let (response, _) = try await client.fetchMedia(query: query, apiKey: apiKey)
                await MainActor.run {
                    if let data = response["data"] as? [String: Any] {
                        var loaded = 0
                        if let intro = data["intro"] as? [String: Any],
                           let start = intro["start_ms"] as? Int, let end = intro["end_ms"] as? Int {
                            self.drafts[.intro] = SegmentDraft(startMs: start, endMs: end)
                            loaded += 1
                        }
                        if let credits = data["credits"] as? [String: Any],
                           let start = credits["start_ms"] as? Int, let end = credits["end_ms"] as? Int {
                            self.drafts[.credits] = SegmentDraft(startMs: start, endMs: end)
                            loaded += 1
                        }
                        if let recap = data["recap"] as? [String: Any],
                           let start = recap["start_ms"] as? Int, let end = recap["end_ms"] as? Int {
                            self.drafts[.recap] = SegmentDraft(startMs: start, endMs: end)
                            loaded += 1
                        }
                        self.statusMessage = "Loaded \(loaded) segment(s) from database!"
                    } else {
                        self.statusMessage = "No segments found in database for TMDB \(tmdbInt)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Load Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func uploadAllDrafts() {
        let keyToUse = theIntroDBKey.trimmingCharacters(in: .whitespaces)
        guard !keyToUse.isEmpty else {
            statusMessage = "Error: TheIntroDB API key is missing. Set API key in sidebar."
            return
        }

        guard let tmdbInt = Int(tmdbId.trimmingCharacters(in: .whitespaces)) else {
            statusMessage = "Error: Valid TMDB ID is required for submission"
            return
        }

        statusMessage = "Submitting segments to TheIntroDB..."
        let client = TheIntroDBClient()

        var payload: [String: Any] = [
            "tmdb_id": tmdbInt,
            "media_type": mediaType.rawValue
        ]
        if let s = Int(season.trimmingCharacters(in: .whitespaces)) { payload["season"] = s }
        if let e = Int(episode.trimmingCharacters(in: .whitespaces)) { payload["episode"] = e }
        if !imdbId.isEmpty { payload["imdb_id"] = imdbId.trimmingCharacters(in: .whitespaces) }

        var segDict: [String: Any] = [:]
        for (type, draft) in drafts {
            if let start = draft.startMs, let end = draft.endMs, end > start {
                segDict[type.rawValue] = ["start_ms": start, "end_ms": end]
            }
        }
        payload["segments"] = segDict

        Task {
            do {
                let (_, _) = try await client.submit(requestBody: payload, apiKey: keyToUse)
                await MainActor.run {
                    self.statusMessage = "Successfully submitted segments to TheIntroDB!"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Submission Error: \(error.localizedDescription)"
                }
            }
        }
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
                        self.statusMessage = "RCD Season scan complete! Detected intro/credits across \(results.count) episodes"

                        // Apply detected timestamps to current draft if current video matches
                        if let currentName = self.videoURL?.lastPathComponent,
                           let matches = results[currentName] {
                            for match in matches {
                                let startMs = Int(match.startSec * 1000.0)
                                let endMs = Int(match.endSec * 1000.0)
                                self.drafts[match.type] = SegmentDraft(startMs: startMs, endMs: endMs)
                            }
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

    private func loadCachedRCDSegments(for url: URL) {
        let filename = url.lastPathComponent
        guard let matches = RCDCacheService.shared.getMatches(forFilename: filename) else { return }

        var loadedCount = 0
        for match in matches {
            let startMs = Int(match.startSec * 1000.0)
            let endMs = Int(match.endSec * 1000.0)
            self.drafts[match.type] = SegmentDraft(startMs: startMs, endMs: endMs)
            loadedCount += 1
        }

        if loadedCount > 0 {
            self.statusMessage = "✨ Auto-loaded \(loadedCount) RCD segment(s) for episode!"
            LoggerService.shared.info("[UI] Auto-applied \(loadedCount) RCD segments for \(filename)")
        }
    }

    private func formatTimeMs(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        let millis = ms % 1000
        return String(format: "%02d:%02d.%03d", m, s, millis)
    }
}

