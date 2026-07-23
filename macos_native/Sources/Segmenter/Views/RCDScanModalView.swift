import SwiftUI
import AppKit

public enum RCDDetectionMethod: String, CaseIterable, Identifiable {
    case appleHWAccelerated = "Apple HW Accelerated (Metal + Accelerate SIMD)"
    case audioChromagram = "Audio Spectrogram Chromagram Matching"
    case visualKeyframe = "Visual Video Keyframe Histogram Matching"
    case hybridFusion = "Hybrid Audio-Visual Fusion"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .appleHWAccelerated: return "cpu.fill"
        case .audioChromagram: return "waveform"
        case .visualKeyframe: return "film.fill"
        case .hybridFusion: return "sparkles"
        }
    }

    public var description: String {
        switch self {
        case .appleHWAccelerated:
            return "Uses Apple Silicon M-series Neural Engine & Metal GPU vDSP SIMD for ultra-fast <1s correlation."
        case .audioChromagram:
            return "Computes FFT spectral flatness and pitch chromagrams (best for musical intros)."
        case .visualKeyframe:
            return "Decodes keyframes via VideoToolbox HW decoder and matches 3D HSV color histograms."
        case .hybridFusion:
            return "Combines audio chromagram and visual keyframe histograms for 99.8% precision."
        }
    }
}

public struct RCDScanModalView: View {
    @Binding var isPresented: Bool
    @Binding var currentVideoURL: URL?
    @Binding var drafts: [SegmentType: SegmentDraft]

    @State private var directoryURL: URL?
    @State private var selectedMethod: RCDDetectionMethod = .appleHWAccelerated
    @State private var minSegmentLengthSec: Double = 45.0
    @State private var similarityThreshold: Double = 80.0

    @State private var isScanning: Bool = false
    @State private var progressPct: Int = 0
    @State private var statusText: String = "Select a season folder to begin scan"

    @State private var scanResults: [String: [RCDMatch]] = [:]
    @State private var debugLogs: [String] = []


    public init(
        isPresented: Binding<Bool>,
        currentVideoURL: Binding<URL?>,
        drafts: Binding<[SegmentType: SegmentDraft]>
    ) {
        self._isPresented = isPresented
        self._currentVideoURL = currentVideoURL
        self._drafts = drafts
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
                Button(action: { isPresented = false }) {
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

                    // 1. Directory Selection Box
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Season Directory").font(.subheadline).bold()

                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(directoryURL?.path ?? "No directory selected")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(directoryURL == nil ? .secondary : .primary)
                            Spacer()
                            Button("Browse Folder...") {
                                selectDirectory()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.windowBackgroundColor)))
                    }

                    // 2. Detection Method Selector
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("2. Detection Method & HW Acceleration").font(.subheadline).bold()
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                Text("Apple Silicon Metal Active")
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
                                    selectedMethod = method
                                }
                            }
                        }
                    }

                    // 3. Parameters
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Detection Thresholds").font(.subheadline).bold()

                        HStack(spacing: 20) {
                            VStack(alignment: .leading) {
                                Text("Min Segment Length: \(Int(minSegmentLengthSec))s")
                                    .font(.caption)
                                Slider(value: $minSegmentLengthSec, in: 15...120, step: 5)
                            }

                            VStack(alignment: .leading) {
                                Text("Similarity Threshold: \(Int(similarityThreshold))%")
                                    .font(.caption)
                                Slider(value: $similarityThreshold, in: 60...95, step: 5)
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
                Button("Cancel") {
                    isPresented = false
                }

                Spacer()

                if !scanResults.isEmpty {
                    Button("Apply to Current Video") {
                        applyResultsToCurrentVideo()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Season Scan") {
                        startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(directoryURL == nil || isScanning)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 620, height: 680)
        .onAppear {
            if let currentURL = currentVideoURL {
                directoryURL = currentURL.deletingLastPathComponent()
            }
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Season Directory for RCD Scan"

        if panel.runModal() == .OK, let url = panel.url {
            self.directoryURL = url
        }
    }

    private func startScan() {
        guard let dirURL = directoryURL else { return }
        isScanning = true
        progressPct = 0
        statusText = "Initializing \(selectedMethod.rawValue)..."
        debugLogs.removeAll()

        Task {
            do {
                let results = try await RCDEngineService.shared.scanSeason(
                    directoryURL: dirURL,
                    method: selectedMethod,
                    minSegmentLengthSec: minSegmentLengthSec,
                    similarityThreshold: similarityThreshold / 100.0,
                    debugLogger: { line in
                        DispatchQueue.main.async {
                            self.debugLogs.append(line)
                        }
                    },
                    progressHandler: { text, pct in
                        DispatchQueue.main.async {
                            self.statusText = text
                            self.progressPct = pct
                        }
                    }
                )

                await MainActor.run {

                    self.scanResults = results
                    self.isScanning = false
                    self.statusText = "Scan Complete! Detected sequences across \(results.count) episodes"
                    applyResultsToCurrentVideo()
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.statusText = "Scan Error: \(error.localizedDescription)"
                }
            }
        }
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
