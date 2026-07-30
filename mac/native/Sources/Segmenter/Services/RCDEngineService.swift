import Foundation
import AVFoundation
import Accelerate
import Vision
import AppKit

public struct RCDMatch: Codable, Equatable, Sendable {
    public let type: SegmentType
    public let startSec: Double
    public let endSec: Double
    public let confidence: Float
}

/// Per-episode chroma feature vectors for the intro (first 5 min) and credits (last 5 min) regions.
/// Hoisted to file scope (rather than local to `scanSeason`) so it can be shared with the
/// parallel template-search helper below.
struct RCDEpisodeAudio: Sendable {
    let introFeatures: [Float]
    let creditsFeatures: [Float]
    let durationSec: Int
    /// Length of the analysed regions for this episode. Scaled per-episode from its duration
    /// (see `searchRegionSeconds`), so it must travel with the features — the credits offset is
    /// converted back to absolute time using this episode's own region length.
    let introRegionSec: Int
    let creditsRegionSec: Int
}

/// Search-region sizes, scaled to episode length rather than fixed.
///
/// A fixed 10-minute intro window is 20% of a 50-minute drama but 45% of a 22-minute animation —
/// and every extra minute searched is more room for incidental music to out-score the real theme.
/// Scaling keeps the searched fraction roughly constant across formats. The floors keep very short
/// episodes workable; the ceilings stop feature extraction from ballooning on long ones.
func searchRegionSeconds(forDurationSec duration: Int) -> (intro: Int, credits: Int) {
    let intro = min(600, max(240, Int(Double(duration) * 0.25)))
    let credits = min(360, max(150, Int(Double(duration) * 0.18)))
    return (intro, credits)
}

/// A single (base episode, window length) candidate match produced while searching for the
/// best recurring INTRO/CREDITS template across sample episodes.
private struct RCDTemplateCandidate: Sendable {
    let startBucket: Int
    let wLen: Int
    let score: Float
    let baseName: String
    let weightedScore: Float
}

// Stateless (no mutable stored properties) — every method is a pure function of its
// parameters, so it's safe to call concurrently from multiple parallel tasks.
public final class RCDEngineService: @unchecked Sendable {
    public static let shared = RCDEngineService()

    private init() {}

    static let supportedVideoExtensions = ["mp4", "mkv", "avi", "mov", "webm", "m4v"]

    /// Scans a directory of episode videos and detects repeated Intro/Credits content across episodes
    public func scanSeason(
        directoryURL: URL,
        method: RCDDetectionMethod = .appleHWAccelerated,
        minSegmentLengthSec: Double = 15.0,
        similarityThreshold: Double = 0.80,
        debugLogger: ((String) -> Void)? = nil,
        progressHandler: @escaping (String, Int) -> Void
    ) async throws -> [String: [RCDMatch]] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: keys) else {
            throw NSError(domain: "RCDEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate season directory: \(directoryURL.path)"])
        }

        var videoFiles = enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { Self.supportedVideoExtensions.contains($0.pathExtension.lowercased()) }

        // Natural sort filenames (S01E01, S01E02...)
        videoFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !videoFiles.isEmpty else {
            throw NSError(domain: "RCDEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Directory contains no supported video files"])
        }

        return try await runScan(
            videoFiles: videoFiles,
            sourceDescription: directoryURL.path,
            method: method,
            minSegmentLengthSec: minSegmentLengthSec,
            similarityThreshold: similarityThreshold,
            debugLogger: debugLogger,
            progressHandler: progressHandler
        )
    }

    /// Scans a single standalone video file without needing sibling episodes to compare against.
    /// Boundaries come from structural heuristics within the one file rather than cross-episode
    /// matching, so results are less precise than a full season scan.
    public func scanSingleEpisode(
        videoURL: URL,
        method: RCDDetectionMethod = .singleEpisodeAI,
        minSegmentLengthSec: Double = 15.0,
        similarityThreshold: Double = 0.80,
        debugLogger: ((String) -> Void)? = nil,
        progressHandler: @escaping (String, Int) -> Void
    ) async throws -> [String: [RCDMatch]] {
        guard Self.supportedVideoExtensions.contains(videoURL.pathExtension.lowercased()) else {
            throw NSError(domain: "RCDEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported video format: .\(videoURL.pathExtension)"])
        }

        return try await runScan(
            videoFiles: [videoURL],
            sourceDescription: videoURL.lastPathComponent,
            method: method,
            minSegmentLengthSec: minSegmentLengthSec,
            similarityThreshold: similarityThreshold,
            debugLogger: debugLogger,
            progressHandler: progressHandler
        )
    }

    private func runScan(
        videoFiles: [URL],
        sourceDescription: String,
        method: RCDDetectionMethod,
        minSegmentLengthSec: Double,
        similarityThreshold: Double,
        debugLogger: ((String) -> Void)?,
        progressHandler: @escaping (String, Int) -> Void
    ) async throws -> [String: [RCDMatch]] {
        // Deliberately NOT wrapped in its own Task.detached: that would start a fully
        // independent, unrelated task, and Task.detached does not inherit cancellation from
        // anything — a caller cancelling the task it got back from calling this function would
        // never actually reach the Task.checkCancellation() calls below. Every current caller
        // already invokes this from its own Task.detached(priority: .userInitiated), so
        // this function just runs directly in that context and correctly observes its cancellation.
        do {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            func log(_ msg: String) {
                let logLine = "[\(timestamp)] \(msg)"
                LoggerService.shared.info("[RCD Engine] \(msg)")
                debugLogger?(logLine)
            }

            log("Initiating RCD scan with method '\(method.rawValue)' on \(sourceDescription)")
            log("FFmpeg binary path: \(FFmpegService.shared.ffmpegPath ?? "NOT FOUND!")")
            log("FFprobe binary path: \(FFmpegService.shared.ffprobePath ?? "NOT FOUND!")")

            // Fail loudly instead of silently returning zero matches. Without these binaries every
            // audio extraction returns empty and the scan "succeeds" while detecting nothing —
            // which reads to the user as a broken feature rather than a missing dependency.
            guard FFmpegService.shared.ffmpegPath != nil, FFmpegService.shared.ffprobePath != nil else {
                let err = "ffmpeg/ffprobe not found. RCD scanning needs them to decode audio. Install with 'brew install ffmpeg', or bundle them in Segmenter.app/Contents/Resources/bin/."
                log("ERROR: \(err)")
                throw NSError(domain: "RCDEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: err])
            }
            log("Acceleration: Accelerate vDSP SIMD (CPU) + VideoToolbox HW decode for visual pass")
            log("Analysing \(videoFiles.count) video file(s); minimum segment length \(Int(minSegmentLengthSec))s")

            progressHandler("Preparing audio feature vectors...", 5)
            try Task.checkCancellation()

            // Repeated-content detection is meaningless with a single file: there is nothing to
            // cross-correlate against. Correlating an episode with itself scores 1.0 at every
            // offset, which makes boundary expansion run to the edges and report the whole
            // search region as one segment. Route single-file scans to structural analysis instead.
            if videoFiles.count == 1, let video = videoFiles.first {
                let epName = video.lastPathComponent
                log("Single file — cross-episode correlation not applicable. Using structural audio analysis.")
                let structural = try await detectStructuralSegments(
                    videoURL: video,
                    minSegmentLengthSec: minSegmentLengthSec,
                    log: log,
                    progressHandler: progressHandler
                )

                let refined = await refineMatchesWithVisionAI(
                    matches: structural,
                    videoURL: video,
                    method: method,
                    log: log
                )
                let filtered = refined.filter { $0.endSec - $0.startSec >= minSegmentLengthSec }

                log("Structural scan complete — located \(filtered.count) segment(s) in \(epName)")
                progressHandler("RCD Fingerprinting Complete!", 100)
                return [epName: filtered]
            }

            // 2. Extract the intro region (from the start) and credits region (to the end) per
            // episode. Region sizes are scaled from each episode's own duration — see
            // `searchRegionSeconds`. Keep RCDFeatureCacheService.featureVersion in sync when
            // changing any of this, or stale features from the old windows get reused.

            // Extraction is I/O-bound (each episode spawns an independent FFmpeg subprocess)
            // and was previously fully serialized for no reason — run a bounded pool of them
            // concurrently instead. Feature vectors are cached to disk (RCDFeatureCacheService)
            // keyed by file size + modification date, so re-scanning a season (different method
            // or threshold, or one new episode dropped into the folder) skips decode+FFT
            // entirely for files that haven't changed since the last scan.
            let maxConcurrentExtractions = max(1, min(ProcessInfo.processInfo.activeProcessorCount, videoFiles.count))
            log("Extracting audio features across \(videoFiles.count) episode(s) with up to \(maxConcurrentExtractions) concurrent workers...")

            let episodeAudio: [String: RCDEpisodeAudio] = try await withThrowingTaskGroup(of: (String, RCDEpisodeAudio).self) { group in
                var pendingFiles = videoFiles.makeIterator()

                func scheduleNext() {
                    guard let video = pendingFiles.next() else { return }
                    group.addTask {
                        try Task.checkCancellation()
                        let epName = video.lastPathComponent

                        if let cached = await RCDFeatureCacheService.shared.features(for: video) {
                            log("  [\(epName)] Reusing cached audio features (skipped decode + FFT)")
                            return (epName, RCDEpisodeAudio(
                                introFeatures: cached.introFeatures,
                                creditsFeatures: cached.creditsFeatures,
                                durationSec: cached.durationSec,
                                introRegionSec: cached.introRegionSec,
                                creditsRegionSec: cached.creditsRegionSec
                            ))
                        }

                        var epDurationSec = 3000 // fallback 50 min
                        if let meta = await FFmpegService.shared.inspectMedia(url: video) {
                            epDurationSec = max(meta.durationMs / 1000, 600)
                        }

                        let regions = searchRegionSeconds(forDurationSec: epDurationSec)

                        // Intro region, measured from the start of the episode
                        let introFeatures = await self.extractFeatureVector(
                            url: video, startSec: 0, durationSec: regions.intro
                        )

                        // Credits region, measured back from the end of the episode
                        let creditsStartSec = max(0, epDurationSec - regions.credits)
                        let creditsFeatures = await self.extractFeatureVector(
                            url: video, startSec: creditsStartSec, durationSec: regions.credits
                        )

                        await RCDFeatureCacheService.shared.store(
                            RCDFeatureCacheService.FeatureSet(
                                introFeatures: introFeatures,
                                creditsFeatures: creditsFeatures,
                                durationSec: epDurationSec,
                                introRegionSec: regions.intro,
                                creditsRegionSec: regions.credits
                            ),
                            for: video
                        )

                        return (epName, RCDEpisodeAudio(
                            introFeatures: introFeatures,
                            creditsFeatures: creditsFeatures,
                            durationSec: epDurationSec,
                            introRegionSec: regions.intro,
                            creditsRegionSec: regions.credits
                        ))
                    }
                }

                for _ in 0..<maxConcurrentExtractions { scheduleNext() }

                var results: [String: RCDEpisodeAudio] = [:]
                var completed = 0
                for try await (epName, audio) in group {
                    results[epName] = audio
                    completed += 1
                    let pct = 5 + Int((Double(completed) / Double(videoFiles.count)) * 40.0)
                    progressHandler("Extracted audio for \(epName) (\(completed)/\(videoFiles.count))...", pct)
                    log("  [\(completed)/\(videoFiles.count)] \(epName): intro \(audio.introFeatures.count / 12) frames, credits \(audio.creditsFeatures.count / 12) frames")
                    scheduleNext()
                }
                return results
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
            // Candidate template lengths in frames (~7.8 fps): 10s, 15s, 20s, 30s, 45s, 60s, 90s,
            // 120s, 150s. The list used to stop at 90s, which silently capped every result: a show
            // whose intro is longer simply cannot be described by any candidate, so the search
            // returned its best 90s slice and boundary expansion tacked on a few more seconds.
            // Measured on FROM S03 (true intro 115-122s), that produced ~100s intros no matter what
            // the expansion threshold was set to, because the answer was never in the search space.
            let introWindowLengths = [78, 117, 156, 234, 352, 469, 703, 938, 1172]
            let creditsWindowLengths = [78, 117, 156, 234, 352, 469, 703, 938, 1172]

            var bestIntroTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?
            var bestCreditsTemplate: (startBucket: Int, wLen: Int, score: Float, baseName: String)?

            // Helper function to find best template across sample episodes with adaptive thresholding.
            // Each (base episode, window length) pair is an independent unit of search — this was
            // previously a fully serial nested loop (the single most expensive phase of a scan).
            // It now fans out across a TaskGroup so all CPU cores share the O(episodes ×
            // windowLengths × frames²) search. The math is unchanged: same comparisons, same
            // max-by-weightedScore reduction the serial version used — just computed concurrently.
            func findBestTemplate(isIntro: Bool) async throws -> (startBucket: Int, wLen: Int, score: Float, baseName: String)? {
                let windowLengths = isIntro ? introWindowLengths : creditsWindowLengths
                let thresholdsToTry: [Float] = [targetThresh, 0.65, 0.50, 0.40]

                if sampleEpisodes.count == 1, let baseEp = sampleEpisodes.first {
                    let baseName = baseEp.lastPathComponent
                    if let baseAudio = episodeAudio[baseName] {
                        let baseBuckets = isIntro ? baseAudio.introFeatures : baseAudio.creditsFeatures
                        let totalFrames = baseBuckets.count / C
                        let defaultWLen = min(totalFrames - 1, 352) // ~45s
                        let startIdx = isIntro ? min(totalFrames - defaultWLen, 120) : max(0, totalFrames - defaultWLen - 60)
                        if totalFrames > defaultWLen {
                            log("Single episode mode: extracted \(isIntro ? "INTRO" : "CREDITS") structural interval candidate.")
                            return (startBucket: startIdx, wLen: defaultWLen, score: 0.85, baseName: baseName)
                        }
                    }
                }

                for minThresh in thresholdsToTry {
                    try Task.checkCancellation()

                    let candidates: [RCDTemplateCandidate] = try await withThrowingTaskGroup(of: RCDTemplateCandidate?.self) { group in
                        for baseEp in sampleEpisodes {
                            let baseName = baseEp.lastPathComponent
                            guard let baseAudio = episodeAudio[baseName] else { continue }
                            let baseBuckets = isIntro ? baseAudio.introFeatures : baseAudio.creditsFeatures

                            for wLen in windowLengths {
                                group.addTask {
                                    try Task.checkCancellation()
                                    return self.searchBestTemplateWindow(
                                        baseBuckets: baseBuckets,
                                        baseName: baseName,
                                        wLen: wLen,
                                        C: C,
                                        isIntro: isIntro,
                                        sampleEpisodes: sampleEpisodes,
                                        episodeAudio: episodeAudio,
                                        minThresh: minThresh,
                                        secPerFrame: secPerFrame
                                    )
                                }
                            }
                        }

                        var found: [RCDTemplateCandidate] = []
                        for try await candidate in group {
                            if let candidate { found.append(candidate) }
                        }
                        return found
                    }

                    guard !candidates.isEmpty else { continue }

                    // Audio alone can't tell closing credits from a "next time on…" preview: both
                    // recur across episodes and both score well. For credits, resolve it visually.
                    let best: RCDTemplateCandidate
                    if isIntro {
                        best = candidates.max(by: { $0.weightedScore < $1.weightedScore })!
                    } else {
                        best = await self.pickCreditsCandidate(
                            candidates: candidates,
                            episodeAudio: episodeAudio,
                            sampleEpisodes: sampleEpisodes,
                            secPerFrame: secPerFrame,
                            log: log
                        )
                    }

                    if minThresh < targetThresh {
                        log(String(format: "Adaptive threshold fallback used: %.0f%% for \(isIntro ? "INTRO" : "CREDITS")", minThresh * 100))
                    }
                    return (startBucket: best.startBucket, wLen: best.wLen, score: best.score, baseName: best.baseName)
                }

                return nil
            }

            // --- INTRO template detection ---
            bestIntroTemplate = try await findBestTemplate(isIntro: true)

            progressHandler("Cross-correlating credits fingerprints...", 60)
            log("Phase 3: Cross-correlating credits chroma vectors across episodes...")

            // --- CREDITS template detection ---
            bestCreditsTemplate = try await findBestTemplate(isIntro: false)

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

            // Some formats have no recurring audio under their credits at all, so no amount of
            // audio matching can find them (see detectCreditsVisually). Scan one representative
            // episode visually; a credit block sits at a stable offset from the end, so the
            // interval found there transfers to the rest of the season. One episode keeps this to
            // a few dozen frame extractions instead of a few hundred.
            progressHandler("Checking for on-screen credits...", 70)
            var visualCreditsOffset: (secondsBeforeEndStart: Double, secondsBeforeEndEnd: Double)?
            if method != .chromaprintFFT,
               let probe = videoFiles.sorted(by: { (episodeAudio[$0.lastPathComponent]?.durationSec ?? 0) < (episodeAudio[$1.lastPathComponent]?.durationSec ?? 0) })[videoFiles.count / 2] as URL?,
               let probeAudio = episodeAudio[probe.lastPathComponent] {
                log("Scanning \(probe.lastPathComponent) for an on-screen credit block...")
                visualCreditsOffset = await detectCreditsVisually(
                    videoURL: probe,
                    durationSec: probeAudio.durationSec,
                    log: log
                )
            }

            progressHandler("Locating per-episode segment positions...", 75)
            try Task.checkCancellation()

            // 4. For each episode, locate exact intro/credits position by sliding the template &
            // expanding boundaries, then refine with Vision AI. Independent per episode — run a
            // bounded pool concurrently. Capped lower than audio extraction since Vision OCR +
            // ffmpeg thumbnail extraction contend more heavily over decode hardware than the
            // pure vDSP localization math does.
            let introTemplate = bestIntroTemplate
            let creditsTemplate = bestCreditsTemplate
            let visualCredits = visualCreditsOffset
            let maxConcurrentLocalization = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount, videoFiles.count))

            let results: [String: [RCDMatch]] = try await withThrowingTaskGroup(of: (String, [RCDMatch]).self) { group in
                var pendingFiles = videoFiles.makeIterator()

                func scheduleNext() {
                    guard let video = pendingFiles.next() else { return }
                    group.addTask {
                        try Task.checkCancellation()
                        let epName = video.lastPathComponent

                        guard let epAudio = episodeAudio[epName] else {
                            return (epName, [])
                        }

                        var matches: [RCDMatch] = []

                        // --- Per-episode INTRO localization (in first-5-min chroma) ---
                        if let t = introTemplate {
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
                            baseStart: t.startBucket,
                            epBuckets: epBuckets,
                            epStart: bestStart,
                            seedWLen: t.wLen,
                            C: C,
                            isBaseEpisode: epName == t.baseName,
                            templateScore: t.score
                        )

                        let startSec = Double(expStart) * secPerFrame
                        let endSec = Double(expEnd) * secPerFrame
                        let conf = bestSim > 0 ? bestSim : t.score
                        matches.append(RCDMatch(type: .intro, startSec: startSec, endSec: endSec, confidence: conf))
                        log(String(format: "  [%@] INTRO: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                }

                        // --- Per-episode CREDITS ---
                        // A visually-confirmed credit block wins over the audio match: dense
                        // on-screen text is specific to credits, whereas recurring audio in the
                        // last minutes is equally consistent with a preview or a confessional bed.
                        if let visual = visualCredits {
                            let startSec = max(0, Double(epAudio.durationSec) - visual.secondsBeforeEndStart)
                            let endSec = max(startSec, Double(epAudio.durationSec) - visual.secondsBeforeEndEnd)
                            matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: 0.90))
                            log(String(format: "  [%@] CREDITS (on-screen text): %02d:%02d - %02d:%02d", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60))
                        } else if let t = creditsTemplate {
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
                            baseStart: t.startBucket,
                            epBuckets: epBuckets,
                            epStart: bestStart,
                            seedWLen: t.wLen,
                            C: C,
                            isBaseEpisode: epName == t.baseName,
                            templateScore: t.score
                        )

                        // Convert offset within last-5-min segment to absolute time
                        let creditsStartOffset = max(0, epAudio.durationSec - epAudio.creditsRegionSec)
                        let startSec = Double(creditsStartOffset) + Double(expStart) * secPerFrame
                        let endSec = Double(creditsStartOffset) + Double(expEnd) * secPerFrame
                        let conf = bestSim > 0 ? bestSim : t.score
                        matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: conf))
                                log(String(format: "  [%@] CREDITS: %02d:%02d - %02d:%02d (%.1f%%)", epName, Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, conf * 100))
                        }

                        let refinedMatches = await self.refineMatchesWithVisionAI(
                            matches: matches,
                            videoURL: video,
                            method: method,
                            log: log
                        )

                        // Honour the Min Segment Length setting: drop anything shorter than the
                        // user asked for. Applied after refinement because the Vision pass can
                        // move a credits start boundary (black-frame snapping) and change duration.
                        let finalMatches = refinedMatches.filter { match in
                            let durationSec = match.endSec - match.startSec
                            if durationSec < minSegmentLengthSec {
                                log(String(format: "  [%@] Discarded %@ — %.1fs is shorter than the %ds minimum segment length", epName, match.type.displayName, durationSec, Int(minSegmentLengthSec)))
                                return false
                            }
                            return true
                        }

                        return (epName, finalMatches)
                    }
                }

                for _ in 0..<maxConcurrentLocalization { scheduleNext() }

                var collected: [String: [RCDMatch]] = [:]
                var completed = 0
                for try await (epName, matches) in group {
                    collected[epName] = matches
                    completed += 1
                    let pct = 75 + Int((Double(completed) / Double(videoFiles.count)) * 20.0)
                    progressHandler("Located segments for \(epName) (\(completed)/\(videoFiles.count))...", pct)
                    scheduleNext()
                }
                return collected
            }

            let totalMatches = results.values.reduce(0) { $0 + $1.count }
            log("Scan complete — located \(totalMatches) segment(s) across \(videoFiles.count) file(s)!")
            progressHandler("RCD Fingerprinting Complete!", 100)
            return results
        }
    }


    // MARK: - Standalone Single-File Structural Detection

    /// Detects intro/credits in a single file with no sibling episodes to compare against.
    /// Cross-correlation can't be used here, so this instead looks for sustained music in the
    /// regions where themes and credits live, using the SoundAnalysis music/speech classifier
    /// that AudioExtractorService already runs on the Neural Engine.
    ///
    /// This is inherently less precise than a season scan — it finds "a long stretch of music
    /// near the start/end", which is usually but not always the intro/credits.
    private func detectStructuralSegments(
        videoURL: URL,
        minSegmentLengthSec: Double,
        log: (String) -> Void,
        progressHandler: @escaping (String, Int) -> Void
    ) async throws -> [RCDMatch] {
        progressHandler("Inspecting media duration...", 10)

        var durationMs = 0
        if let meta = await FFmpegService.shared.inspectMedia(url: videoURL) {
            durationMs = meta.durationMs
        }
        guard durationMs > 0 else {
            log("ERROR: could not determine media duration; structural analysis aborted.")
            return []
        }

        try Task.checkCancellation()
        progressHandler("Classifying music vs. speech (Neural Engine)...", 25)

        let (_, musicLikelihood) = await AudioExtractorService.shared.extractAudioWaveform(
            videoURL: videoURL,
            durationMs: durationMs,
            progressHandler: { pct in
                progressHandler("Classifying music vs. speech (Neural Engine)...", 25 + (pct * 45 / 100))
            }
        )

        try Task.checkCancellation()
        guard musicLikelihood.count > 4 else {
            log("ERROR: audio classification returned no usable data.")
            return []
        }

        let durationSec = Double(durationMs) / 1000.0
        let secPerBucket = durationSec / Double(musicLikelihood.count)
        log(String(format: "Structural analysis over %.0fs (%d buckets, %.2fs each)", durationSec, musicLikelihood.count, secPerBucket))

        progressHandler("Locating structural boundaries...", 80)

        // Intros live near the start, credits near the end. Bound the search to those regions
        // so a musical scene in the middle of the episode can't be mistaken for either.
        let introSearchEnd = min(musicLikelihood.count, Int((min(600.0, durationSec * 0.30)) / secPerBucket))
        let creditsSearchStart = max(0, musicLikelihood.count - Int((min(600.0, durationSec * 0.25)) / secPerBucket))

        var matches: [RCDMatch] = []

        if let introRun = longestMusicRun(in: musicLikelihood, range: 0..<introSearchEnd, minLengthSec: minSegmentLengthSec, secPerBucket: secPerBucket) {
            let startSec = Double(introRun.range.lowerBound) * secPerBucket
            let endSec = Double(introRun.range.upperBound) * secPerBucket
            matches.append(RCDMatch(type: .intro, startSec: startSec, endSec: endSec, confidence: introRun.confidence))
            log(String(format: "  INTRO (structural): %02d:%02d - %02d:%02d (%.1f%% music confidence)", Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, introRun.confidence * 100))
        } else {
            log("  No sustained intro music found in the opening region.")
        }

        if creditsSearchStart < musicLikelihood.count,
           let creditsRun = longestMusicRun(in: musicLikelihood, range: creditsSearchStart..<musicLikelihood.count, minLengthSec: minSegmentLengthSec, secPerBucket: secPerBucket) {
            let startSec = Double(creditsRun.range.lowerBound) * secPerBucket
            let endSec = Double(creditsRun.range.upperBound) * secPerBucket
            matches.append(RCDMatch(type: .credits, startSec: startSec, endSec: endSec, confidence: creditsRun.confidence))
            log(String(format: "  CREDITS (structural): %02d:%02d - %02d:%02d (%.1f%% music confidence)", Int(startSec)/60, Int(startSec)%60, Int(endSec)/60, Int(endSec)%60, creditsRun.confidence * 100))
        } else {
            log("  No sustained credits music found in the closing region.")
        }

        return matches
    }

    /// Finds the longest contiguous run of high music likelihood within `range`, trying
    /// progressively lower thresholds (mirroring the adaptive thresholding the season scan uses)
    /// until a run meets the caller's minimum segment length.
    private func longestMusicRun(
        in buckets: [Float],
        range: Range<Int>,
        minLengthSec: Double,
        secPerBucket: Double
    ) -> (range: Range<Int>, confidence: Float)? {
        guard !range.isEmpty, range.upperBound <= buckets.count else { return nil }
        let minBuckets = max(1, Int(minLengthSec / secPerBucket))

        for threshold in [Float(0.70), 0.60, 0.50, 0.42] {
            var bestRange: Range<Int>?
            var runStart: Int?

            // Close over one trailing bucket so a run ending exactly at the boundary is considered.
            for idx in range.lowerBound...range.upperBound {
                let isMusic = idx < range.upperBound && buckets[idx] >= threshold
                if isMusic {
                    if runStart == nil { runStart = idx }
                } else if let start = runStart {
                    let candidate = start..<idx
                    if candidate.count >= minBuckets && candidate.count > (bestRange?.count ?? 0) {
                        bestRange = candidate
                    }
                    runStart = nil
                }
            }

            if let best = bestRange {
                let mean = buckets[best].reduce(0, +) / Float(best.count)
                return (range: best, confidence: min(1.0, mean))
            }
        }

        return nil
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

    /// Expands the matched window outward in ~1s steps for as long as the base template and the
    /// episode keep agreeing, then applies a small safety pad so skipping doesn't clip the first
    /// or last musical note.
    ///
    /// `baseStart` and `epStart` are tracked separately and stepped together on purpose. They are
    /// generally *different* offsets — the whole job of localization is to find where the template
    /// sits in this particular episode — so comparing both arrays at the same index compares
    /// unrelated audio, scores near-random similarity, and (at a permissive threshold) expands
    /// until it hits the array bounds. For the base episode itself the two slices would be
    /// literally identical, scoring 1.0 forever and swallowing the entire search region.
    private func expandBoundaries(
        baseBuckets: [Float],
        baseStart: Int,
        epBuckets: [Float],
        epStart: Int,
        seedWLen: Int,
        C: Int,
        isBaseEpisode: Bool,
        templateScore: Float
    ) -> (startFrame: Int, endFrame: Int) {
        let totalEpFrames = epBuckets.count / C
        let totalBaseFrames = baseBuckets.count / C

        // The template was cut from this very episode, so every comparison would be the slice
        // against itself and score a perfect 1.0 — expansion would just run to the cap in both
        // directions and report a segment noticeably longer than the same segment in every other
        // episode. The template bounds are already the answer here.
        if isBaseEpisode {
            return (max(0, epStart - 4), min(totalEpFrames, epStart + seedWLen + 4))
        }

        let win = 8 // ~1s comparison window

        // Chroma cosine similarity required to keep growing. 0.32 sits at the noise level, where
        // unrelated audio passes and expansion runs to the array bounds. Tried at 0.42 and scaled
        // to the template's own score; neither changed results measurably, because expansion was
        // never the binding constraint — the template length list was (see introWindowLengths).
        let simThreshold: Float = 0.50

        // Growth cap, proportional to the segment being expanded. A fixed 15s is simultaneously
        // too generous for a 15s title card and too mean for a 2-minute title sequence.
        let maxExpandFrames = max(60, seedWLen / 2)

        /// Correlates the base template and the episode at their own respective offsets.
        func similarity(baseAt: Int, epAt: Int) -> Float? {
            guard baseAt >= 0, epAt >= 0,
                  baseAt + win <= totalBaseFrames,
                  epAt + win <= totalEpFrames else { return nil }

            let sliceA = Array(baseBuckets[(baseAt * C)..<((baseAt + win) * C)])
            let sliceB = Array(epBuckets[(epAt * C)..<((epAt + win) * C)])
            let normA = self.vectorNorm(sliceA)
            let normB = self.vectorNorm(sliceB)
            guard normA > 0.03, normB > 0.03 else { return nil }

            var dot: Float = 0
            vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(win * C))
            return dot / (normA * normB)
        }

        var expandedBack = 0
        while expandedBack + win <= maxExpandFrames {
            let step = expandedBack + win
            guard let sim = similarity(baseAt: baseStart - step, epAt: epStart - step),
                  sim >= simThreshold else { break }
            expandedBack = step
        }

        var expandedForward = 0
        while expandedForward + win <= maxExpandFrames {
            guard let sim = similarity(baseAt: baseStart + seedWLen + expandedForward,
                                       epAt: epStart + seedWLen + expandedForward),
                  sim >= simThreshold else { break }
            expandedForward += win
        }

        // Apply fine-tuned 4-frame (~0.5s) boundary safety padding
        let paddedStart = max(0, epStart - expandedBack - 4)
        let paddedEnd = min(totalEpFrames, epStart + seedWLen + expandedForward + 4)

        return (paddedStart, paddedEnd)
    }

    /// Compute L2 norm of a feature vector using vDSP
    private func vectorNorm(_ vector: [Float]) -> Float {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        return sqrt(sumSq)
    }

    /// Searches a single (base episode, window length) combination for the best-scoring
    /// recurring template start position against the other sample episodes. This is exactly
    /// the inner two loops `findBestTemplate` used to run serially for every combination —
    /// extracted so `findBestTemplate` can dispatch one of these per CPU core via TaskGroup
    /// instead of visiting every combination one at a time.
    private func searchBestTemplateWindow(
        baseBuckets: [Float],
        baseName: String,
        wLen: Int,
        C: Int,
        isIntro: Bool,
        sampleEpisodes: [URL],
        episodeAudio: [String: RCDEpisodeAudio],
        minThresh: Float,
        secPerFrame: Double
    ) -> RCDTemplateCandidate? {
        let totalFrames = baseBuckets.count / C
        guard totalFrames > wLen else { return nil }

        var best: RCDTemplateCandidate?

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

                // NB: position within the credits region is deliberately NOT weighted here.
                // Preferring later candidates was tried and measured worse: it fixed 3 of 7
                // Party Shore episodes, left 3 on the preview and moved 1 further away, while
                // dropping confidence across the board. Credits-vs-preview is disambiguated
                // visually instead — see pickCreditsCandidate.
                let weightedScore = avgScore * durationWeight

                if best == nil || weightedScore > best!.weightedScore {
                    best = RCDTemplateCandidate(startBucket: startIdx, wLen: wLen, score: avgScore, baseName: baseName, weightedScore: weightedScore)
                }
            }
        }

        return best
    }


    // MARK: - Visual Credits Detection

    /// Counts Vision text rectangles in a single frame.
    ///
    /// Full 1080p, not a downscale: credits are not always full-screen. Party Shore Slovensko runs
    /// its crawl in a narrow side panel beside the preview, which at 960x540 leaves each name about
    /// 8 pixels tall — legible to a human looking at the source, invisible to the text detector,
    /// which reported 4 rectangles on a frame carrying 20 names.
    private func textRectangleCount(url: URL, timeSec: Int) async -> Int {
        guard let jpegData = await FFmpegService.shared.extractThumbnailData(url: url, timeMs: timeSec * 1000, size: "1920x1080"),
              let nsImage = NSImage(data: jpegData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return request.results?.count ?? 0
    }

    /// Finds the closing credits by looking for sustained on-screen text in the tail of an episode,
    /// independent of audio.
    ///
    /// Cross-episode audio matching cannot find these at all in some formats. Party Shore Slovensko
    /// runs its credit list in a side panel *next to* a "next time on…" preview, so the audio under
    /// the credits is different every week — there is no recurring sound to fingerprint, and the
    /// audio search instead locks onto a confessional music bed minutes earlier. A dense block of
    /// text on screen, however, is exactly what closing credits are.
    ///
    /// Returns the credits interval as an offset measured back from the end of the episode, so it
    /// can be applied to episodes of differing lengths.
    private func detectCreditsVisually(
        videoURL: URL,
        durationSec: Int,
        log: (String) -> Void
    ) async -> (secondsBeforeEndStart: Double, secondsBeforeEndEnd: Double)? {
        let tailSec = min(420, max(120, Int(Double(durationSec) * 0.22)))
        let scanStart = max(0, durationSec - tailSec)
        let step = 8

        var samples: [(sec: Int, rects: Int)] = []
        for t in stride(from: scanStart, to: durationSec - 2, by: step) {
            if Task.isCancelled { return nil }
            samples.append((t, await textRectangleCount(url: videoURL, timeSec: t)))
        }
        guard samples.count >= 4 else { return nil }

        // Threshold relative to this episode's own baseline: burned-in logos and name captions give
        // every frame a couple of rectangles, so a fixed cut-off would either miss credits on a
        // clean-looking show or fire on ordinary footage of a caption-heavy one.
        let counts = samples.map { $0.rects }.sorted()
        let median = counts[counts.count / 2]
        let peak = counts.last ?? 0
        let threshold = max(5, median * 3)

        guard peak >= threshold else {
            log(String(format: "  [Credits/Vision] No dense text block in the last %ds (peak %d rects, median %d) — leaving the audio match in place", tailSec, peak, median))
            return nil
        }

        // Longest contiguous run at or above the threshold.
        var bestRun: (start: Int, end: Int)?
        var runStart: Int?
        for (idx, sample) in samples.enumerated() {
            if sample.rects >= threshold {
                if runStart == nil { runStart = idx }
            } else if let s = runStart {
                if bestRun == nil || (idx - s) > (bestRun!.end - bestRun!.start) { bestRun = (s, idx) }
                runStart = nil
            }
        }
        if let s = runStart, bestRun == nil || (samples.count - s) > (bestRun!.end - bestRun!.start) {
            bestRun = (s, samples.count)
        }
        guard let run = bestRun else { return nil }

        // Sampling every `step` seconds only brackets the block — it began somewhere between the
        // previous sample and the first hit, so widen by one step rather than reporting the sampled
        // bounds as if they were exact.
        let startSec = max(0, Double(samples[run.start].sec - step))

        // Closing credits run to the end of the file. Every ground-truth entry for both validation
        // shows records credits as open-ended (TheIntroDB stores end_ms: null), and the densest
        // stretch of text is only the middle of the crawl — text thins out as names scroll off, so
        // the sampled run consistently under-reports the end. Reporting the run's own end produced
        // a 21s segment where the real credits were several minutes long. Anything after them
        // (a post-credits stinger) is the cost of matching the convention the app submits against.
        let endSec = Double(durationSec)

        log(String(format: "  [Credits/Vision] Dense text from %02d:%02d, credits run to end of file %02d:%02d (threshold %d rects, peak %d, median %d)",
                   Int(startSec) / 60, Int(startSec) % 60, Int(endSec) / 60, Int(endSec) % 60, threshold, peak, median))

        return (secondsBeforeEndStart: Double(durationSec) - startSec,
                secondsBeforeEndEnd: Double(durationSec) - endSec)
    }

    // MARK: - Credits vs. Preview Disambiguation

    /// Chooses between competing credits candidates using Apple Vision OCR.
    ///
    /// Closing credits and a "next time on…" preview are both recurring content sitting in the last
    /// few minutes of every episode, so chroma cross-correlation scores them about equally and will
    /// happily report the preview as the credits (observed on Party Shore Slovensko). Weighting by
    /// position was tried and measured worse. What actually separates them is on screen: credits are
    /// a dense crawl of names, a preview is ordinary footage with almost no text.
    ///
    /// Only the top few distinct candidates are inspected, and only in their own base episode, so
    /// this costs a handful of thumbnail extractions per scan rather than per episode.
    private func pickCreditsCandidate(
        candidates: [RCDTemplateCandidate],
        episodeAudio: [String: RCDEpisodeAudio],
        sampleEpisodes: [URL],
        secPerFrame: Double,
        log: (String) -> Void
    ) async -> RCDTemplateCandidate {
        let ranked = candidates.sorted { $0.weightedScore > $1.weightedScore }
        let fallback = ranked[0]

        // Collect up to 3 candidates that describe genuinely different moments. Two candidates from
        // the same base episode overlapping in time are the same finding at different window
        // lengths, and inspecting both would waste extractions without adding information.
        var distinct: [RCDTemplateCandidate] = []
        for candidate in ranked {
            let overlaps = distinct.contains { chosen in
                chosen.baseName == candidate.baseName
                    && candidate.startBucket < chosen.startBucket + chosen.wLen
                    && chosen.startBucket < candidate.startBucket + candidate.wLen
            }
            if !overlaps { distinct.append(candidate) }
            if distinct.count == 3 { break }
        }

        guard distinct.count > 1 else { return fallback }

        var bestDensity: Float = -1
        var bestByDensity: RCDTemplateCandidate?

        for candidate in distinct {
            guard let baseAudio = episodeAudio[candidate.baseName],
                  let baseURL = sampleEpisodes.first(where: { $0.lastPathComponent == candidate.baseName }) else { continue }

            let regionStartSec = max(0, baseAudio.durationSec - baseAudio.creditsRegionSec)
            let startSec = Double(regionStartSec) + Double(candidate.startBucket) * secPerFrame
            let endSec = Double(regionStartSec) + Double(candidate.startBucket + candidate.wLen) * secPerFrame

            let (textDensity, _) = await analyzeVisualCreditsWithVisionAI(
                url: baseURL,
                candidateStartSec: startSec,
                candidateEndSec: endSec
            )

            log(String(format: "  [Credits candidate] %02d:%02d-%02d:%02d in %@ — audio %.1f%%, text density %.1f",
                       Int(startSec) / 60, Int(startSec) % 60, Int(endSec) / 60, Int(endSec) % 60,
                       candidate.baseName, candidate.score * 100, textDensity))

            if textDensity > bestDensity {
                bestDensity = textDensity
                bestByDensity = candidate
            }
        }

        // Require actual text on screen before overriding the audio ranking. Below this a scene
        // simply has no captions to measure, and the density figures are noise — a show whose
        // credits are a static logo rather than a crawl lands here and keeps the audio winner.
        let meaningfulTextDensity: Float = 2.0
        guard let winner = bestByDensity, bestDensity >= meaningfulTextDensity else {
            log(String(format: "  [Credits] No candidate showed meaningful on-screen text (best density %.1f) — keeping strongest audio match", max(0, bestDensity)))
            return fallback
        }

        if winner.startBucket != fallback.startBucket || winner.baseName != fallback.baseName {
            log(String(format: "  [Credits] Vision OCR overrode the audio ranking (text density %.1f) — the stronger audio match had less on-screen text, which is how a preview gets mistaken for credits", bestDensity))
        }
        return winner
    }

    // MARK: - Apple Vision AI Framework Integration

    /// Uses Apple's Vision framework (VNDetectTextRectanglesRequest) & 5-frame luminance analysis
    /// to detect credit text blocks and black frame transitions in video keyframes.
    private func analyzeVisualCreditsWithVisionAI(
        url: URL,
        candidateStartSec: Double,
        candidateEndSec: Double
    ) async -> (textDensity: Float, blackFrameSec: Double?) {
        let sampleTimesSec = [
            max(0, Int(candidateStartSec) - 1),
            Int(candidateStartSec),
            Int(candidateStartSec + 3),
            Int((candidateStartSec + candidateEndSec) / 2.0),
            Int(max(candidateStartSec, candidateEndSec - 2.0))
        ]

        var totalTextRects = 0
        var blackFrameSec: Double? = nil

        for timeSec in sampleTimesSec {
            // 960x540, not the filmstrip's 160x90: Vision's text detector needs readable glyph
            // heights, and a credit crawl at thumbnail size registers as no text at all.
            guard let jpegData = await FFmpegService.shared.extractThumbnailData(url: url, timeMs: timeSec * 1000, size: "960x540"),
                  let nsImage = NSImage(data: jpegData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            // 1. Text Rectangle Detection via Apple Vision AI OCR
            let textRequest = VNDetectTextRectanglesRequest()
            textRequest.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([textRequest])

            if let results = textRequest.results {
                totalTextRects += results.count
            }

            // 2. Fine-Tuned Black Frame Luminance & Contrast Check
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
                    if avgLuminance < 30.0 && blackFrameSec == nil { // Average brightness threshold (< 30/255)
                        blackFrameSec = Double(timeSec)
                    }
                }
            }
        }

        let textDensity = Float(totalTextRects) / Float(max(1, sampleTimesSec.count))
        return (textDensity: textDensity, blackFrameSec: blackFrameSec)
    }

    /// Refines RCDMatch results using Apple Vision AI framework text recognition & visual analysis
    private func refineMatchesWithVisionAI(
        matches: [RCDMatch],
        videoURL: URL,
        method: RCDDetectionMethod,
        log: (String) -> Void
    ) async -> [RCDMatch] {
        switch method {
        case .chromaprintFFT:
            log("  [Method: Chromaprint 12-Bin Pitch Chromagram] Using pure 12-bin pitch chromagram cross-correlation (no visual pass).")
            return matches

        // Single-episode mode derives its boundaries from within the one file during template
        // selection, then shares the same visual refinement pass as the default method so
        // credits still get black-frame snapping.
        case .appleHWAccelerated, .multimodalFusionAI, .singleEpisodeAI:
            log("  [Method: \(method.rawValue)] Running Apple Vision AI OCR text & luminance frame inspection...")
            var refined: [RCDMatch] = []

            for match in matches {
                if match.type == .credits {
                    let (textDensity, blackFrameSec) = await analyzeVisualCreditsWithVisionAI(
                        url: videoURL,
                        candidateStartSec: match.startSec,
                        candidateEndSec: match.endSec
                    )

                    var boostedConf = match.confidence
                    var tunedStartSec = match.startSec

                    // Snap credit start timestamp to black frame transition if found within 3s
                    if let bfSec = blackFrameSec, abs(bfSec - match.startSec) <= 4.0 {
                        tunedStartSec = bfSec
                        log(String(format: "  [Vision AI Fine-Tuning] Snapped credits start to visual black frame at %02d:%02d", Int(bfSec)/60, Int(bfSec)%60))
                    }

                    if method == .multimodalFusionAI {
                        // 60% Audio + 40% Vision AI score fusion
                        let visionScore = min(1.0, (textDensity / 8.0) + (blackFrameSec != nil ? 0.35 : 0.0))
                        boostedConf = (0.60 * match.confidence) + (0.40 * visionScore)
                        log(String(format: "  [Multimodal AI Fusion] Fused 60%% Audio (%.1f%%) + 40%% Vision AI (%.1f%%) -> Final: %.1f%%", match.confidence * 100, visionScore * 100, boostedConf * 100))
                    } else {
                        if textDensity > 2.5 {
                            boostedConf = min(1.0, boostedConf + 0.15)
                            log(String(format: "  [Vision AI Fine-Tuning] Detected scrolling credit text blocks (density: %.1f). Boosted confidence to %.1f%%", textDensity, boostedConf * 100))
                        }
                        if blackFrameSec != nil {
                            boostedConf = min(1.0, boostedConf + 0.10)
                            log(String(format: "  [Vision AI Fine-Tuning] Black frame transition verified. Boosted confidence to %.1f%%", boostedConf * 100))
                        }
                    }

                    refined.append(RCDMatch(
                        type: match.type,
                        startSec: tunedStartSec,
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


