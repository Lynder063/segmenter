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

    public func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        let player = VLCMediaPlayer()
        player.drawable = containerView
        player.delegate = context.coordinator
        context.coordinator.mediaPlayer = player

        if let url = videoURL {
            context.coordinator.loadMedia(url: url)
        }

        return containerView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
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

        init(parent: VLCVideoPlayerView) {
            self.parent = parent
        }

        func loadMedia(url: URL) {
            guard currentURL != url else { return }
            self.currentURL = url
            LoggerService.shared.info("[VLCKit] Loading video directly with LibVLC engine: \(url.lastPathComponent)")

            let media = VLCMedia(url: url)
            mediaPlayer?.media = media
            mediaPlayer?.play()
        }

        func update(url: URL?, isPlaying: Bool, positionMs: Int) {
            if let url = url, currentURL != url {
                loadMedia(url: url)
            }

            guard let player = mediaPlayer else { return }

            if isPlaying && !player.isPlaying {
                player.play()
            } else if !isPlaying && player.isPlaying {
                player.pause()
            }

            if !isSeeking {
                let playerMs = Int(player.time.value?.int64Value ?? 0)
                if abs(playerMs - positionMs) > 400 && positionMs >= 0 {
                    isSeeking = true
                    let vlcTime = VLCTime(number: NSNumber(value: positionMs))
                    player.time = vlcTime
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
                    self.parent.currentPositionMs = timeMs
                    self.parent.onTimeChanged?(timeMs)
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
                DispatchQueue.main.async {
                    self.parent.isPlaying = false
                }
            }
        }


    }
}
