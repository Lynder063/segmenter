import SwiftUI
import AppKit

/// Detection methods. Every entry here must map to a genuinely distinct code path in
/// `RCDEngineService.refineMatchesWithVisionAI` — do not add an option whose behaviour
/// duplicates another one, and do not describe hardware or models the engine doesn't use.
public enum RCDDetectionMethod: String, CaseIterable, Identifiable {
    case appleHWAccelerated = "Apple HW Accelerated (vDSP SIMD + Vision AI)"
    case chromaprintFFT = "Chromaprint 12-Bin Pitch Chromagram (AcoustID)"
    case multimodalFusionAI = "Multimodal Fusion (Audio Chroma + Vision AI)"
    case singleEpisodeAI = "Single Episode (Standalone — No Season Folder)"

    public var id: String { rawValue }

    /// Single-episode mode analyses one file on its own; the others need sibling episodes
    /// to cross-correlate against, so they require a season directory.
    public var requiresSeasonFolder: Bool {
        self != .singleEpisodeAI
    }

    public var iconName: String {
        switch self {
        case .appleHWAccelerated: return "cpu.fill"
        case .chromaprintFFT: return "waveform"
        case .multimodalFusionAI: return "sparkles"
        case .singleEpisodeAI: return "play.tv.fill"
        }
    }

    public var description: String {
        switch self {
        case .appleHWAccelerated:
            return "Accelerate vDSP 12-bin chromagram across episodes + Vision OCR text density and black-frame snapping. Recommended default."
        case .chromaprintFFT:
            return "Pure 12-bin pitch chromagram cross-correlation (AcoustID / Chromaprint style), no visual pass. Fastest; ideal for distinct theme music."
        case .multimodalFusionAI:
            return "Same audio + visual signals as the default, but scored as a weighted fusion (60% chromagram + 40% Vision) instead of additive confidence boosts."
        case .singleEpisodeAI:
            return "Analyses a single video file on its own, without needing sibling episodes to compare against. Less precise — uses structural heuristics rather than cross-episode matching."
        }
    }
}



public struct RCDScanModalView: View {
    @Binding var isPresented: Bool
    @Binding var currentVideoURL: URL?
    @Binding var drafts: [SegmentType: SegmentDraft]

    @State private var directoryURL: URL?
    @State private var singleFileURL: URL?
    @State private var selectedMethod: RCDDetectionMethod = .appleHWAccelerated
    // 15s, not 45s: plenty of shows have short segments — reality formats routinely run ~20s
    // credits and ~30s intros — and a 45s floor silently discarded every correctly-detected
    // segment for those, which reads as "detection is broken" rather than "threshold too high".
    @State private var minSegmentLengthSec: Double = 15.0
    @State private var similarityThreshold: Double = 80.0

    @State private var isScanning: Bool = false
    @State private var progressPct: Int = 0
    @State private var statusText: String = "Select a season folder to begin scan"

    @State private var scanResults: [String: [RCDMatch]] = [:]
    @State private var debugLogs: [String] = []
    @State private var scanTask: Task<Void, Never>?


    public init(
        isPresented: Binding<Bool>,
        currentVideoURL: Binding<URL?>,
        drafts: Binding<[SegmentType: SegmentDraft]>
    ) {
        self._isPresented = isPresented
        self._currentVideoURL = currentVideoURL
        self._drafts = drafts
    }

    /// Cross-episode methods need sibling episodes to correlate against; single-episode
    /// mode works on one standalone file.
    private var needsSeasonFolder: Bool {
        selectedMethod.requiresSeasonFolder
    }

    private var selectedSourcePath: String? {
        needsSeasonFolder ? directoryURL?.path : singleFileURL?.path
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Season Automatic Scan (RCD)")
                        .font(.headline)
                    Text("Repeated Content Detection across Season Episodes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { closeModal() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // 1. Source Selection Box — a season folder for cross-episode methods,
                    // or a single file for standalone single-episode mode.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(needsSeasonFolder ? "1. Season Directory" : "1. Video File").font(.subheadline).bold()

                        HStack {
                            Image(systemName: needsSeasonFolder ? "folder.fill" : "film.fill")
                                .foregroundColor(.accentColor)
                            Text(selectedSourcePath ?? (needsSeasonFolder ? "No directory selected" : "No video file selected"))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(selectedSourcePath == nil ? .secondary : .primary)
                            Spacer()
                            Button(needsSeasonFolder ? "Browse Folder..." : "Browse File...") {
                                if needsSeasonFolder {
                                    selectDirectory()
                                } else {
                                    selectSingleFile()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isScanning)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.windowBackgroundColor)))
                    }

                    // 2. Detection Method Selector
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("2. Detection Method").font(.subheadline).bold()
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                Text("Accelerate vDSP SIMD")
                            }
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                        }

                        VStack(spacing: 8) {
                            ForEach(RCDDetectionMethod.allCases) { method in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: method.iconName)
                                        .font(.title3)
                                        .foregroundColor(selectedMethod == method ? .accentColor : .secondary)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(method.rawValue)
                                            .font(.body)
                                            .fontWeight(selectedMethod == method ? .bold : .regular)

                                        Text(method.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedMethod == method {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedMethod == method ? Color.accentColor.opacity(0.12) : Color(NSColor.windowBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedMethod == method ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if !isScanning {
                                        selectedMethod = method
                                    }
                                }
                            }
                        }
                        .disabled(isScanning)
                    }

                    // 3. Parameters
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Detection Thresholds").font(.subheadline).bold()

                        HStack(spacing: 20) {
                            VStack(alignment: .leading) {
                                Text("Min Segment Length: \(Int(minSegmentLengthSec))s")
                                    .font(.caption)
                                Slider(value: $minSegmentLengthSec, in: 5...120, step: 5)
                                    .disabled(isScanning)
                            }

                            VStack(alignment: .leading) {
                                Text("Similarity Threshold: \(Int(similarityThreshold))%")
                                    .font(.caption)
                                Slider(value: $similarityThreshold, in: 60...95, step: 5)
                                    .disabled(isScanning)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.windowBackgroundColor)))
                    }


                    // Progress Section
                    if isScanning || progressPct > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(statusText)
                                    .font(.caption)
                                    .bold()
                                Spacer()
                                Text("\(progressPct)%")
                                    .font(.caption)
                                    .bold()
                            }
                            ProgressView(value: Double(progressPct), total: 100.0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    }

                    // Debug Console Box
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "terminal.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Real-Time HW Diagnostic Log")
                                .font(.caption)
                                .bold()
                            Spacer()
                            if !debugLogs.isEmpty {
                                Button("Clear Logs") {
                                    debugLogs.removeAll()
                                }
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            }
                        }

                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    if debugLogs.isEmpty {
                                        Text("Waiting for scan to start...")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.gray)
                                    } else {
                                        ForEach(Array(debugLogs.enumerated()), id: \.offset) { idx, line in
                                            Text(line)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(line.contains("Match Found") ? .green : (line.contains("Error") ? .red : .secondary))
                                                .id(idx)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(height: 120)
                            .background(Color.black.opacity(0.90))
                            .cornerRadius(6)
                            .onChange(of: debugLogs.count) { _ in
                                if let lastIdx = debugLogs.indices.last {
                                    withAnimation {
                                        proxy.scrollTo(lastIdx, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }

                    // Results Table

                    if !scanResults.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Detected Season Sequences (\(scanResults.count) Episodes)").font(.subheadline).bold()

                            VStack(spacing: 4) {
                                ForEach(scanResults.keys.sorted(), id: \.self) { epName in
                                    HStack {
                                        Text(epName)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .frame(maxWidth: 180, alignment: .leading)
                                        Spacer()
                                        if let matches = scanResults[epName] {
                                            ForEach(matches, id: \.type) { match in
                                                HStack(spacing: 3) {
                                                    Text(match.type.displayName)
                                                        .font(.caption2)
                                                        .bold()
                                                    Text("\(formatSec(match.startSec)) - \(formatSec(match.endSec))")
                                                        .font(.system(.caption2, design: .monospaced))
                                                }
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.2))
                                                .cornerRadius(4)
                                            }
                                        }
                                    }
                                    .padding(6)
                                    .background(Color(NSColor.windowBackgroundColor))
                                    .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer Buttons
            HStack {
                Button(isScanning ? "Cancel Scan" : "Cancel") {
                    closeModal()
                }

                Spacer()

                if !scanResults.isEmpty {
                    Button("Apply to Current Video") {
                        applyResultsToCurrentVideo()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(needsSeasonFolder ? "Start Season Scan" : "Scan This Episode") {
                        startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning)

                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 620, height: 680)
        .onAppear {
            print("🔴 [GUI TERMINAL LOG] RCDScanModalView appeared! currentVideoURL: \(currentVideoURL?.path ?? "NIL")")
            if let currentURL = currentVideoURL {
                directoryURL = currentURL.deletingLastPathComponent()
                singleFileURL = currentURL
                print("🔴 [GUI TERMINAL LOG] Pre-filled directoryURL: \(directoryURL?.path ?? "NIL")")
            } else {
                print("🔴 [GUI TERMINAL LOG] directoryURL is initially NIL!")
            }
        }
    }

    private func selectDirectory() {
        print("🔴 [GUI TERMINAL LOG] Triggering NSOpenPanel for season directory selection...")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Season Directory for RCD Scan"

        if panel.runModal() == .OK, let url = panel.url {
            print("🔴 [GUI TERMINAL LOG] NSOpenPanel OK! Selected directory: \(url.path)")
            self.directoryURL = url
        } else {
            print("🔴 [GUI TERMINAL LOG] NSOpenPanel Cancelled or Failed!")
        }
    }

    private func selectSingleFile() {
        print("🔴 [GUI TERMINAL LOG] Triggering NSOpenPanel for single video file selection...")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Select Video File for Standalone RCD Scan"

        if panel.runModal() == .OK, let url = panel.url {
            print("🔴 [GUI TERMINAL LOG] NSOpenPanel OK! Selected file: \(url.path)")
            self.singleFileURL = url
        } else {
            print("🔴 [GUI TERMINAL LOG] NSOpenPanel Cancelled or Failed!")
        }
    }

    private func startScan() {
        print("🔴 [GUI TERMINAL LOG] Start Scan button pressed! (season folder mode: \(needsSeasonFolder))")

        // Prompt for whichever source the selected method actually needs.
        if selectedSourcePath == nil {
            if needsSeasonFolder {
                selectDirectory()
            } else {
                selectSingleFile()
            }
        }

        let scanSource: URL?
        if needsSeasonFolder {
            scanSource = directoryURL
        } else {
            scanSource = singleFileURL
        }

        guard let sourceURL = scanSource else {
            let what = needsSeasonFolder ? "season directory" : "video file"
            print("🔴 [GUI TERMINAL LOG] ERROR: no \(what) selected!")
            statusText = "Error: No \(what) selected"
            debugLogs.append("[RCD Modal] Error: No \(what) selected. Please use the Browse button.")
            return
        }

        print("🔴 [GUI TERMINAL LOG] Starting RCD scan on \(sourceURL.path) using method '\(selectedMethod.rawValue)'")
        isScanning = true
        progressPct = 0
        statusText = "Initializing \(selectedMethod.rawValue)..."
        debugLogs.removeAll()

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLogs.append("[\(timeStr)] [RCD Modal] Starting scan on: \(sourceURL.path)")
        debugLogs.append("[\(timeStr)] [RCD Modal] Selected Method: \(selectedMethod.rawValue)")
        debugLogs.append("[\(timeStr)] [RCD Modal] Min Segment Length: \(Int(minSegmentLengthSec))s, Threshold: \(Int(similarityThreshold))%")

        let useSeasonFolder = needsSeasonFolder

        scanTask = Task.detached(priority: .userInitiated) {
            print("🔴 [GUI TERMINAL LOG] Task.detached background worker started for RCD scan...")
            do {
                let engine = RCDEngineService.shared
                let debugLogger: (String) -> Void = { line in
                    print("🔴 [GUI TERMINAL LOG] [ENGINE LOG]: \(line)")
                    DispatchQueue.main.async {
                        self.debugLogs.append(line)
                    }
                }
                let progress: (String, Int) -> Void = { text, pct in
                    print("🔴 [GUI TERMINAL LOG] [PROGRESS]: \(pct)% - \(text)")
                    DispatchQueue.main.async {
                        self.statusText = text
                        self.progressPct = pct
                    }
                }

                let results: [String: [RCDMatch]]
                if useSeasonFolder {
                    results = try await engine.scanSeason(
                        directoryURL: sourceURL,
                        method: selectedMethod,
                        minSegmentLengthSec: minSegmentLengthSec,
                        similarityThreshold: similarityThreshold / 100.0,
                        debugLogger: debugLogger,
                        progressHandler: progress
                    )
                } else {
                    results = try await engine.scanSingleEpisode(
                        videoURL: sourceURL,
                        method: selectedMethod,
                        minSegmentLengthSec: minSegmentLengthSec,
                        similarityThreshold: similarityThreshold / 100.0,
                        debugLogger: debugLogger,
                        progressHandler: progress
                    )
                }
                try await self.finishScan(results: results)
            } catch is CancellationError {
                print("🔴 [GUI TERMINAL LOG] Scan cancelled by user")
                await MainActor.run {
                    self.isScanning = false
                    self.statusText = "Scan cancelled"
                    self.debugLogs.append("[RCD Modal] Scan cancelled by user.")
                }
            } catch {
                let errStr = error.localizedDescription
                print("🔴 [GUI TERMINAL LOG] EXCEPTION THROWN: \(errStr)")
                await MainActor.run {
                    self.isScanning = false
                    self.statusText = "Scan Error: \(errStr)"
                    self.debugLogs.append("[RCD Modal] EXCEPTION CATCH: \(errStr)")
                }
            }
        }
    }

    private func finishScan(results: [String: [RCDMatch]]) async throws {
        print("🔴 [GUI TERMINAL LOG] RCD scan completed with \(results.count) results!")
        await RCDCacheService.shared.saveResults(results)

        await MainActor.run {
            self.scanResults = results
            self.isScanning = false
            let totalSegments = results.values.reduce(0) { $0 + $1.count }
            self.statusText = "Scan Complete! Found \(totalSegments) segment(s) across \(results.count) file(s)"
            applyResultsToCurrentVideo()
        }
    }

    /// Cancels any in-flight scan (so closing the modal doesn't leave orphaned background
    /// work running) and dismisses the modal.
    private func closeModal() {
        if isScanning {
            scanTask?.cancel()
        }
        isPresented = false
    }



    private func applyResultsToCurrentVideo() {
        guard let currentName = currentVideoURL?.lastPathComponent,
              let matches = scanResults[currentName] else { return }

        for match in matches {
            let startMs = Int(match.startSec * 1000.0)
            let endMs = Int(match.endSec * 1000.0)
            drafts[match.type] = SegmentDraft(startMs: startMs, endMs: endMs)
        }
    }

    private func formatSec(_ sec: Double) -> String {
        let totalMs = Int(sec * 1000.0)
        let m = (totalMs / 1000) / 60
        let s = (totalMs / 1000) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
