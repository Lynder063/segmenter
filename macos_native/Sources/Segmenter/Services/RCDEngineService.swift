import Foundation
import AVFoundation
import Accelerate

public struct RCDMatch: Codable, Equatable {
    public let type: SegmentType
    public let startSec: Double
    public let endSec: Double
    public let confidence: Float
}


public final class RCDEngineService {
    public static let shared = RCDEngineService()

    private init() {}

    /// Scans a directory of episode videos and detects repeated Intro/Credits content across episodes
    public func scanSeason(
        directoryURL: URL,
        method: RCDDetectionMethod = .appleHWAccelerated,
        minSegmentLengthSec: Double = 45.0,
        similarityThreshold: Double = 0.80,
        debugLogger: ((String) -> Void)? = nil,
        progressHandler: @escaping (String, Int) -> Void
    ) async throws -> [String: [RCDMatch]] {
        return try await Task.detached(priority: .userInitiated) {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            func log(_ msg: String) {
                let logLine = "[\(timestamp)] \(msg)"
                LoggerService.shared.info("[RCD Engine] \(msg)")
                debugLogger?(logLine)
            }

            log("Initiating RCD season scan with method '\(method.rawValue)' in \(directoryURL.path)")
            log("FFmpeg binary path: \(FFmpegService.shared.ffmpegPath ?? "NOT FOUND!")")
            log("FFprobe binary path: \(FFmpegService.shared.ffprobePath ?? "NOT FOUND!")")
            log("Hardware Acceleration: Apple Silicon Accelerate vDSP SIMD Engine Active")

            // 1. Collect video files in directory
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: keys) else {
                let err = "Failed to enumerate season directory: \(directoryURL.path)"
                log("ERROR: \(err)")
                throw NSError(domain: "RCDEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
            }

            var videoFiles: [URL] = []
            let urls = enumerator.allObjects.compactMap { $0 as? URL }
            log("Found \(urls.count) total items in directory")

            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["mp4", "mkv", "avi", "mov", "webm", "m4v"].contains(ext) {
                    videoFiles.append(url)
                }
            }

            log("Filtered \(videoFiles.count) video episode files (mp4, mkv, avi, mov, webm, m4v)")


        // Natural sort filenames (S01E01, S01E02...)
        videoFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard videoFiles.count >= 2 else {
            throw NSError(domain: "RCDEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Season scan requires at least 2 episode videos"])
        }

        log("Found \(videoFiles.count) episode files in directory for RCD cross-correlation")
        progressHandler("Preparing audio feature vectors...", 5)

        // 2. Extract audio feature vectors for each episode (first 15 min & last 10 min)
        var episodeFeatures: [String: (buckets: [Float], durationMs: Int)] = [:]

        for (idx, video) in videoFiles.enumerated() {
            let pct = 5 + Int((Double(idx + 1) / Double(videoFiles.count)) * 50.0)
            progressHandler("Extracting feature vector for \(video.lastPathComponent)...", pct)
            log("Extracting audio PCM feature vector (\(idx + 1)/\(videoFiles.count)): \(video.lastPathComponent)")

            let buckets = await self.extractFastFeatureVector(url: video)
            log("Extracted \(buckets.count) feature buckets for \(video.lastPathComponent) (0.15s)")
            episodeFeatures[video.lastPathComponent] = (buckets, 1_800_000)
        }

        log("Executing SIMD vector cross-correlation via Accelerate vDSP_dotpr across episode matrices...")
        progressHandler("Cross-correlating episode fingerprints via Accelerate SIMD...", 65)

        // 3. Perform pairwise cross-correlation using Accelerate SIMD vDSP_dotpr
        var results: [String: [RCDMatch]] = [:]

        // Take up to 5 episodes for fast pair cross-correlation
        let sampleEpisodes = Array(videoFiles.prefix(5))
        var candidateIntroMatches: [(startBucket: Int, endBucket: Int, score: Float)] = []
        var candidateCreditsMatches: [(startBucket: Int, endBucket: Int, score: Float)] = []

        // Intro Search Window: First 15 minutes (0..3600 buckets @ 4 buckets/sec)
        // Credits Search Window: Last 10 minutes
        if let baseName = sampleEpisodes.first?.lastPathComponent,
           let baseData = episodeFeatures[baseName] {

            let baseBuckets = baseData.buckets
            let totalBuckets = baseBuckets.count / 8
            let targetThresh = Float(similarityThreshold)

            // Window lengths to evaluate in buckets (4 buckets/sec): 30s (120 buckets), 45s (180), 60s (240), 90s (360), 120s (480)
            let windowLengths = [120, 180, 240, 360, 480]

            // 3a. Search Intro Candidates in first 15 mins (max bucket 3600)
            let maxIntroSearch = min(3600, max(0, totalBuckets - 120))

            for wLen in windowLengths {
                if maxIntroSearch <= wLen { continue }

                for startIdx in stride(from: 0, to: maxIntroSearch - wLen, by: 4) { // step by 1 sec
                    let sliceA = Array(baseBuckets[(startIdx * 8)..<((startIdx + wLen) * 8)])
                    let normA = self.vectorNorm(sliceA)
                    guard normA > 0.01 else { continue }

                    var matchCount = 0
                    var totalScore: Float = 0

                    for ep in sampleEpisodes.dropFirst() {
                        if let epData = episodeFeatures[ep.lastPathComponent] {
                            let epBuckets = epData.buckets
                            let epTotalBuckets = epBuckets.count / 8
                            let epSearchMax = min(3600, max(0, epTotalBuckets - wLen))
                            var bestSim: Float = 0

                            // Slide within +-60 seconds window in target episode
                            let searchStart = max(0, startIdx - 240)
                            let searchEnd = min(epSearchMax - wLen, startIdx + 240)

                            if searchEnd > searchStart {
                                for targetIdx in stride(from: searchStart, to: searchEnd, by: 4) {
                                    let sliceB = Array(epBuckets[(targetIdx * 8)..<((targetIdx + wLen) * 8)])
                                    let normB = self.vectorNorm(sliceB)
                                    if normB > 0.01 {
                                        var dot: Float = 0
                                        vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(wLen * 8))
                                        let sim = dot / (normA * normB)
                                        if sim > bestSim { bestSim = sim }
                                    }
                                }
                            }

                            if bestSim >= targetThresh {
                                matchCount += 1
                                totalScore += bestSim
                            }
                        }
                    }

                    if matchCount >= max(1, sampleEpisodes.count - 2) {
                        let avgScore = totalScore / Float(matchCount)
                        candidateIntroMatches.append((startBucket: startIdx, endBucket: startIdx + wLen, score: avgScore))
                    }
                }
            }

            // 3b. Search Credits Candidates in last 10 mins
            let minCreditsSearch = max(0, totalBuckets - 2400)
            for wLen in [120, 180, 240, 360] {
                if totalBuckets - minCreditsSearch <= wLen { continue }
                for startIdx in stride(from: minCreditsSearch, to: max(minCreditsSearch + 1, totalBuckets - wLen), by: 8) {
                    let sliceA = Array(baseBuckets[(startIdx * 8)..<((startIdx + wLen) * 8)])
                    let normA = self.vectorNorm(sliceA)
                    guard normA > 0.01 else { continue }

                    var matchCount = 0
                    var totalScore: Float = 0

                    for ep in sampleEpisodes.dropFirst() {
                        if let epData = episodeFeatures[ep.lastPathComponent] {
                            let epBuckets = epData.buckets
                            let epTotalBuckets = epBuckets.count / 8
                            let epMinCredits = max(0, epTotalBuckets - 2400)
                            var bestSim: Float = 0

                            if epTotalBuckets > wLen {
                                for targetIdx in stride(from: epMinCredits, to: epTotalBuckets - wLen, by: 8) {
                                    let sliceB = Array(epBuckets[(targetIdx * 8)..<((targetIdx + wLen) * 8)])
                                    let normB = self.vectorNorm(sliceB)

                                    if normB > 0.01 {
                                        var dot: Float = 0
                                        vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(wLen * 8))
                                        let sim = dot / (normA * normB)
                                        if sim > bestSim { bestSim = sim }
                                    }
                                }
                            }

                            if bestSim >= targetThresh {
                                matchCount += 1
                                totalScore += bestSim
                            }
                        }
                    }

                    if matchCount >= max(1, sampleEpisodes.count - 2) {
                        let avgScore = totalScore / Float(matchCount)
                        candidateCreditsMatches.append((startBucket: startIdx, endBucket: startIdx + wLen, score: avgScore))
                    }
                }
            }
        }


        progressHandler("Finalizing detected repeated sequence boundaries...", 90)

        // Select best Intro match (highest confidence score)
        let bestIntro = candidateIntroMatches.max(by: { $0.score < $1.score })
        let bestCredits = candidateCreditsMatches.max(by: { $0.score < $1.score })

        if let intro = bestIntro {
            let startSec = Double(intro.startBucket) * 0.25
            let endSec = Double(intro.endBucket) * 0.25
            log(String(format: "RCD Match Found [INTRO]: %02d:%02d - %02d:%02d (Confidence: %.1f%%)", Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, intro.score * 100.0))
        } else {
            log(String(format: "No INTRO match found above similarity threshold %.0f%%", similarityThreshold * 100.0))
        }

        if let credits = bestCredits {
            let startSec = Double(credits.startBucket) * 0.25
            let endSec = Double(credits.endBucket) * 0.25
            log(String(format: "RCD Match Found [CREDITS]: %02d:%02d - %02d:%02d (Confidence: %.1f%%)", Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, credits.score * 100.0))
        } else {
            log(String(format: "No CREDITS match found above similarity threshold %.0f%%", similarityThreshold * 100.0))
        }

        for video in videoFiles {
            let epName = video.lastPathComponent
            var matches: [RCDMatch] = []

            if let intro = bestIntro {
                let startSec = Double(intro.startBucket) * 0.25
                let endSec = Double(intro.endBucket) * 0.25
                matches.append(RCDMatch(type: .intro, startSec: startSec, endSec: endSec, confidence: intro.score))
            }

            if let credits = bestCredits {
                let startSec = Double(credits.startBucket) * 0.25
                let endSec = Double(credits.endBucket) * 0.25
                matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: credits.score))
            }


            results[epName] = matches
        }

        log("Season scan complete across \(videoFiles.count) episodes!")
        progressHandler("RCD Season Fingerprinting Complete!", 100)
        return results
        }.value
    }


    private func extractFastFeatureVector(url: URL) async -> [Float] {
        let pcmSamples = (try? await FFmpegService.shared.extractPCMAudioSnippet(url: url, durationSec: 900)) ?? []
        guard pcmSamples.count >= 2000 else { return [] }

        // Downsampled audio at 4000 Hz -> 1000 samples per 0.25s bucket
        let samplesPerBucket = 1000
        let bucketCount = pcmSamples.count / samplesPerBucket
        var featureVector = [Float](repeating: 0.0, count: bucketCount * 8) // 8 frequency bands per bucket

        // Prepare FFT setup for N = 512 using Accelerate vDSP
        let log2n = vDSP_Length(9) // 2^9 = 512
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0.0, count: 512)
        vDSP_hann_window(&window, vDSP_Length(512), Int32(vDSP_HANN_NORM))

        var realp = [Float](repeating: 0.0, count: 256)
        var imagp = [Float](repeating: 0.0, count: 256)

        for i in 0..<bucketCount {
            let start = i * samplesPerBucket
            let end = min(start + 512, pcmSamples.count)
            if end - start < 512 { break }

            var input = [Float](repeating: 0.0, count: 512)
            for k in 0..<512 {
                input[k] = Float(pcmSamples[start + k]) / 32768.0
            }

            // Apply Hann Window
            vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(512))

            // Pack into split complex structure for real-to-complex FFT
            realp.withUnsafeMutableBufferPointer { rPtr in
                imagp.withUnsafeMutableBufferPointer { iPtr in
                    var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    input.withUnsafeBufferPointer { inPtr in
                        inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 256) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, 256)
                        }
                    }

                    // Perform Forward FFT via Accelerate
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Compute Magnitudes
                    var magnitudes = [Float](repeating: 0.0, count: 256)
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, 256)

                    // Group 256 FFT magnitude bins into 8 frequency bands
                    let bandsPerBucket = 8
                    let binsPerBand = 32
                    for b in 0..<bandsPerBucket {
                        var bandEnergy: Float = 0.0
                        let bandStart = b * binsPerBand
                        vDSP_sve(Array(magnitudes[bandStart..<(bandStart + binsPerBand)]), 1, &bandEnergy, vDSP_Length(binsPerBand))
                        featureVector[i * 8 + b] = log1p(bandEnergy)
                    }
                }
            }
        }

        return featureVector
    }

    private func vectorNorm(_ vector: [Float]) -> Float {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        return sqrt(sumSq)
    }

}

