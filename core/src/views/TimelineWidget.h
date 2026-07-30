#pragma once

#include <QHash>
#include <QVector>
#include <QWidget>

#include "models/Models.h"

namespace segmenter {

/// Multi-track timeline: an audio density track plus one lane per segment type,
/// with the same 1.0x-50.0x interactive zoom the macOS build gained.
///
/// Segment ranges can be dragged whole or by either edge; the widget reports
/// edits and lets the window own the drafts, so undo stays in one place.
class TimelineWidget : public QWidget {
    Q_OBJECT

public:
    explicit TimelineWidget(QWidget *parent = nullptr);

    void setDurationMs(qint64 durationMs);
    qint64 durationMs() const { return m_durationMs; }

    void setPlayheadMs(qint64 milliseconds);
    qint64 playheadMs() const { return m_playheadMs; }

    void setDensityTrack(const TimelineDensityTrack &track);
    void setDrafts(const QHash<int, SegmentDraft> &draftsBySegmentType);

    void setZoom(double zoom);
    double zoom() const { return m_zoom; }

    /// Scrolls so the playhead sits in the middle of the visible span — the
    /// "Scope" action in the zoom toolbar.
    void centerOnPlayhead();

    static constexpr double kMinZoom = 1.0;
    static constexpr double kMaxZoom = 50.0;

signals:
    void seekRequested(qint64 milliseconds);
    void zoomChanged(double zoom);
    void draftEdited(SegmentType type, const SegmentDraft &draft);
    /// Raised when a drag begins and ends, so the window can coalesce the whole
    /// drag into a single undo step rather than one per mouse-move.
    void draftDragStarted();
    void draftDragFinished();

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;
    bool event(QEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;

private:
    enum class DragMode {
        None,
        Playhead,
        SegmentStart,
        SegmentEnd,
        SegmentWhole,
    };

    static constexpr int kLabelColumnWidth = 70;
    static constexpr int kRulerHeight = 18;
    static constexpr int kAudioTrackHeight = 42;
    static constexpr int kSegmentTrackHeight = 42;
    static constexpr int kEdgeGrabPx = 5;

    int trackTop(int trackIndex) const;
    QRect laneRect(int trackIndex) const;
    QRect contentRect() const;

    qint64 xToMs(int x) const;
    double msToX(qint64 milliseconds) const;

    /// Visible span in milliseconds at the current zoom.
    qint64 visibleSpanMs() const;
    void clampScroll();

    /// Chooses a ruler tick interval that keeps labels legible at the current
    /// zoom — 5 minutes when fully out, down to 250 ms when fully in.
    qint64 tickIntervalMs() const;

    void paintRuler(QPainter &painter);
    void paintAudioTrack(QPainter &painter);
    void paintSegmentTracks(QPainter &painter);
    void paintPlayhead(QPainter &painter);

    qint64 m_durationMs = 0;
    qint64 m_playheadMs = 0;

    TimelineDensityTrack m_density;
    QHash<int, SegmentDraft> m_drafts;

    double m_zoom = 1.0;
    qint64 m_scrollMs = 0;

    DragMode m_dragMode = DragMode::None;
    SegmentType m_dragSegment = SegmentType::Intro;
    qint64 m_dragAnchorMs = 0;
    SegmentDraft m_dragOriginal;
};

} // namespace segmenter
