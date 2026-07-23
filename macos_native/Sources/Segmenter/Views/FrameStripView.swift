import SwiftUI
import AVFoundation
import AppKit

public struct ThumbnailItem: Identifiable {
    public var id: Int { timeMs }
    public let timeMs: Int
    public let image: NSImage

    public init(timeMs: Int, image: NSImage) {
        self.timeMs = timeMs
        self.image = image
    }
}

public struct FrameStripView: View {
    public var videoURL: URL?
    public var currentPositionMs: Int
    public var durationMs: Int
    public var frameRate: Double

    @State private var thumbnails: [ThumbnailItem] = []
    @State private var isGenerating = false

    public init(videoURL: URL?, currentPositionMs: Int, durationMs: Int, frameRate: Double) {
        self.videoURL = videoURL
        self.currentPositionMs = currentPositionMs
        self.durationMs = durationMs
        self.frameRate = frameRate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Overview")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Text("step = 250 ms, fps \(String(format: "%.2f", frameRate))")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(thumbnails.enumerated()), id: \.element.id) { _, item in
                        let isCurrent = isCurrentFrame(item.timeMs)
                        let borderColor = isCurrent ? Color(red: 0.0, green: 0.48, blue: 1.0) : Color.clear
                        let textColor = isCurrent ? Color.blue : Color.gray

                        VStack(spacing: 2) {
                            Image(nsImage: item.image)
                                .resizable()
                                .aspectRatio(16/9, contentMode: .fit)
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
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 65)
        }
        .padding(.vertical, 4)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .onChange(of: currentPositionMs) { newPos in
            generateThumbnailsIfNeeded(centerMs: newPos)
        }
        .onChange(of: videoURL) { _ in
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
        guard let url = videoURL, !isGenerating else { return }

        // Generate 13 frames around centerMs with 250ms step
        let count = 13
        let stepMs = 250
        let half = count / 2
        let targetTimes = (-half...half).map { max(0, min(durationMs, centerMs + $0 * stepMs)) }

        // Skip if already matching current range
        if let first = thumbnails.first?.timeMs, let last = thumbnails.last?.timeMs,
           first == targetTimes.first && last == targetTimes.last {
            return
        }

        isGenerating = true
        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)

            var newThumbs: [ThumbnailItem] = []
            for timeMs in targetTimes {
                let cmTime = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
                if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 80, height: 45))
                    newThumbs.append(ThumbnailItem(timeMs: timeMs, image: nsImage))
                }
            }

            let resultThumbs = newThumbs
            await MainActor.run {
                self.thumbnails = resultThumbs
                self.isGenerating = false
            }
        }
    }
}
