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

            // 2. Extract SEPARATE intro (first 5 min) and credits (last 5 min) audio for each episode
            let introExtractSec = 300  // first 5 minutes
            let creditsExtractSec = 300 // last 5 minutes

            struct EpisodeAudio {
                let introFeatures: [Float]  // FFT features from first 5 min
                let creditsFeatures: [Float] // FFT features from last 5 min
                let durationSec: Int         // total episode duration
            }

            var episodeAudio: [String: EpisodeAudio] = [:]

            for (idx, video) in videoFiles.enumerated() {
                let pct = 5 + Int((Double(idx + 1) / Double(videoFiles.count)) * 40.0)
                progressHandler("Extracting audio for \(video.lastPathComponent)...", pct)
                log("Extracting audio (intro + credits) (\(idx + 1)/\(videoFiles.count)): \(video.lastPathComponent)")

                // Get episode duration via ffprobe
                var epDurationSec = 3000 // fallback 50 min
                if let meta = await FFmpegService.shared.inspectMedia(url: video) {
                    epDurationSec = max(meta.durationMs / 1000, 600)
                    log("  Duration: \(epDurationSec / 60)m \(epDurationSec % 60)s")
                }

                // Extract first 5 minutes (for intro detection)
                let introFeatures = await self.extractFeatureVector(
                    url: video, startSec: 0, durationSec: introExtractSec
                )
                log("  Intro region: \(introFeatures.count / 8) buckets (first \(introExtractSec)s)")

                // Extract last 5 minutes (for credits detection)
                let creditsStartSec = max(0, epDurationSec - creditsExtractSec)
                let creditsFeatures = await self.extractFeatureVector(
                    url: video, startSec: creditsStartSec, durationSec: creditsExtractSec
                )
                log("  Credits region: \(creditsFeatures.count / 8) buckets (last \(creditsExtractSec)s, from \(creditsStartSec)s)")

                episodeAudio[video.lastPathComponent] = EpisodeAudio(
                    introFeatures: introFeatures,
                    creditsFeatures: creditsFeatures,
                    durationSec: epDurationSec
                )
            }

            progressHandler("Cross-correlating intro fingerprints...", 50)
            log("Phase 2: Cross-correlating intro audio across episodes...")

            // 3. Find repeating INTRO pattern by cross-correlating first-5-min audio across episodes
            let sampleEpisodes = Array(videoFiles.prefix(5))
            let targetThresh = Float(similarityThreshold)

            // Window lengths in buckets (4 buckets/sec): 20s=80, 30s=120, 45s=180, 60s=240
            let introWindowLengths = [80, 120, 180, 240]
            let creditsWindowLengths = [80, 120, 180, 240]

            var bestIntroTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?
            var bestCreditsTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?

            // --- INTRO template detection ---
            if let baseName = sampleEpisodes.first?.lastPathComponent,
               let baseAudio = episodeAudio[baseName] {

                let baseBuckets = baseAudio.introFeatures
                let totalBuckets = baseBuckets.count / 8

                for wLen in introWindowLengths {
                    guard totalBuckets > wLen else { continue }

                    for startIdx in stride(from: 0, to: totalBuckets - wLen, by: 4) {
                        let sliceA = Array(baseBuckets[(startIdx * 8)..<((startIdx + wLen) * 8)])
                        let normA = self.vectorNorm(sliceA)
                        guard normA > 0.01 else { continue }

                        var matchCount = 0
                        var totalScore: Float = 0

                        for ep in sampleEpisodes.dropFirst() {
                            guard let epAudio = episodeAudio[ep.lastPathComponent] else { continue }
                            let epBuckets = epAudio.introFeatures
                            let epTotal = epBuckets.count / 8
                            var bestSim: Float = 0

                            // Search within +-60s window
                            let searchStart = max(0, startIdx - 240)
                            let searchEnd = min(max(0, epTotal - wLen), startIdx + 240)

                            if searchEnd > searchStart {
                                for targetIdx in stride(from: searchStart, to: searchEnd, by: 4) {
                                    let end = (targetIdx + wLen) * 8
                                    guard end <= epBuckets.count else { break }
                                    let sliceB = Array(epBuckets[(targetIdx * 8)..<end])
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

                        if matchCount >= max(1, sampleEpisodes.count - 2) {
                            let avgScore = totalScore / Float(matchCount)
                            if bestIntroTemplate == nil || avgScore > bestIntroTemplate!.score {
                                bestIntroTemplate = (startBucket: startIdx, wLen: wLen, score: avgScore, baseName: baseName)
                            }
                        }
                    }
                }
            }

            progressHandler("Cross-correlating credits fingerprints...", 60)
            log("Phase 3: Cross-correlating credits audio across episodes...")

            // --- CREDITS template detection ---
            if let baseName = sampleEpisodes.first?.lastPathComponent,
               let baseAudio = episodeAudio[baseName] {

                let baseBuckets = baseAudio.creditsFeatures
                let totalBuckets = baseBuckets.count / 8

                for wLen in creditsWindowLengths {
                    guard totalBuckets > wLen else { continue }

                    for startIdx in stride(from: 0, to: totalBuckets - wLen, by: 4) {
                        let sliceA = Array(baseBuckets[(startIdx * 8)..<((startIdx + wLen) * 8)])
                        let normA = self.vectorNorm(sliceA)
                        guard normA > 0.01 else { continue }

                        var matchCount = 0
                        var totalScore: Float = 0

                        for ep in sampleEpisodes.dropFirst() {
                            guard let epAudio = episodeAudio[ep.lastPathComponent] else { continue }
                            let epBuckets = epAudio.creditsFeatures
                            let epTotal = epBuckets.count / 8
                            var bestSim: Float = 0

                            let searchStart = max(0, startIdx - 240)
                            let searchEnd = min(max(0, epTotal - wLen), startIdx + 240)

                            if searchEnd > searchStart {
                                for targetIdx in stride(from: searchStart, to: searchEnd, by: 4) {
                                    let end = (targetIdx + wLen) * 8
                                    guard end <= epBuckets.count else { break }
                                    let sliceB = Array(epBuckets[(targetIdx * 8)..<end])
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

                        if matchCount >= max(1, sampleEpisodes.count - 2) {
                            let avgScore = totalScore / Float(matchCount)
                            if bestCreditsTemplate == nil || avgScore > bestCreditsTemplate!.score {
                                bestCreditsTemplate = (startBucket: startIdx, wLen: wLen, score: avgScore, baseName: baseName)
                            }
                        }
                    }
                }
            }

            // Log discovered templates
            if let t = bestIntroTemplate {
                let s = Double(t.startBucket) * 0.25, e = Double(t.startBucket + t.wLen) * 0.25
                log(String(format: "INTRO template found in first 5 min: %02d:%02d - %02d:%02d (%.1f%%)", Int(s)/60, Int(s)%60, Int(e)/60, Int(e)%60, t.score * 100))
            } else {
                log("No INTRO template found above threshold")
            }
            if let t = bestCreditsTemplate {
                let s = Double(t.startBucket) * 0.25, e = Double(t.startBucket + t.wLen) * 0.25
                log(String(format: "CREDITS template found in last 5 min: %02d:%02d - %02d:%02d offset (%.1f%%)", Int(s)/60, Int(s)%60, Int(e)/60, Int(e)%60, t.score * 100))
            } else {
                log("No CREDITS template found above threshold")
            }

            progressHandler("Locating per-episode segment positions...", 75)

            // 4. For each episode, locate exact intro/credits position by sliding the template
            var results: [String: [RCDMatch]] = [:]

            for (epIdx, video) in videoFiles.enumerated() {
                let epName = video.lastPathComponent
                var matches: [RCDMatch] = []

                guard let epAudio = episodeAudio[epName] else {
                    results[epName] = matches
                    continue
                }

                let pct = 75 + Int((Double(epIdx + 1) / Double(videoFiles.count)) * 20.0)
                progressHandler("Locating segments for \(epName)...", pct)

                // --- Per-episode INTRO localization (in first-5-min audio) ---
                if let t = bestIntroTemplate {
                    let baseBuckets = episodeAudio[t.baseName]!.introFeatures
                    let templateSlice = Array(baseBuckets[(t.startBucket * 8)..<((t.startBucket + t.wLen) * 8)])
                    let normT = self.vectorNorm(templateSlice)

                    let epBuckets = epAudio.introFeatures
                    let epTotal = epBuckets.count / 8
                    let searchMax = max(0, epTotal - t.wLen)
                    var bestSim: Float = 0
                    var bestStart = t.startBucket

                    if searchMax > 0 && normT > 0.01 {
                        for targetIdx in stride(from: 0, to: searchMax, by: 2) {
                            let end = (targetIdx + t.wLen) * 8
                            guard end <= epBuckets.count else { break }
                            let sliceB = Array(epBuckets[(targetIdx * 8)..<end])
                            let normB = self.vectorNorm(sliceB)
                            if normB > 0.01 {
                                var dot: Float = 0
                                vDSP_dotpr(templateSlice, 1, sliceB, 1, &dot, vDSP_Length(t.wLen * 8))
                                let sim = dot / (normT * normB)
                                if sim > bestSim {
                                    bestSim = sim
                                    bestStart = targetIdx
                                }
                            }
                        }
                    }

                    // startSec/endSec are absolute times (intro is from start of video)
                    let startSec = Double(bestStart) * 0.25
                    let endSec = Double(bestStart + t.wLen) * 0.25
                    let conf = bestSim > 0 ? bestSim : t.score
                    matches.append(RCDMatch(type: .intro, startSec: startSec, endSec: endSec, confidence: conf))
                    log(String(format: "  [%@] INTRO: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                }

                // --- Per-episode CREDITS localization (in last-5-min audio) ---
                if let t = bestCreditsTemplate {
                    let baseBuckets = episodeAudio[t.baseName]!.creditsFeatures
                    let templateSlice = Array(baseBuckets[(t.startBucket * 8)..<((t.startBucket + t.wLen) * 8)])
                    let normT = self.vectorNorm(templateSlice)

                    let epBuckets = epAudio.creditsFeatures
                    let epTotal = epBuckets.count / 8
                    let searchMax = max(0, epTotal - t.wLen)
                    var bestSim: Float = 0
                    var bestStart = t.startBucket

                    if searchMax > 0 && normT > 0.01 {
                        for targetIdx in stride(from: 0, to: searchMax, by: 2) {
                            let end = (targetIdx + t.wLen) * 8
                            guard end <= epBuckets.count else { break }
                            let sliceB = Array(epBuckets[(targetIdx * 8)..<end])
                            let normB = self.vectorNorm(sliceB)
                            if normB > 0.01 {
                                var dot: Float = 0
                                vDSP_dotpr(templateSlice, 1, sliceB, 1, &dot, vDSP_Length(t.wLen * 8))
                                let sim = dot / (normT * normB)
                                if sim > bestSim {
                                    bestSim = sim
                                    bestStart = targetIdx
                                }
                            }
                        }
                    }

                    // Convert offset within last-5-min segment to absolute time
                    let creditsStartOffset = max(0, epAudio.durationSec - creditsExtractSec)
                    let startSec = Double(creditsStartOffset) + Double(bestStart) * 0.25
                    let endSec = Double(creditsStartOffset) + Double(bestStart + t.wLen) * 0.25
                    let conf = bestSim > 0 ? bestSim : t.score
                    matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: conf))
                    log(String(format: "  [%@] CREDITS: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                }

                results[epName] = matches
            }

            log("Season scan complete — located per-episode segments across \(videoFiles.count) episodes!")
            progressHandler("RCD Season Fingerprinting Complete!", 100)
            return results

        }.value
    }



    private func extractFeatureVector(url: URL, startSec: Int, durationSec: Int) async -> [Float] {
        let pcmSamples = (try? await FFmpegService.shared.extractPCMAudioSnippet(
            url: url, startSec: startSec, durationSec: durationSec
        )) ?? []
        return computeFFTFeatures(from: pcmSamples)
    }

    private func extractFastFeatureVector(url: URL) async -> [Float] {
        let pcmSamples = (try? await FFmpegService.shared.extractPCMAudioSnippet(url: url, durationSec: 900)) ?? []
        return computeFFTFeatures(from: pcmSamples)
    }

    private func computeFFTFeatures(from pcmSamples: [Int16]) -> [Float] {
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
