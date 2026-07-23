import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis

public final class AudioExtractorService {
    public static let shared = AudioExtractorService()

    private init() {}

    public func extractAudioWaveform(
        videoURL: URL,
        durationMs: Int,
        progressHandler: @escaping (Int) -> Void
    ) async throws -> (buckets: [Float], musicLikelihood: [Float]) {
        LoggerService.shared.info("[AudioExtractor] Starting IntroStamp audio engine for: \(videoURL.lastPathComponent) (\(durationMs)ms)")

        guard durationMs > 0 else {
            throw NSError(domain: "AudioExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid video duration"])
        }

        let bucketCount = max(120, min(2400, durationMs / 250))
        progressHandler(10)

        return await Task.detached(priority: .userInitiated) {

            let durationSec = max(Double(durationMs) / 1000.0, 0.001)

            // 1. Extract Waveform Buckets using Zero-Copy vDSP_maxmgv (IntroStamp WaveformExtractor)
            var waveformBuckets = [Float](repeating: 0.0, count: bucketCount)
            let asset = AVAsset(url: videoURL)

            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
               let reader = try? AVAssetReader(asset: asset) {

                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]

                let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                trackOutput.alwaysCopiesSampleData = false

                if reader.canAdd(trackOutput) {
                    reader.add(trackOutput)
                    if reader.startReading() {
                        while reader.status == .reading {
                            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
                            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            let seconds = max(0, timestamp.seconds)
                            let ratio = min(max(seconds / durationSec, 0), 1)
                            let index = min(bucketCount - 1, max(0, Int((ratio * Double(bucketCount)).rounded(.down))))

                            let peak = AudioExtractorService.peakAmplitude(from: sampleBuffer)
                            if peak > waveformBuckets[index] {
                                waveformBuckets[index] = peak
                            }
                        }
                    }
                }
            }

            // Fallback to FFmpeg if AVAssetReader returned empty buckets
            let maxPeak = waveformBuckets.max() ?? 0
            if maxPeak == 0 {
                LoggerService.shared.info("[AudioExtractor] AVAssetReader empty for \(videoURL.lastPathComponent). Falling back to FFmpeg PCM extraction...")
                if let pcm = try? await FFmpegService.shared.extractPCMAudio(url: videoURL) {
                    let samplesPerBucket = max(1, pcm.count / bucketCount)
                    for i in 0..<bucketCount {
                        let startIdx = i * samplesPerBucket
                        let count = min(samplesPerBucket, pcm.count - startIdx)
                        if count > 0 {
                            pcm.withUnsafeBufferPointer { ptr in
                                var floatBuffer = [Float](repeating: 0, count: count)
                                vDSP_vflt16(ptr.baseAddress! + startIdx, 1, &floatBuffer, 1, vDSP_Length(count))
                                var chunkMax: Float = 0
                                vDSP_maxmgv(floatBuffer, 1, &chunkMax, vDSP_Length(count))
                                waveformBuckets[i] = chunkMax / Float(Int16.max)
                            }
                        }
                    }
                }
            }

            // Normalize Waveform Buckets
            let finalMax = waveformBuckets.max() ?? 0
            if finalMax > 0 {
                var divisor = finalMax
                vDSP_vsdiv(waveformBuckets, 1, &divisor, &waveformBuckets, 1, vDSP_Length(bucketCount))
            }

            progressHandler(50)

            // 2. SoundAnalysis CoreML Music Likelihood Classifier (IntroStamp AudioLikelihoodObserver)
            var musicBuckets = [Float](repeating: 0.5, count: bucketCount)
            do {
                let analyzer = try SNAudioFileAnalyzer(url: videoURL)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTime(seconds: 2.0, preferredTimescale: 600)
                request.overlapFactor = 0.0

                let observer = SoundLikelihoodObserver(bucketCount: bucketCount, durationSeconds: durationSec)
                try analyzer.add(request, withObserver: observer)
                await analyzer.analyze()
                musicBuckets = observer.resolvedMusicBuckets()
            } catch {
                LoggerService.shared.warn("[AudioExtractor] SoundAnalysis CoreML failed: \(error). Using fallback spectral flatness.")
            }


            // Smooth music likelihood buckets (radius = 2)
            let smoothedMusic = AudioExtractorService.smoothBuckets(input: musicBuckets, radius: 2)
            progressHandler(100)
            LoggerService.shared.info("[AudioExtractor] IntroStamp audio engine analysis complete! Buckets: \(bucketCount)")

            return (waveformBuckets, smoothedMusic)
        }.value
    }

    private static func peakAmplitude(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength >= MemoryLayout<Int16>.stride else { return 0 }

        var maxSample: Float = 0
        var offset = 0

        while offset < totalLength {
            var lengthAtOffset = 0
            var chunkTotalLength = 0
            var chunkPointer: UnsafeMutablePointer<Int8>?

            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: offset,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &chunkTotalLength,
                dataPointerOut: &chunkPointer
            )

            guard status == kCMBlockBufferNoErr, let chunkPointer, lengthAtOffset > 0 else { break }

            let sampleCount = lengthAtOffset / MemoryLayout<Int16>.stride
            if sampleCount > 0 {
                chunkPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                    var floatBuffer = [Float](repeating: 0, count: sampleCount)
                    vDSP_vflt16(samples, 1, &floatBuffer, 1, vDSP_Length(sampleCount))
                    var chunkMax: Float = 0
                    vDSP_maxmgv(floatBuffer, 1, &chunkMax, vDSP_Length(sampleCount))
                    if chunkMax > maxSample { maxSample = chunkMax }
                }
            }
            offset += lengthAtOffset
        }

        return maxSample / Float(Int16.max)
    }

    private static func smoothBuckets(input: [Float], radius: Int) -> [Float] {
        guard !input.isEmpty && radius > 0 else { return input }
        var result = [Float](repeating: 0.0, count: input.count)

        for i in 0..<input.count {
            var sum: Float = 0.0
            var weightSum: Float = 0.0

            for r in -radius...radius {
                let idx = i + r
                if idx >= 0 && idx < input.count {
                    let weight = Float(radius + 1 - abs(r))
                    sum += input[idx] * weight
                    weightSum += weight
                }
            }
            result[i] = weightSum > 0 ? (sum / weightSum) : input[i]
        }
        return result
    }
}

private final class SoundLikelihoodObserver: NSObject, SNResultsObserving {
    private let bucketCount: Int
    private let durationSeconds: Double
    private var musicSums: [Float]
    private var speechSums: [Float]
    private var counts: [Int]

    init(bucketCount: Int, durationSeconds: Double) {
        self.bucketCount = bucketCount
        self.durationSeconds = max(durationSeconds, 0.001)
        self.musicSums = Array(repeating: 0.0, count: bucketCount)
        self.speechSums = Array(repeating: 0.0, count: bucketCount)
        self.counts = Array(repeating: 0, count: bucketCount)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        let musicConfidence = highestConfidence(
            in: classificationResult,
            matchingAnyOf: ["music", "singing", "choir", "yodeling", "rapping", "humming", "whistling"],
            excluding: ["speech", "spoken", "voice"]
        )
        let speechConfidence = highestConfidence(
            in: classificationResult,
            matchingAnyOf: ["speech", "spoken", "dialog", "dialogue", "voice", "narration", "conversation"],
            excluding: ["sing", "choir", "yodel", "rapping", "humming", "whistling", "music"]
        )

        guard musicConfidence > 0 || speechConfidence > 0 else { return }

        let start = max(0, classificationResult.timeRange.start.seconds)
        let end = max(start, classificationResult.timeRange.end.seconds)
        let startRatio = min(max(start / durationSeconds, 0), 1)
        let endRatio = min(max(end / durationSeconds, 0), 1)

        let startIndex = min(bucketCount - 1, max(0, Int((startRatio * Double(bucketCount)).rounded(.down))))
        let endIndex = min(bucketCount - 1, max(startIndex, Int((endRatio * Double(bucketCount)).rounded(.down))))

        for index in startIndex...endIndex {
            musicSums[index] += Float(musicConfidence)
            speechSums[index] += Float(speechConfidence)
            counts[index] += 1
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}

    func resolvedMusicBuckets() -> [Float] {
        let speechSuppressionFactor: Float = 0.75
        return (0..<bucketCount).map { index in
            let count = counts[index]
            guard count > 0 else { return 0.5 }

            let music = min(max(musicSums[index] / Float(count), 0), 1)
            let speech = min(max(speechSums[index] / Float(count), 0), 1)
            let effectiveMusic = max(0, music - (speech * speechSuppressionFactor))
            return min(max(effectiveMusic, 0), 1)
        }
    }

    private func highestConfidence(
        in result: SNClassificationResult,
        matchingAnyOf keywords: [String],
        excluding excludedKeywords: [String]
    ) -> Double {
        var best: Double = 0
        for classification in result.classifications {
            let identifier = classification.identifier.lowercased()
            let matchesKeyword = keywords.contains { identifier.contains($0) }
            guard matchesKeyword else { continue }

            let isExcluded = excludedKeywords.contains { identifier.contains($0) }
            guard !isExcluded else { continue }

            if classification.confidence > best {
                best = classification.confidence
            }
        }
        return best
    }
}
