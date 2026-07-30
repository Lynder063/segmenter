import SwiftUI
import AppKit

public struct TimelineView: View {
    @Binding public var currentPositionMs: Int
    @Binding public var durationMs: Int
    @Binding public var densityTrack: TimelineDensityTrack
    @Binding public var drafts: [SegmentType: SegmentDraft]

    public var onSeek: ((Int) -> Void)?
    public var onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)?

    @State private var zoomScale: Double = 1.0 // 1.0x (full view) to 50.0x (high precision)
    @State private var scrollOffsetMs: Double = 0.0

    public init(
        currentPositionMs: Binding<Int>,
        durationMs: Binding<Int>,
        densityTrack: Binding<TimelineDensityTrack>,
        drafts: Binding<[SegmentType: SegmentDraft]>,
        onSeek: ((Int) -> Void)? = nil,
        onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)? = nil
    ) {
        self._currentPositionMs = currentPositionMs
        self._durationMs = durationMs
        self._densityTrack = densityTrack
        self._drafts = drafts
        self.onSeek = onSeek
        self.onDraftsChanged = onDraftsChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Zoom & Navigation Toolbar
            HStack(spacing: 12) {
                Text("Timeline")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)

                Spacer()

                // Zoom Level Display
                Text(String(format: "Zoom: %.1fx", zoomScale))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)


                // Zoom Out Button (-)
                Button(action: { zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom Out (1.0x)")

                // Zoom Slider (1.0x - 50.0x)
                Slider(
                    value: Binding(
                        get: { zoomScale },
                        set: { newZoom in
                            updateZoom(newZoom: newZoom)
                        }
                    ),
                    in: 1.0...50.0
                )
                .frame(width: 140)

                // Zoom In Button (+)
                Button(action: { zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom In (50.0x)")

                // Reset Zoom Button
                Button(action: { resetZoom() }) {
                    Text("1x")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .help("Reset Zoom to 1.0x")

                // Center on Playhead Button
                Button(action: { centerOnPlayhead() }) {
                    Image(systemName: "scope")
                }
                .buttonStyle(.plain)
                .help("Center View on Playhead")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))

            Divider()

            // Canvas Timeline Viewport
            TimelineCanvasRepresentable(
                currentPositionMs: $currentPositionMs,
                durationMs: $durationMs,
                densityTrack: $densityTrack,
                drafts: $drafts,
                zoomScale: $zoomScale,
                scrollOffsetMs: $scrollOffsetMs,
                onSeek: onSeek,
                onDraftsChanged: onDraftsChanged
            )
        }
    }

    private func updateZoom(newZoom: Double) {
        zoomScale = max(1.0, min(50.0, newZoom))


        if durationMs > 0 {
            let visibleDuration = Double(durationMs) / zoomScale
            let playhead = Double(currentPositionMs)
            let newScroll = playhead - (visibleDuration / 2.0)
            let maxScroll = Double(durationMs) - visibleDuration
            scrollOffsetMs = max(0, min(maxScroll, newScroll))
        }
    }

    private func zoomIn() {
        updateZoom(newZoom: zoomScale * 1.5)
    }

    private func zoomOut() {
        updateZoom(newZoom: zoomScale / 1.5)
    }

    private func resetZoom() {
        zoomScale = 1.0
        scrollOffsetMs = 0.0
    }

    private func centerOnPlayhead() {
        if durationMs > 0 {
            let visibleDuration = Double(durationMs) / zoomScale
            let playhead = Double(currentPositionMs)
            let newScroll = playhead - (visibleDuration / 2.0)
            let maxScroll = Double(durationMs) - visibleDuration
            scrollOffsetMs = max(0, min(maxScroll, newScroll))
        }
    }
}

// MARK: - NSViewRepresentable Canvas Wrapper
public struct TimelineCanvasRepresentable: NSViewRepresentable {
    @Binding public var currentPositionMs: Int
    @Binding public var durationMs: Int
    @Binding public var densityTrack: TimelineDensityTrack
    @Binding public var drafts: [SegmentType: SegmentDraft]
    @Binding public var zoomScale: Double
    @Binding public var scrollOffsetMs: Double

    public var onSeek: ((Int) -> Void)?
    public var onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)?

    public func makeNSView(context: Context) -> TimelineCanvasNSView {
        let canvas = TimelineCanvasNSView()
        canvas.onSeek = onSeek
        canvas.onDraftsChanged = onDraftsChanged
        canvas.onZoomChanged = { newZoom, newOffset in
            DispatchQueue.main.async {
                self.zoomScale = newZoom
                self.scrollOffsetMs = newOffset
            }
        }
        return canvas
    }

    public func updateNSView(_ nsView: TimelineCanvasNSView, context: Context) {
        nsView.updateState(
            currentPositionMs: currentPositionMs,
            durationMs: durationMs,
            densityTrack: densityTrack,
            drafts: drafts,
            zoomScale: zoomScale,
            scrollOffsetMs: scrollOffsetMs
        )
    }
}

// MARK: - AppKit Drawing & Interaction Canvas
public class TimelineCanvasNSView: NSView {
    public var onSeek: ((Int) -> Void)?
    public var onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)?
    public var onZoomChanged: ((Double, Double) -> Void)?

    private var currentPositionMs: Int = 0
    private var durationMs: Int = 0
    private var densityTrack = TimelineDensityTrack()
    private var drafts: [SegmentType: SegmentDraft] = [:]
    private var zoomScale: Double = 1.0
    private var scrollOffsetMs: Double = 0.0

    override public var isFlipped: Bool { true }

    public func updateState(
        currentPositionMs: Int,
        durationMs: Int,
        densityTrack: TimelineDensityTrack,
        drafts: [SegmentType: SegmentDraft],
        zoomScale: Double,
        scrollOffsetMs: Double
    ) {
        self.currentPositionMs = currentPositionMs
        self.durationMs = durationMs
        self.densityTrack = densityTrack
        self.drafts = drafts
        self.zoomScale = zoomScale
        self.scrollOffsetMs = scrollOffsetMs
        self.needsDisplay = true
    }

    // MARK: - Trackpad Pinch & Scroll Panning
    override public func magnify(with event: NSEvent) {
        let factor = 1.0 + Double(event.magnification)
        let newZoom = max(1.0, min(50.0, zoomScale * factor))

        if durationMs > 0 {
            let visibleDuration = Double(durationMs) / newZoom
            let playhead = Double(currentPositionMs)
            let newScroll = playhead - (visibleDuration / 2.0)
            let maxScroll = Double(durationMs) - visibleDuration
            let clampedScroll = max(0, min(maxScroll, newScroll))

            self.zoomScale = newZoom
            self.scrollOffsetMs = clampedScroll
            onZoomChanged?(newZoom, clampedScroll)
            self.needsDisplay = true
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            // Option + Scroll = Zoom In/Out
            let delta = Double(event.deltaY)
            let factor = delta > 0 ? 1.15 : 0.85
            let newZoom = max(1.0, min(50.0, zoomScale * factor))

            if durationMs > 0 {
                let visibleDuration = Double(durationMs) / newZoom
                let playhead = Double(currentPositionMs)
                let newScroll = playhead - (visibleDuration / 2.0)
                let maxScroll = Double(durationMs) - visibleDuration
                let clampedScroll = max(0, min(maxScroll, newScroll))

                self.zoomScale = newZoom
                self.scrollOffsetMs = clampedScroll
                onZoomChanged?(newZoom, clampedScroll)
                self.needsDisplay = true
            }
        } else {
            // Horizontal scroll = Pan timeline left/right
            let visibleDuration = Double(durationMs) / zoomScale
            let deltaMs = Double(event.deltaX != 0 ? -event.deltaX : event.deltaY) * (visibleDuration / 40.0)
            let maxScroll = max(0, Double(durationMs) - visibleDuration)
            let newScroll = max(0, min(maxScroll, scrollOffsetMs + deltaMs))

            self.scrollOffsetMs = newScroll
            onZoomChanged?(zoomScale, newScroll)
            self.needsDisplay = true
        }
    }

    // MARK: - Drawing
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let bgPath = NSBezierPath(rect: bounds)
        NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0).setFill()
        bgPath.fill()

        let sidebarWidth: CGFloat = 80
        let timelineWidth = bounds.width - sidebarWidth
        guard durationMs > 0 && timelineWidth > 0 else { return }

        let visibleDurationMs = Double(durationMs) / zoomScale

        func msToX(_ ms: Double) -> CGFloat {
            let frac = (ms - scrollOffsetMs) / visibleDurationMs
            return sidebarWidth + CGFloat(frac) * timelineWidth
        }

        func xToMs(_ x: CGFloat) -> Double {
            let frac = Double((x - sidebarWidth) / timelineWidth)
            return scrollOffsetMs + frac * visibleDurationMs
        }

        let rulerHeight: CGFloat = 18
        let trackHeight: CGFloat = 24
        let tracks: [(label: String, type: SegmentType?)] = [
            ("Audio", nil),
            ("Intro", .intro),
            ("Recap", .recap),
            ("Credits", .credits),
            ("Preview", .preview)
        ]

        // 1. Draw Time Ruler Header
        let rulerRect = CGRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        let rulerPath = NSBezierPath(rect: rulerRect)
        NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0).setFill()
        rulerPath.fill()

        // Time Ruler Ticks & Labels
        let tickIntervalMs: Double
        if zoomScale > 20.0 {
            tickIntervalMs = 1000 // 1-second ticks at high zoom
        } else if zoomScale > 8.0 {
            tickIntervalMs = 5000 // 5-second ticks
        } else if zoomScale > 3.0 {
            tickIntervalMs = 30000 // 30-second ticks
        } else {
            tickIntervalMs = 300000 // 5-minute ticks
        }

        let startTickMs = floor(scrollOffsetMs / tickIntervalMs) * tickIntervalMs
        let endTickMs = scrollOffsetMs + visibleDurationMs
        var tMs = startTickMs

        while tMs <= endTickMs {
            let x = msToX(tMs)
            if x >= sidebarWidth && x <= bounds.width {
                ctx.setStrokeColor(NSColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 0.6).cgColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: x, y: rulerHeight - 5))
                ctx.addLine(to: CGPoint(x: x, y: rulerHeight))
                ctx.strokePath()

                let sec = Int(tMs) / 1000
                let m = sec / 60
                let s = sec % 60
                let timeStr: String
                if tickIntervalMs < 5000 {
                    let msRem = Int(tMs) % 1000
                    timeStr = String(format: "%02d:%02d.%03d", m, s, msRem)
                } else {
                    timeStr = String(format: "%02d:%02d", m, s)
                }

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor(red: 0.6, green: 0.6, blue: 0.65, alpha: 1.0)
                ]
                let str = NSString(string: timeStr)
                str.draw(at: NSPoint(x: x + 2, y: 2), withAttributes: attrs)
            }
            tMs += tickIntervalMs
        }

        // 2. Draw Track Rows
        for (i, track) in tracks.enumerated() {
            let y = rulerHeight + CGFloat(i) * trackHeight

            // Label background
            let labelRect = CGRect(x: 0, y: y, width: sidebarWidth, height: trackHeight)
            let labelPath = NSBezierPath(rect: labelRect)
            NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
            labelPath.fill()

            // Label text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(red: 0.75, green: 0.75, blue: 0.80, alpha: 1.0)
            ]
            let str = NSString(string: track.label)
            str.draw(at: NSPoint(x: 8, y: y + 4), withAttributes: attrs)

            // Horizontal row separator
            ctx.setStrokeColor(NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: 0, y: y + trackHeight))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y + trackHeight))
            ctx.strokePath()

            // Draw Audio Waveform Track
            if i == 0 {
                let trackY = y + trackHeight / 2.0
                ctx.setStrokeColor(NSColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 0.6).cgColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: sidebarWidth, y: trackY))
                ctx.addLine(to: CGPoint(x: bounds.width, y: trackY))
                ctx.strokePath()

                if !densityTrack.buckets.isEmpty {
                    let totalBuckets = densityTrack.buckets.count
                    let msPerBucket = Double(durationMs) / Double(totalBuckets)

                    let startBucket = max(0, Int(scrollOffsetMs / msPerBucket))
                    let endBucket = min(totalBuckets - 1, Int((scrollOffsetMs + visibleDurationMs) / msPerBucket))

                    if startBucket <= endBucket {
                        for b in startBucket...endBucket {
                            let bStartMs = Double(b) * msPerBucket
                            let barX = msToX(bStartMs)
                            let barW = max(1.5, (msToX(bStartMs + msPerBucket) - barX))

                            if barX >= sidebarWidth && barX <= bounds.width {
                                let amp = CGFloat(densityTrack.buckets[b])
                                let barH = max(2.0, amp * (trackHeight - 4))
                                let barY = y + (trackHeight - barH) / 2.0

                                var barColor = NSColor(red: 0.0, green: 0.78, blue: 0.65, alpha: 0.85) // Mint
                                if let music = densityTrack.musicLikelihoodBuckets, b < music.count {
                                    if music[b] > 0.4 {
                                        barColor = NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.85) // Orange music
                                    }
                                }

                                let barRect = CGRect(x: barX, y: barY, width: max(1.0, barW - 0.5), height: barH)
                                ctx.setFillColor(barColor.cgColor)
                                ctx.fill(barRect)
                            }
                        }
                    }
                }
            }

            // Draw Segment Draft Bars
            if let type = track.type, let draft = drafts[type], let startMs = draft.startMs {
                let startX = msToX(Double(startMs))
                let endMs = draft.endMs ?? durationMs
                let endX = msToX(Double(endMs))
                let segW = max(4.0, endX - startX)

                if endX >= sidebarWidth && startX <= bounds.width {
                    let clampedStartX = max(sidebarWidth, startX)
                    let clampedW = min(bounds.width - clampedStartX, segW)

                    let segRect = CGRect(x: clampedStartX, y: y + 2, width: clampedW, height: trackHeight - 4)
                    let segPath = NSBezierPath(roundedRect: segRect, xRadius: 4, yRadius: 4)

                    type.nsColor.withAlphaComponent(0.45).setFill()
                    segPath.fill()

                    type.nsColor.setStroke()
                    segPath.lineWidth = 1.5
                    segPath.stroke()
                }
            }
        }

        // 3. Draw Red Playhead Marker
        let playheadX = msToX(Double(currentPositionMs))
        if playheadX >= sidebarWidth && playheadX <= bounds.width {
            ctx.setStrokeColor(NSColor.red.cgColor)
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: playheadX, y: 0))
            ctx.addLine(to: CGPoint(x: playheadX, y: bounds.height))
            ctx.strokePath()

            // Draw playhead top handle
            let handlePath = NSBezierPath()
            handlePath.move(to: NSPoint(x: playheadX - 5, y: 0))
            handlePath.line(to: NSPoint(x: playheadX + 5, y: 0))
            handlePath.line(to: NSPoint(x: playheadX, y: rulerHeight - 4))
            handlePath.close()
            NSColor.red.setFill()
            handlePath.fill()
        }
    }

    // MARK: - Mouse Click to Seek
    override public func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let sidebarWidth: CGFloat = 80
        let timelineWidth = bounds.width - sidebarWidth
        guard durationMs > 0 && timelineWidth > 0 && pt.x >= sidebarWidth else { return }

        let visibleDurationMs = Double(durationMs) / zoomScale
        let frac = Double((pt.x - sidebarWidth) / timelineWidth)
        let clickMs = Int(scrollOffsetMs + frac * visibleDurationMs)

        onSeek?(max(0, min(durationMs, clickMs)))
    }
}
