import SwiftUI
import AVFoundation
import AppKit

public struct ThumbnailItem: Identifiable {
    public var id: Int { timeMs }
    public let timeMs: Int
    public let image: NSImage?

    public init(timeMs: Int, image: NSImage? = nil) {
        self.timeMs = timeMs
        self.image = image
    }
}

public struct FrameStripView: View {
    public var videoURL: URL?
    public var currentPositionMs: Int
    public var durationMs: Int
    public var frameRate: Double
    public var onSeek: ((Int) -> Void)?

    @State private var thumbnails: [ThumbnailItem] = []
    @State private var thumbnailCache: [Int: NSImage] = [:]
    @State private var isGenerating = false

    public init(
        videoURL: URL?,
        currentPositionMs: Int,
        durationMs: Int,
        frameRate: Double,
        onSeek: ((Int) -> Void)? = nil
    ) {
        self.videoURL = videoURL
        self.currentPositionMs = currentPositionMs
        self.durationMs = durationMs
        self.frameRate = frameRate
        self.onSeek = onSeek
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Overview")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Text("step = 250 ms, fps \(String(format: "%.2f", frameRate > 0 ? frameRate : 23.98))")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(thumbnails) { item in
                        let isCurrent = isCurrentFrame(item.timeMs)
                        let borderColor = isCurrent ? Color(red: 0.0, green: 0.48, blue: 1.0) : Color.clear
                        let textColor = isCurrent ? Color.blue : Color.gray

                        Button(action: { onSeek?(item.timeMs) }) {
                            VStack(spacing: 2) {
                                Group {
                                    if let img = item.image ?? thumbnailCache[item.timeMs] {
                                        Image(nsImage: img)
                                            .resizable()
                                            .aspectRatio(16/9, contentMode: .fill)
                                    } else {
                                        Color(red: 0.15, green: 0.15, blue: 0.18)
                                            .overlay(
                                                Image(systemName: "photo")
                                                    .foregroundColor(.gray.opacity(0.5))
                                            )
                                    }
                                }
                                .frame(width: 80, height: 45)
                                .cornerRadius(3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(borderColor, lineWidth: 2)
                                )

                                Text(formatTimeMs(item.timeMs))
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundColor(textColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 65)
        }
        .padding(.vertical, 4)
        .onAppear {
            generateThumbnailsIfNeeded(centerMs: currentPositionMs)
        }
        .onChange(of: currentPositionMs) { newPos in
            generateThumbnailsIfNeeded(centerMs: newPos)
        }
        .onChange(of: videoURL) { _ in
            thumbnailCache.removeAll()
            thumbnails.removeAll()
            generateThumbnailsIfNeeded(centerMs: currentPositionMs)
        }
    }

    private func isCurrentFrame(_ timeMs: Int) -> Bool {
        abs(timeMs - currentPositionMs) < 150
    }

    private func formatTimeMs(_ ms: Int) -> String {
        let sec = ms / 1000
        let m = sec / 60
        let s = sec % 60
        let millis = ms % 1000
        return String(format: "%02d:%02d.%03d", m, s, millis)
    }

    private func generateThumbnailsIfNeeded(centerMs: Int) {
        guard let url = videoURL else { return }

        // Generate 13 frames around centerMs with 250ms step
        let count = 13
        let stepMs = 250
        let half = count / 2
        let maxLimit = durationMs > 0 ? durationMs : centerMs + 10000

        let targetTimes = (-half...half).map { offset in
            let raw = centerMs + offset * stepMs
            return max(0, min(maxLimit, raw))
        }

        // Update placeholder items immediately so timestamps display instantly
        self.thumbnails = targetTimes.map { ThumbnailItem(timeMs: $0, image: self.thumbnailCache[$0]) }

        // Filter missing times that are not in cache
        let missingTimes = targetTimes.filter { thumbnailCache[$0] == nil }
        guard !missingTimes.isEmpty else { return }

        let ext = url.pathExtension.lowercased()
        let isNativeContainer = ["mp4", "mov", "m4v"].contains(ext)

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = isNativeContainer ? AVAssetImageGenerator(asset: asset) : nil
            if let generator {
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 160, height: 90)
                generator.requestedTimeToleranceBefore = CMTime(value: 300, timescale: 1000)
                generator.requestedTimeToleranceAfter = CMTime(value: 300, timescale: 1000)
            }

            for timeMs in missingTimes {
                var loadedData: Data? = nil

                // 1. For native containers (mp4/mov), try AVAssetImageGenerator
                if isNativeContainer, let gen = generator {
                    let cmTime = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
                    if let cgImage = try? gen.copyCGImage(at: cmTime, actualTime: nil) {
                        let rep = NSBitmapImageRep(cgImage: cgImage)
                        loadedData = rep.representation(using: .jpeg, properties: [:])
                    }
                }

                // 2. Fast FFmpeg in-memory pipe for MKV/x265/non-native (<0.02s)
                if loadedData == nil {
                    loadedData = await FFmpegService.shared.extractThumbnailData(url: url, timeMs: timeMs)
                }

                if let data = loadedData, let img = NSImage(data: data) {
                    await MainActor.run {
                        self.thumbnailCache[timeMs] = img
                        self.thumbnails = targetTimes.map { ThumbnailItem(timeMs: $0, image: self.thumbnailCache[$0]) }
                    }
                }
            }
        }
    }

}
