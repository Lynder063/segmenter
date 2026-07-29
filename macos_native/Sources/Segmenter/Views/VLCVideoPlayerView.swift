import SwiftUI
import AppKit
import VLCKit

public struct VLCVideoPlayerView: NSViewRepresentable {
    @Binding public var videoURL: URL?
    @Binding public var isPlaying: Bool
    @Binding public var currentPositionMs: Int
    @Binding public var durationMs: Int
    @Binding public var frameRate: Double

    public var onTimeChanged: ((Int) -> Void)?
    public var onDurationChanged: ((Int) -> Void)?

    public init(
        videoURL: Binding<URL?>,
        isPlaying: Binding<Bool>,
        currentPositionMs: Binding<Int>,
        durationMs: Binding<Int>,
        frameRate: Binding<Double>,
        onTimeChanged: ((Int) -> Void)? = nil,
        onDurationChanged: ((Int) -> Void)? = nil
    ) {
        self._videoURL = videoURL
        self._isPlaying = isPlaying
        self._currentPositionMs = currentPositionMs
        self._durationMs = durationMs
        self._frameRate = frameRate
        self.onTimeChanged = onTimeChanged
        self.onDurationChanged = onDurationChanged
    }

    public func makeNSView(context: Context) -> VLCPlayerContainerNSView {
        let container = VLCPlayerContainerNSView()
        context.coordinator.setupPlayer(containerView: container.videoView)

        if let url = videoURL {
            context.coordinator.loadMedia(url: url)
        }

        return container
    }

    public func updateNSView(_ nsView: VLCPlayerContainerNSView, context: Context) {
        context.coordinator.update(
            url: videoURL,
            isPlaying: isPlaying,
            positionMs: currentPositionMs
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: VLCVideoPlayerView
        var mediaPlayer: VLCMediaPlayer?
        var currentURL: URL?
        private var isSeeking = false
        private var playbackTimer: Timer?

        init(parent: VLCVideoPlayerView) {
            self.parent = parent
        }


        deinit {
            playbackTimer?.invalidate()
        }

        func setupPlayer(containerView: NSView) {
            let options = [
                "--quiet",
                "--no-spu",                          // Disable subtitle renderer pre-parsing overhead
                "--no-osd",                          // Disable OSD overlay
                "--avcodec-hw=any",                  // Enable VideoToolbox macOS hardware video acceleration
                "--file-caching=300",               // 300ms file caching for instant local seeking
                "--network-caching=300",
                "--no-stats",
                "--no-sub-autodetect-file"
            ]
            let library = VLCLibrary(options: options)
            let player = VLCMediaPlayer(library: library)
            player.drawable = containerView
            player.delegate = self
            self.mediaPlayer = player
        }

        private func startTimer() {
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.mediaPlayer else { return }
                let state = player.state
                let active = player.isPlaying || state == .playing || state == .opening
                guard active, !self.isSeeking else { return }

                let timeMs = Int(player.time.value?.int64Value ?? 0)
                if timeMs >= 0 {
                    DispatchQueue.main.async {
                        if self.parent.currentPositionMs != timeMs {
                            self.parent.currentPositionMs = timeMs
                            self.parent.onTimeChanged?(timeMs)
                        }
                    }
                }
                if let lengthMs = player.media?.length.value?.intValue, lengthMs > 0, self.parent.durationMs != lengthMs {
                    DispatchQueue.main.async {
                        self.parent.durationMs = lengthMs
                        self.parent.onDurationChanged?(lengthMs)
                    }
                }
            }
        }

        private func stopTimer() {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }

        func loadMedia(url: URL) {
            guard currentURL != url else { return }
            self.currentURL = url
            LoggerService.shared.info("[VLCKit] Loading video directly with LibVLC engine: \(url.lastPathComponent)")

            let media = VLCMedia(url: url)
            mediaPlayer?.media = media

            if parent.isPlaying {
                mediaPlayer?.play()
                startTimer()
            } else {
                mediaPlayer?.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self, !self.parent.isPlaying else { return }
                    self.mediaPlayer?.pause()
                }
            }
        }

        func update(url: URL?, isPlaying: Bool, positionMs: Int) {
            if let url = url, currentURL != url {
                loadMedia(url: url)
            }

            guard let player = mediaPlayer else { return }

            if isPlaying {
                if !player.isPlaying && player.state != .playing && player.state != .opening {
                    player.play()
                }
                startTimer()
            } else {
                if player.isPlaying || player.state == .playing {
                    player.pause()
                }
                stopTimer()
            }

            if !isSeeking {
                let playerMs = Int(player.time.value?.int64Value ?? 0)
                if abs(playerMs - positionMs) > 150 && positionMs >= 0 {
                    isSeeking = true
                    let vlcTime = VLCTime(number: NSNumber(value: positionMs))
                    player.time = vlcTime
                    if !player.isPlaying {
                        player.gotoNextFrame()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.isSeeking = false
                    }
                }
            }
        }



        public func mediaPlayerTimeChanged(_ notification: Notification) {
            guard let player = mediaPlayer, !isSeeking else { return }
            let timeMs = Int(player.time.value?.int64Value ?? 0)
            if timeMs >= 0 {
                DispatchQueue.main.async {
                    if self.parent.currentPositionMs != timeMs {
                        self.parent.currentPositionMs = timeMs
                        self.parent.onTimeChanged?(timeMs)
                    }
                }
            }

            if let lengthMs = player.media?.length.value?.intValue, lengthMs > 0, parent.durationMs != lengthMs {
                DispatchQueue.main.async {
                    self.parent.durationMs = lengthMs
                    self.parent.onDurationChanged?(lengthMs)
                }
            }
        }


        public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            guard let player = mediaPlayer else { return }
            if player.state == newState, "\(newState)".lowercased().contains("ended") {
                stopTimer()
                DispatchQueue.main.async {
                    self.parent.isPlaying = false
                }
            }
        }
    }

}

public class VLCPlayerContainerNSView: NSView {
    public let videoView = NSView()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.masksToBounds = true

        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.autoresizingMask = [.width, .height]
        videoView.frame = self.bounds
        self.addSubview(videoView)
    }

    override public func layout() {
        super.layout()
        videoView.frame = self.bounds
    }
}
