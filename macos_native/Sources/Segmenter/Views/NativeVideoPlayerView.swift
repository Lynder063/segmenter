import SwiftUI
import AppKit
import AVFoundation
import AVKit

public struct NativeVideoPlayerView: NSViewRepresentable {
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

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect

        let player = AVPlayer()
        playerView.player = player

        context.coordinator.setupPlayer(player: player)
        return playerView
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard let player = nsView.player else { return }

        if context.coordinator.currentURL != videoURL {
            context.coordinator.loadVideo(url: videoURL, player: player)
        }

        if isPlaying && player.timeControlStatus != .playing {
            player.play()
        } else if !isPlaying && player.timeControlStatus == .playing {
            player.pause()
        }
    }

    public class Coordinator: NSObject {
        var parent: NativeVideoPlayerView
        var currentURL: URL?
        var timeObserverToken: Any?
        private weak var player: AVPlayer?
        private var isSeeking = false

        init(_ parent: NativeVideoPlayerView) {
            self.parent = parent
        }

        deinit {
            if let token = timeObserverToken, let player = player {
                player.removeTimeObserver(token)
            }
        }

        func setupPlayer(player: AVPlayer) {
            self.player = player
            let interval = CMTime(value: 1, timescale: 30) // ~33ms periodic observer

            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self, !self.isSeeking else { return }
                let ms = Int(CMTimeGetSeconds(time) * 1000.0)
                DispatchQueue.main.async {
                    self.parent.currentPositionMs = max(0, ms)
                    self.parent.onTimeChanged?(max(0, ms))
                }
            }
        }

        func loadVideo(url: URL?, player: AVPlayer) {
            self.currentURL = url
            guard let videoURL = url else {
                player.replaceCurrentItem(with: nil)
                return
            }

            LoggerService.shared.info("[VideoPlayer] Loading native video: \(videoURL.lastPathComponent)")
            let asset = AVAsset(url: videoURL)
            let item = AVPlayerItem(asset: asset)

            player.replaceCurrentItem(with: item)

            Task {
                if let duration = try? await asset.load(.duration) {
                    let durMs = Int(CMTimeGetSeconds(duration) * 1000.0)
                    DispatchQueue.main.async {
                        self.parent.durationMs = max(0, durMs)
                        self.parent.onDurationChanged?(max(0, durMs))
                    }
                }

                if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                   let fps = try? await videoTrack.load(.nominalFrameRate), fps > 0 {
                    DispatchQueue.main.async {
                        self.parent.frameRate = Double(fps)
                        LoggerService.shared.info("[VideoPlayer] Resolved video frame rate: \(fps) fps")
                    }
                }
            }
        }

        public func stepFrame(forward: Bool, player: AVPlayer) {
            let frameDuration = 1.0 / parent.frameRate
            let currentSec = CMTimeGetSeconds(player.currentTime())
            let newSec = forward ? (currentSec + frameDuration) : (currentSec - frameDuration)
            let targetTime = CMTime(seconds: max(0.0, newSec), preferredTimescale: 600)

            isSeeking = true
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.isSeeking = false
            }
        }
    }
}
