import Foundation
import AVFoundation
import Accelerate
import Vision
import AppKit

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
                log("  Intro region: \(introFeatures.count / 12) frames (first \(introExtractSec)s)")

                // Extract last 5 minutes (for credits detection)
                let creditsStartSec = max(0, epDurationSec - creditsExtractSec)
                let creditsFeatures = await self.extractFeatureVector(
                    url: video, startSec: creditsStartSec, durationSec: creditsExtractSec
                )
                log("  Credits region: \(creditsFeatures.count / 12) frames (last \(creditsExtractSec)s, from \(creditsStartSec)s)")

                episodeAudio[video.lastPathComponent] = EpisodeAudio(
                    introFeatures: introFeatures,
                    creditsFeatures: creditsFeatures,
                    durationSec: epDurationSec
                )
            }

            progressHandler("Cross-correlating intro fingerprints...", 50)
            log("Phase 2: Cross-correlating intro chroma vectors across episodes...")

            // Constants for new chroma feature layout
            let C = 12              // chroma bins per frame
            let secPerFrame = 0.128 // each frame = hopSize/sampleRate = 512/4000

            // 3. Find repeating INTRO & CREDITS patterns by cross-correlating audio across sample episodes
            let sampleEpisodes = Array(videoFiles.prefix(min(5, videoFiles.count)))
            let targetThresh = Float(similarityThreshold)

            // Window lengths in frames (~8.0 fps): 10s=78, 15s=117, 20s=156, 30s=234, 45s=352, 60s=469, 90s=703
            let introWindowLengths = [78, 117, 156, 234, 352, 469, 703]
            let creditsWindowLengths = [78, 117, 156, 234, 352, 469, 703]

            var bestIntroTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?
            var bestCreditsTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?

            // Helper function to find best template across sample episodes with adaptive thresholding
            func findBestTemplate(isIntro: Bool) -> (startBucket: Int, wLen: Int, score: Float, baseName: String)? {
                let windowLengths = isIntro ? introWindowLengths : creditsWindowLengths
                let thresholdsToTry: [Float] = [targetThresh, 0.65, 0.50, 0.40]

                for minThresh in thresholdsToTry {
                    var bestForThresh: (startBucket: Int, wLen: Int, score: Float, baseName: String, weightedScore: Float)?

                    for baseEp in sampleEpisodes {
                        let baseName = baseEp.lastPathComponent
                        guard let baseAudio = episodeAudio[baseName] else { continue }
                        let baseBuckets = isIntro ? baseAudio.introFeatures : baseAudio.creditsFeatures
                        let totalFrames = baseBuckets.count / C

                        for wLen in windowLengths {
                            guard totalFrames > wLen else { continue }

                            for startIdx in stride(from: 0, to: totalFrames - wLen, by: 4) {
                                let sliceA = Array(baseBuckets[(startIdx * C)..<((startIdx + wLen) * C)])
                                let normA = self.vectorNorm(sliceA)
                                guard normA > 0.01 else { continue }

                                var matchCount = 0
                                var totalScore: Float = 0

                                for otherEp in sampleEpisodes where otherEp.lastPathComponent != baseName {
                                    guard let epAudio = episodeAudio[otherEp.lastPathComponent] else { continue }
                                    let epBuckets = isIntro ? epAudio.introFeatures : epAudio.creditsFeatures
                                    let epTotal = epBuckets.count / C
                                    var bestSim: Float = 0

                                    let searchMax = max(0, epTotal - wLen)
                                    if searchMax > 0 {
                                        for targetIdx in stride(from: 0, to: searchMax, by: 4) {
                                            let end = (targetIdx + wLen) * C
                                            guard end <= epBuckets.count else { break }
                                            let sliceB = Array(epBuckets[(targetIdx * C)..<end])
                                            let normB = self.vectorNorm(sliceB)
                                            if normB > 0.01 {
                                                var dot: Float = 0
                                                vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(wLen * C))
                                                let sim = dot / (normA * normB)
                                                if sim > bestSim { bestSim = sim }
                                            }
                                        }
                                    }

                                    if bestSim >= minThresh {
                                        matchCount += 1
                                        totalScore += bestSim
                                    }
                                }

                                if matchCount >= max(1, (sampleEpisodes.count - 1) / 2) {
                                    let avgScore = totalScore / Float(matchCount)
                                    // Weight score by window duration so full 45s-90s intros win over tiny 10s snippets
                                    let durationWeight = sqrt(Float(wLen) * Float(secPerFrame) / 30.0)
                                    let weightedScore = avgScore * durationWeight

                                    if bestForThresh == nil || weightedScore > bestForThresh!.weightedScore {
                                        bestForThresh = (startBucket: startIdx, wLen: wLen, score: avgScore, baseName: baseName, weightedScore: weightedScore)
                                    }
                                }
                            }
                        }
                    }

                    if let found = bestForThresh {
                        if minThresh < targetThresh {
                            log(String(format: "Adaptive threshold fallback used: %.0f%% for \(isIntro ? "INTRO" : "CREDITS")", minThresh * 100))
                        }
                        return (startBucket: found.startBucket, wLen: found.wLen, score: found.score, baseName: found.baseName)
                    }
                }

                return nil
            }

            // --- INTRO template detection ---
            bestIntroTemplate = findBestTemplate(isIntro: true)

            progressHandler("Cross-correlating credits fingerprints...", 60)
            log("Phase 3: Cross-correlating credits chroma vectors across episodes...")

            // --- CREDITS template detection ---
            bestCreditsTemplate = findBestTemplate(isIntro: false)

            // Log discovered templates
            if let t = bestIntroTemplate {
                let s = Double(t.startBucket) * secPerFrame, e = Double(t.startBucket + t.wLen) * secPerFrame
                log(String(format: "INTRO template found in first 5 min: %02d:%02d - %02d:%02d (confidence: %.1f%%, base: %@)", Int(s)/60, Int(s)%60, Int(e)/60, Int(e)%60, t.score * 100, t.baseName))
            } else {
                log("No INTRO template found across episodes")
            }
            if let t = bestCreditsTemplate {
                let s = Double(t.startBucket) * secPerFrame, e = Double(t.startBucket + t.wLen) * secPerFrame
                log(String(format: "CREDITS template found in last 5 min: %02d:%02d - %02d:%02d offset (confidence: %.1f%%, base: %@)", Int(s)/60, Int(s)%60, Int(e)/60, Int(e)%60, t.score * 100, t.baseName))
            } else {
                log("No CREDITS template found across episodes")
            }

            progressHandler("Locating per-episode segment positions...", 75)

            // 4. For each episode, locate exact intro/credits position by sliding the template & expanding boundaries
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

                // --- Per-episode INTRO localization (in first-5-min chroma) ---
                if let t = bestIntroTemplate {
                    let baseBuckets = episodeAudio[t.baseName]!.introFeatures
                    let templateSlice = Array(baseBuckets[(t.startBucket * C)..<((t.startBucket + t.wLen) * C)])
                    let normT = self.vectorNorm(templateSlice)

                    let epBuckets = epAudio.introFeatures
                    let epTotal = epBuckets.count / C
                    let searchMax = max(0, epTotal - t.wLen)
                    var bestSim: Float = 0
                    var bestStart = t.startBucket

                    if searchMax > 0 && normT > 0.01 {
                        for targetIdx in stride(from: 0, to: searchMax, by: 4) {
                            let end = (targetIdx + t.wLen) * C
                            guard end <= epBuckets.count else { break }
                            let sliceB = Array(epBuckets[(targetIdx * C)..<end])
                            let normB = self.vectorNorm(sliceB)
                            if normB > 0.01 {
                                var dot: Float = 0
                                vDSP_dotpr(templateSlice, 1, sliceB, 1, &dot, vDSP_Length(t.wLen * C))
                                let sim = dot / (normT * normB)
                                if sim > bestSim {
                                    bestSim = sim
                                    bestStart = targetIdx
                                }
                            }
                        }
                    }

                    // Expand boundaries forward/backward to capture the full intro length
                    let (expStart, expEnd) = self.expandBoundaries(
                        baseBuckets: baseBuckets,
                        epBuckets: epBuckets,
                        seedStart: bestStart,
                        seedWLen: t.wLen,
                        C: C
                    )

                    let startSec = Double(expStart) * secPerFrame
                    let endSec = Double(expEnd) * secPerFrame
                    let conf = bestSim > 0 ? bestSim : t.score
                    matches.append(RCDMatch(type: .intro, startSec: startSec, endSec: endSec, confidence: conf))
                    log(String(format: "  [%@] INTRO: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                }

                // --- Per-episode CREDITS localization (in last-5-min chroma) ---
                if let t = bestCreditsTemplate {
                    let baseBuckets = episodeAudio[t.baseName]!.creditsFeatures
                    let templateSlice = Array(baseBuckets[(t.startBucket * C)..<((t.startBucket + t.wLen) * C)])
                    let normT = self.vectorNorm(templateSlice)

                    let epBuckets = epAudio.creditsFeatures
                    let epTotal = epBuckets.count / C
                    let searchMax = max(0, epTotal - t.wLen)
                    var bestSim: Float = 0
                    var bestStart = t.startBucket

                    if searchMax > 0 && normT > 0.01 {
                        for targetIdx in stride(from: 0, to: searchMax, by: 4) {
                            let end = (targetIdx + t.wLen) * C
                            guard end <= epBuckets.count else { break }
                            let sliceB = Array(epBuckets[(targetIdx * C)..<end])
                            let normB = self.vectorNorm(sliceB)
                            if normB > 0.01 {
                                var dot: Float = 0
                                vDSP_dotpr(templateSlice, 1, sliceB, 1, &dot, vDSP_Length(t.wLen * C))
                                let sim = dot / (normT * normB)
                                if sim > bestSim {
                                    bestSim = sim
                                    bestStart = targetIdx
                                }
                            }
                        }
                    }

                    // Expand boundaries forward/backward to capture full credits length
                    let (expStart, expEnd) = self.expandBoundaries(
                        baseBuckets: baseBuckets,
                        epBuckets: epBuckets,
                        seedStart: bestStart,
                        seedWLen: t.wLen,
                        C: C
                    )

                    // Convert offset within last-5-min segment to absolute time
                    let creditsStartOffset = max(0, epAudio.durationSec - creditsExtractSec)
                    let startSec = Double(creditsStartOffset) + Double(expStart) * secPerFrame
                    let endSec = Double(creditsStartOffset) + Double(expEnd) * secPerFrame
                    let conf = bestSim > 0 ? bestSim : t.score
                    matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: conf))
                    log(String(format: "  [%@] CREDITS: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                }


                let finalMatches = await self.refineMatchesWithVisionAI(
                    matches: matches,
                    videoURL: video,
                    method: method,
                    log: log
                )
                results[epName] = finalMatches
            }

            log("Season scan complete — located per-episode segments across \(videoFiles.count) episodes!")
            progressHandler("RCD Season Fingerprinting Complete!", 100)
            return results


        }.value
    }


    /// Extract chroma feature vector from a specific time region of a video
    private func extractFeatureVector(url: URL, startSec: Int, durationSec: Int) async -> [Float] {
        let pcmSamples = (try? await FFmpegService.shared.extractPCMAudioSnippet(
            url: url, startSec: startSec, durationSec: durationSec
        )) ?? []
        return computeChromaFeatures(from: pcmSamples)
    }

    private func extractFastFeatureVector(url: URL) async -> [Float] {
        let pcmSamples = (try? await FFmpegService.shared.extractPCMAudioSnippet(url: url, durationSec: 900)) ?? []
        return computeChromaFeatures(from: pcmSamples)
    }

    // MARK: - Chromaprint-Inspired 12-Bin Chroma Feature Extraction
    //
    // Based on research from:
    //   - Chromaprint/AcoustID (Lukáš Lalinský) — 12-bin chroma pitch class profiles
    //   - Jellyfin Intro Skipper — chromaprint + pairwise episode comparison
    //   - Plex Intro Detection — audio fingerprint cross-correlation
    //
    // Key improvements over previous 8-band FFT energy approach:
    //   1. 12 chroma bins (C, C#, D... B) — maps FFT bins to musical notes, discarding octave
    //   2. L2 normalization per frame — amplitude-invariant matching
    //   3. Higher FFT resolution (4096 samples @ 11025 Hz, matching Chromaprint spec)
    //   4. Overlapping frames (2/3 overlap) for smoother temporal resolution

    private func computeChromaFeatures(from pcmSamples: [Int16]) -> [Float] {
        guard pcmSamples.count >= 4096 else { return [] }

        // Audio is at 4000 Hz sample rate from FFmpeg extraction
        let sampleRate: Float = 4000.0
        let frameSize = 2048        // ~0.512s at 4000Hz
        let hopSize = 512           // ~0.128s hop → ~8 frames/sec (higher temporal resolution)
        let chromaBins = 12         // 12 pitch classes (C through B)

        let totalFrames = max(0, (pcmSamples.count - frameSize) / hopSize)
        guard totalFrames > 0 else { return [] }

        var featureVector = [Float](repeating: 0.0, count: totalFrames * chromaBins)

        // Prepare FFT setup for N=2048 using Accelerate vDSP
        let log2n = vDSP_Length(11)  // 2^11 = 2048
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window for spectral leakage reduction
        var window = [Float](repeating: 0.0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        // Pre-compute FFT bin → chroma bin mapping
        // For each FFT magnitude bin k, frequency = k * sampleRate / frameSize
        // Map frequency to MIDI note: 69 + 12 * log2(freq / 440)
        // Chroma bin = MIDI note % 12
        let halfN = frameSize / 2
        var binToChroma = [Int](repeating: -1, count: halfN)
        for k in 1..<halfN {
            let freq = Float(k) * sampleRate / Float(frameSize)
            if freq < 65.0 || freq > 2000.0 { continue } // Focus on 65Hz–2000Hz (musically relevant range)
            let midiNote = 69.0 + 12.0 * log2(Double(freq) / 440.0)
            let chromaBin = Int(round(midiNote)) % 12
            binToChroma[k] = (chromaBin + 12) % 12  // ensure positive
        }

        var realp = [Float](repeating: 0.0, count: halfN)
        var imagp = [Float](repeating: 0.0, count: halfN)

        for frame in 0..<totalFrames {
            let start = frame * hopSize

            // Convert Int16 PCM to Float32 and apply window
            var input = [Float](repeating: 0.0, count: frameSize)
            for k in 0..<frameSize {
                input[k] = Float(pcmSamples[start + k]) / 32768.0
            }
            vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(frameSize))

            // Compute FFT via Accelerate
            realp.withUnsafeMutableBufferPointer { rPtr in
                imagp.withUnsafeMutableBufferPointer { iPtr in
                    var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    input.withUnsafeBufferPointer { inPtr in
                        inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Compute magnitudes
                    var magnitudes = [Float](repeating: 0.0, count: halfN)
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                    // Accumulate magnitude into 12 chroma bins
                    var chroma = [Float](repeating: 0.0, count: chromaBins)
                    for k in 1..<halfN {
                        let bin = binToChroma[k]
                        if bin >= 0 {
                            chroma[bin] += magnitudes[k]
                        }
                    }

                    // L2 normalization (amplitude-invariant, crucial for matching different masters/volumes)
                    var sumSq: Float = 0
                    vDSP_svesq(chroma, 1, &sumSq, vDSP_Length(chromaBins))
                    let norm = sqrt(sumSq)
                    if norm > 1e-6 {
                        var invNorm = 1.0 / norm
                        vDSP_vsmul(chroma, 1, &invNorm, &chroma, 1, vDSP_Length(chromaBins))
                    }

                    // Store normalized chroma vector
                    for b in 0..<chromaBins {
                        featureVector[frame * chromaBins + b] = chroma[b]
                    }
                }
            }
        }

        return featureVector
    }

    /// Expands a seed matching window [seedStart, seedStart + seedWLen] backwards and forwards
    /// frame-by-frame while local chroma correlation remains high (>= 0.35) to capture full intro/outro lengths.
    private func expandBoundaries(
        baseBuckets: [Float],
        epBuckets: [Float],
        seedStart: Int,
        seedWLen: Int,
        C: Int
    ) -> (startFrame: Int, endFrame: Int) {
        var curStart = seedStart
        var curEnd = seedStart + seedWLen
        let totalEpFrames = epBuckets.count / C
        let totalBaseFrames = baseBuckets.count / C

        let win = 16 // 2-second check window for expansion (~16 frames)

        // Expand backward
        while curStart >= win {
            let testStart = curStart - win
            guard testStart * C + win * C <= baseBuckets.count && testStart * C + win * C <= epBuckets.count else { break }
            let sliceA = Array(baseBuckets[(testStart * C)..<((testStart + win) * C)])
            let sliceB = Array(epBuckets[(testStart * C)..<((testStart + win) * C)])
            let normA = self.vectorNorm(sliceA)
            let normB = self.vectorNorm(sliceB)
            if normA > 0.01 && normB > 0.01 {
                var dot: Float = 0
                vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(win * C))
                let sim = dot / (normA * normB)
                if sim >= 0.35 {
                    curStart = testStart
                    continue
                }
            }
            break
        }

        // Expand forward
        while curEnd + win <= totalEpFrames && curEnd + win <= totalBaseFrames {
            let testEnd = curEnd + win
            let sliceA = Array(baseBuckets[(curEnd * C)..<(testEnd * C)])
            let sliceB = Array(epBuckets[(curEnd * C)..<(testEnd * C)])
            let normA = self.vectorNorm(sliceA)
            let normB = self.vectorNorm(sliceB)
            if normA > 0.01 && normB > 0.01 {
                var dot: Float = 0
                vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(win * C))
                let sim = dot / (normA * normB)
                if sim >= 0.35 {
                    curEnd = testEnd
                    continue
                }
            }
            break
        }

        return (curStart, curEnd)
    }

    /// Compute L2 norm of a feature vector using vDSP
    private func vectorNorm(_ vector: [Float]) -> Float {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        return sqrt(sumSq)
    }


    // MARK: - Apple Vision AI Framework Integration

    /// Uses Apple's Vision framework (VNDetectTextRectanglesRequest) & luminance analysis
    /// to detect credit text blocks and black frame transitions in video keyframes.
    private func analyzeVisualCreditsWithVisionAI(
        url: URL,
        candidateStartSec: Double,
        candidateEndSec: Double
    ) async -> (textDensity: Float, blackFrameDetected: Bool) {
        let sampleTimesSec = [
            Int(candidateStartSec),
            Int(candidateStartSec + 5.0),
            Int(max(candidateStartSec, candidateEndSec - 5.0))
        ]

        var totalTextRects = 0
        var foundBlackFrame = false

        for timeSec in sampleTimesSec {
            guard let jpegData = await FFmpegService.shared.extractThumbnailData(url: url, timeMs: timeSec * 1000),
                  let nsImage = NSImage(data: jpegData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            // 1. Text Rectangle Detection via Apple Vision AI
            let textRequest = VNDetectTextRectanglesRequest()
            textRequest.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([textRequest])

            if let results = textRequest.results {
                totalTextRects += results.count
            }

            // 2. Black Frame Luminance Check
            let width = cgImage.width
            let height = cgImage.height
            if width > 0 && height > 0 {
                let colorSpace = CGColorSpaceCreateDeviceGray()
                var rawData = [UInt8](repeating: 0, count: width * height)
                if let context = CGContext(
                    data: &rawData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) {
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                    var sumLuminance: Double = 0
                    for px in rawData {
                        sumLuminance += Double(px)
                    }
                    let avgLuminance = Float(sumLuminance / Double(rawData.count))
                    if avgLuminance < 25.0 { // Average brightness threshold for black frame
                        foundBlackFrame = true
                    }

                }
            }
        }

        let textDensity = Float(totalTextRects) / Float(max(1, sampleTimesSec.count))
        return (textDensity: textDensity, blackFrameDetected: foundBlackFrame)
    }

    /// Refines RCDMatch results using Apple Vision AI framework text recognition & visual analysis
    private func refineMatchesWithVisionAI(
        matches: [RCDMatch],
        videoURL: URL,
        method: RCDDetectionMethod,
        log: (String) -> Void
    ) async -> [RCDMatch] {
        switch method {
        case .audioChromagram:
            log("  [Method: Audio Chromagram] Using pure 12-bin pitch chromagram cross-correlation.")
            return matches

        case .appleHWAccelerated, .visualKeyframe, .hybridFusion:
            log("  [Method: \(method.rawValue)] Running Apple Vision AI OCR text & luminance frame inspection...")
            var refined: [RCDMatch] = []

            for match in matches {
                if match.type == .credits {
                    let (textDensity, blackFrame) = await analyzeVisualCreditsWithVisionAI(
                        url: videoURL,
                        candidateStartSec: match.startSec,
                        candidateEndSec: match.endSec
                    )

                    var boostedConf = match.confidence
                    if method == .hybridFusion {
                        // 60% Audio + 40% Vision AI score fusion
                        let visionScore = min(1.0, (textDensity / 10.0) + (blackFrame ? 0.3 : 0.0))
                        boostedConf = (0.60 * match.confidence) + (0.40 * visionScore)
                        log(String(format: "  [Multimodal AI Fusion] Fused 60%% Audio (%.1f%%) + 40%% Vision AI (%.1f%%) -> Final: %.1f%%", match.confidence * 100, visionScore * 100, boostedConf * 100))
                    } else {
                        if textDensity > 3.0 {
                            boostedConf = min(1.0, boostedConf + 0.12)
                            log(String(format: "  [Vision AI] Detected scrolling credits text blocks (density: %.1f). Boosted confidence to %.1f%%", textDensity, boostedConf * 100))
                        }
                        if blackFrame {
                            boostedConf = min(1.0, boostedConf + 0.08)
                            log(String(format: "  [Vision AI] Black frame transition detected at credits start. Boosted confidence to %.1f%%", boostedConf * 100))
                        }
                    }

                    refined.append(RCDMatch(
                        type: match.type,
                        startSec: match.startSec,
                        endSec: match.endSec,
                        confidence: boostedConf
                    ))
                } else {
                    refined.append(match)
                }
            }
            return refined
        }
    }
}

