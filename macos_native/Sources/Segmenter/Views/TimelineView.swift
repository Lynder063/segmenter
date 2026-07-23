import SwiftUI
import AppKit

public struct TimelineView: NSViewRepresentable {
    @Binding public var currentPositionMs: Int
    @Binding public var durationMs: Int
    @Binding public var densityTrack: TimelineDensityTrack
    @Binding public var drafts: [SegmentType: SegmentDraft]

    public var onSeek: ((Int) -> Void)?
    public var onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)?

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

    public func makeNSView(context: Context) -> TimelineCanvasNSView {
        let canvas = TimelineCanvasNSView()
        canvas.onSeek = onSeek
        canvas.onDraftsChanged = onDraftsChanged
        return canvas
    }

    public func updateNSView(_ nsView: TimelineCanvasNSView, context: Context) {
        nsView.updateState(
            currentPositionMs: currentPositionMs,
            durationMs: durationMs,
            densityTrack: densityTrack,
            drafts: drafts
        )
    }
}

public class TimelineCanvasNSView: NSView {
    public var onSeek: ((Int) -> Void)?
    public var onDraftsChanged: (([SegmentType: SegmentDraft]) -> Void)?

    private var currentPositionMs: Int = 0
    private var durationMs: Int = 0
    private var densityTrack = TimelineDensityTrack()
    private var drafts: [SegmentType: SegmentDraft] = [:]

    private var activeDraggingSegment: SegmentType?
    private var isDraggingStartEdge = false
    private var dragStartMouseX: CGFloat = 0

    override public var isFlipped: Bool { true }

    public func updateState(
        currentPositionMs: Int,
        durationMs: Int,
        densityTrack: TimelineDensityTrack,
        drafts: [SegmentType: SegmentDraft]
    ) {
        self.currentPositionMs = currentPositionMs
        self.durationMs = durationMs
        self.densityTrack = densityTrack
        self.drafts = drafts
        self.needsDisplay = true
    }

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

        let trackHeight: CGFloat = 28
        let tracks: [(label: String, type: SegmentType?)] = [
            ("Audio", nil),
            ("Intro", .intro),
            ("Recap", .recap),
            ("Credits", .credits),
            ("Preview", .preview)
        ]

        // Draw track rows
        for (i, track) in tracks.enumerated() {
            let y = CGFloat(i) * trackHeight

            // Label background
            let labelRect = CGRect(x: 0, y: y, width: sidebarWidth, height: trackHeight)
            let labelPath = NSBezierPath(rect: labelRect)
            NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
            labelPath.fill()

            // Label text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(red: 0.7, green: 0.7, blue: 0.75, alpha: 1.0)
            ]
            let str = NSString(string: track.label)
            str.draw(at: NSPoint(x: 10, y: y + 6), withAttributes: attrs)

            // Horizontal row separator
            ctx.setStrokeColor(NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: 0, y: y + trackHeight))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y + trackHeight))
            ctx.strokePath()

            // Draw Audio Waveform
            if i == 0 && !densityTrack.buckets.isEmpty {
                let count = densityTrack.buckets.count
                let stepX = timelineWidth / CGFloat(count)
                for b in 0..<count {
                    let amp = CGFloat(densityTrack.buckets[b])
                    let barH = amp * (trackHeight - 4)
                    let barX = sidebarWidth + CGFloat(b) * stepX
                    let barY = y + (trackHeight - barH) / 2.0

                    // Color code music likelihood (orange for music, mint/blue for speech)
                    var barColor = NSColor(red: 0.0, green: 0.78, blue: 0.65, alpha: 0.85) // Mint
                    if let music = densityTrack.musicLikelihoodBuckets, b < music.count {
                        let m = CGFloat(music[b])
                        if m > 0.4 {
                            barColor = NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.85) // Orange music
                        }
                    }

                    let barRect = CGRect(x: barX, y: barY, width: max(1.0, stepX - 0.5), height: barH)
                    ctx.setFillColor(barColor.cgColor)
                    ctx.fill(barRect)
                }
            }

            // Draw Segment Draft Bars
            if let type = track.type, let draft = drafts[type], let startMs = draft.startMs {
                let startX = sidebarWidth + (CGFloat(startMs) / CGFloat(durationMs)) * timelineWidth
                let endMs = draft.endMs ?? durationMs
                let endX = sidebarWidth + (CGFloat(endMs) / CGFloat(durationMs)) * timelineWidth
                let segW = max(4.0, endX - startX)

                let segRect = CGRect(x: startX, y: y + 3, width: segW, height: trackHeight - 6)
                let segPath = NSBezierPath(roundedRect: segRect, xRadius: 4, yRadius: 4)

                type.nsColor.withAlphaComponent(0.4).setFill()
                segPath.fill()

                type.nsColor.setStroke()
                segPath.lineWidth = 1.5
                segPath.stroke()
            }
        }

        // Draw Red Playhead Marker
        let playheadX = sidebarWidth + (CGFloat(currentPositionMs) / CGFloat(durationMs)) * timelineWidth
        ctx.setStrokeColor(NSColor.red.cgColor)
        ctx.setLineWidth(2.0)
        ctx.move(to: CGPoint(x: playheadX, y: 0))
        ctx.addLine(to: CGPoint(x: playheadX, y: bounds.height))
        ctx.strokePath()
    }

    override public func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let sidebarWidth: CGFloat = 80
        let timelineWidth = bounds.width - sidebarWidth
        guard durationMs > 0 && timelineWidth > 0 && pt.x >= sidebarWidth else { return }

        let clickMs = Int(((pt.x - sidebarWidth) / timelineWidth) * CGFloat(durationMs))
        onSeek?(max(0, min(durationMs, clickMs)))
    }
}
