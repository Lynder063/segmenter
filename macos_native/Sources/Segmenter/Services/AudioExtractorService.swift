import Foundation
import AVFoundation
import Accelerate

public final class AudioExtractorService {
    public static let shared = AudioExtractorService()

    private init() {}

    public func extractAudioWaveform(videoURL: URL, durationMs: Int, progressHandler: @escaping (Int) -> Void) async throws -> (buckets: [Float], musicLikelihood: [Float]) {
        LoggerService.shared.info("[AudioExtractor] Starting audio analysis for: \(videoURL.lastPathComponent) (\(durationMs)ms)")

        guard durationMs > 0 else {
            throw NSError(domain: "AudioExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid video duration"])
        }

        let bucketCount = max(120, min(2400, durationMs / 250))
        progressHandler(10)

        // Run extraction on background queue
        return try await Task.detached(priority: .userInitiated) {
            var samples: [Int16] = []

            let ext = videoURL.pathExtension.lowercased()
            let isNonNativeContainer = ["mkv", "avi", "webm", "flv", "wmv", "vob"].contains(ext)

            // Try AVAssetReader only for native containers (MP4, MOV, M4V)
            if !isNonNativeContainer {
                let asset = AVAsset(url: videoURL)
                if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                   let reader = try? AVAssetReader(asset: asset) {

                    let outputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                        AVNumberOfChannelsKey: 1,
                        AVSampleRateKey: 1000
                    ]

                    let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                    reader.add(trackOutput)
                    reader.startReading()

                    while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                            let length = CMBlockBufferGetDataLength(blockBuffer)
                            var bufferSamples = [Int16](repeating: 0, count: length / 2)
                            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bufferSamples)
                            samples.append(contentsOf: bufferSamples)
                        }
                    }
                }
            }

            // Fallback / Primary for MKV / AC3 / DTS / x265 audio streams via FFmpeg
            if samples.isEmpty {
                LoggerService.shared.info("[AudioExtractor] Using FFmpeg PCM audio extraction for \(videoURL.lastPathComponent)...")
                if let pcm = try? await FFmpegService.shared.extractPCMAudio(url: videoURL) {
                    samples = pcm
                }
            }


            progressHandler(50)
            guard !samples.isEmpty else {
                throw NSError(domain: "AudioExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read PCM audio data from media file"])
            }


            progressHandler(50)
            guard !samples.isEmpty else {
                throw NSError(domain: "AudioExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read PCM audio data from media file"])
            }

            // 1. Convert Int16 samples to Float using Accelerate vDSP (instant)
            var floatSamples = [Float](repeating: 0.0, count: samples.count)
            samples.withUnsafeBufferPointer { sPtr in
                vDSP_vflt16(sPtr.baseAddress!, 1, &floatSamples, 1, vDSP_Length(samples.count))
            }

            // Absolute values
            var absSamples = [Float](repeating: 0.0, count: samples.count)
            vDSP_vabs(&floatSamples, 1, &absSamples, 1, vDSP_Length(samples.count))

            // 2. Compute Peak Waveform Buckets using Accelerate vDSP_maxv
            let samplesPerBucket = max(1, samples.count / bucketCount)
            var waveformBuckets = [Float](repeating: 0.0, count: bucketCount)
            var maxPeak: Float = 0.0

            for i in 0..<bucketCount {
                let startIdx = i * samplesPerBucket
                let count = min(samplesPerBucket, samples.count - startIdx)
                if count > 0 {
                    absSamples.withUnsafeBufferPointer { ptr in
                        var peak: Float = 0.0
                        vDSP_maxv(ptr.baseAddress! + startIdx, 1, &peak, vDSP_Length(count))
                        waveformBuckets[i] = peak
                        if peak > maxPeak { maxPeak = peak }
                    }
                }
            }

            // Vector normalize waveform buckets
            if maxPeak > 0 {
                var divisor = maxPeak
                vDSP_vsdiv(waveformBuckets, 1, &divisor, &waveformBuckets, 1, vDSP_Length(bucketCount))
            }

            progressHandler(75)

            // 3. Music Likelihood via Fast FFT Spectral Flatness
            var musicBuckets = [Float](repeating: 0.5, count: bucketCount)
            let fftSize = 512
            let log2n = vDSP_Length(log2(Double(fftSize)))
            if let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) {
                defer { vDSP_destroy_fftsetup(fftSetup) }

                var realP = [Float](repeating: 0.0, count: fftSize / 2)
                var imagP = [Float](repeating: 0.0, count: fftSize / 2)

                for i in 0..<bucketCount {
                    let centerSample = Int((Double(i) / Double(bucketCount)) * Double(samples.count))
                    let startIdx = max(0, centerSample - fftSize / 2)
                    let count = min(fftSize, samples.count - startIdx)

                    if count >= fftSize {
                        let windowed = Array(floatSamples[startIdx..<(startIdx + fftSize)])
                        realP.withUnsafeMutableBufferPointer { rPtr in
                            imagP.withUnsafeMutableBufferPointer { iPtr in
                                var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                                windowed.withUnsafeBufferPointer { wPtr in
                                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                                    }
                                }
                                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                                var power = [Float](repeating: 0.0, count: fftSize / 2)
                                vDSP_zvmags(&splitComplex, 1, &power, 1, vDSP_Length(fftSize / 2))

                                var meanPower: Float = 0.0
                                vDSP_meanv(power, 1, &meanPower, vDSP_Length(fftSize / 2))

                                if meanPower > 0.001 {
                                    let musicScore = max(0.0, min(1.0, 1.0 - (meanPower * 0.1)))
                                    musicBuckets[i] = musicScore
                                }
                            }
                        }
                    }
                }
            }

            // Smooth music buckets (radius = 2)
            let smoothedMusic = AudioExtractorService.smoothBuckets(input: musicBuckets, radius: 2)
            progressHandler(100)
            LoggerService.shared.info("[AudioExtractor] Ultra-fast audio analysis complete! Buckets: \(bucketCount)")

            return (waveformBuckets, smoothedMusic)
        }.value
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
