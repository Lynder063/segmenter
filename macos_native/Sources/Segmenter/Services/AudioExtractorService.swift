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
            let asset = AVAsset(url: videoURL)
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw NSError(domain: "AudioExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio track found in media file"])
            }

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 8000
            ]

            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader.add(trackOutput)
            reader.startReading()

            var samples: [Int16] = []
            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    var bufferSamples = [Int16](repeating: 0, count: length / 2)
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bufferSamples)
                    samples.append(contentsOf: bufferSamples)
                }
            }

            progressHandler(50)
            guard !samples.isEmpty else {
                throw NSError(domain: "AudioExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read PCM audio data"])
            }

            // 1. Calculate Peak Waveform Buckets using Accelerate
            let samplesPerBucket = max(1, samples.count / bucketCount)
            var waveformBuckets = [Float](repeating: 0.0, count: bucketCount)
            var maxPeak: Float = 0.0

            for i in 0..<bucketCount {
                let startIdx = i * samplesPerBucket
                let endIdx = min(samples.count, startIdx + samplesPerBucket)
                if startIdx < endIdx {
                    let chunk = samples[startIdx..<endIdx]
                    let peak = chunk.map { abs(Float($0)) }.max() ?? 0.0
                    waveformBuckets[i] = peak
                    if peak > maxPeak { maxPeak = peak }
                }
            }

            if maxPeak > 0 {
                for i in 0..<bucketCount {
                    waveformBuckets[i] /= maxPeak
                }
            }

            progressHandler(75)

            // 2. Music Likelihood via FFT Spectral Flatness (80Hz - 3000Hz)
            var musicBuckets = [Float](repeating: 0.5, count: bucketCount)
            let fftSize = 2048
            let log2n = vDSP_Length(log2(Double(fftSize)))
            if let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) {
                defer { vDSP_destroy_fftsetup(fftSetup) }

                var realP = [Float](repeating: 0.0, count: fftSize / 2)
                var imagP = [Float](repeating: 0.0, count: fftSize / 2)

                for i in 0..<bucketCount {
                    let centerSample = Int((Double(i) / Double(bucketCount)) * Double(samples.count))
                    let startIdx = max(0, centerSample - fftSize / 2)
                    let endIdx = min(samples.count, startIdx + fftSize)

                    if endIdx - startIdx >= fftSize {
                        let windowed = samples[startIdx..<(startIdx + fftSize)].map { Float($0) }
                        // Convert to split complex
                        realP.withUnsafeMutableBufferPointer { rPtr in
                            imagP.withUnsafeMutableBufferPointer { iPtr in
                                var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                                windowed.withUnsafeBufferPointer { wPtr in
                                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                                    }
                                }
                                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                                // Compute power spectrum
                                var power = [Float](repeating: 0.0, count: fftSize / 2)
                                vDSP_zvmags(&splitComplex, 1, &power, 1, vDSP_Length(fftSize / 2))

                                // Band 80Hz - 3000Hz (sampleRate = 8000Hz)
                                let minBin = Int(80.0 / (8000.0 / Double(fftSize)))
                                let maxBin = min(fftSize / 2 - 1, Int(3000.0 / (8000.0 / Double(fftSize))))

                                if maxBin > minBin {
                                    let bandPower = Array(power[minBin...maxBin])
                                    let sum = bandPower.reduce(0, +)
                                    let arithmeticMean = sum / Float(bandPower.count)
                                    let logSum = bandPower.reduce(0) { $0 + log(max(1e-10, $1)) }
                                    let geometricMean = exp(logSum / Float(bandPower.count))

                                    let flatness = geometricMean / max(1e-10, arithmeticMean)
                                    let musicScore = max(0.0, min(1.0, 1.0 - flatness))
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
            LoggerService.shared.info("[AudioExtractor] Audio waveform analysis complete! Buckets: \(bucketCount)")

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
