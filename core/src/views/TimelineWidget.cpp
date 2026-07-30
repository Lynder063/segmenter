#include "views/TimelineWidget.h"

#include <QGestureEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPinchGesture>
#include <QWheelEvent>

#include <cmath>

#include "Theme.h"

namespace segmenter {
namespace {

/// Audio, then one lane per segment type.
constexpr int kAudioTrackIndex = 0;
constexpr int kFirstSegmentTrackIndex = 1;

const QVector<qint64> kTickLadderMs = {
    250, 500, 1000, 2000, 5000, 10000, 15000, 30000,
    60000, 120000, 300000, 600000,
};

} // namespace

TimelineWidget::TimelineWidget(QWidget *parent)
    : QWidget(parent)
{
    setMouseTracking(true);
    setFocusPolicy(Qt::StrongFocus);
    // Fixed vertically: the track stack has a known height and stretching it
    // would only add empty space under the last lane.
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    setFixedHeight(kRulerHeight + kAudioTrackHeight
                   + kSegmentTrackHeight * static_cast<int>(allSegmentTypes().size()));

    // Trackpad pinch, matching the macOS magnify gesture.
    grabGesture(Qt::PinchGesture);
}

// MARK: - Geometry

QRect TimelineWidget::contentRect() const
{
    return QRect(kLabelColumnWidth, 0, std::max(1, width() - kLabelColumnWidth), height());
}

int TimelineWidget::trackTop(int trackIndex) const
{
    if (trackIndex == kAudioTrackIndex) {
        return kRulerHeight;
    }
    return kRulerHeight + kAudioTrackHeight
         + (trackIndex - kFirstSegmentTrackIndex) * kSegmentTrackHeight;
}

QRect TimelineWidget::laneRect(int trackIndex) const
{
    const int trackHeight =
        (trackIndex == kAudioTrackIndex) ? kAudioTrackHeight : kSegmentTrackHeight;
    return QRect(kLabelColumnWidth, trackTop(trackIndex),
                 std::max(1, width() - kLabelColumnWidth), trackHeight);
}

qint64 TimelineWidget::visibleSpanMs() const
{
    if (m_durationMs <= 0) {
        return 1;
    }
    return std::max<qint64>(1, static_cast<qint64>(m_durationMs / m_zoom));
}

qint64 TimelineWidget::xToMs(int x) const
{
    const QRect content = contentRect();
    if (content.width() <= 0 || m_durationMs <= 0) {
        return 0;
    }
    const double ratio = static_cast<double>(x - content.left()) / content.width();
    return std::clamp<qint64>(m_scrollMs + static_cast<qint64>(ratio * visibleSpanMs()),
                              0, m_durationMs);
}

double TimelineWidget::msToX(qint64 milliseconds) const
{
    const QRect content = contentRect();
    if (m_durationMs <= 0) {
        return content.left();
    }
    const double ratio = static_cast<double>(milliseconds - m_scrollMs)
                       / static_cast<double>(visibleSpanMs());
    return content.left() + ratio * content.width();
}

void TimelineWidget::clampScroll()
{
    const qint64 span = visibleSpanMs();
    m_scrollMs = std::clamp<qint64>(m_scrollMs, 0, std::max<qint64>(0, m_durationMs - span));
}

// MARK: - State

void TimelineWidget::setDurationMs(qint64 durationMs)
{
    m_durationMs = std::max<qint64>(0, durationMs);
    clampScroll();
    update();
}

void TimelineWidget::setPlayheadMs(qint64 milliseconds)
{
    const qint64 clamped = std::clamp<qint64>(milliseconds, 0, std::max<qint64>(0, m_durationMs));
    if (clamped == m_playheadMs) {
        return;
    }
    m_playheadMs = clamped;

    // Follow the playhead when zoomed in and it leaves the visible span; at 1x
    // everything is on screen and scrolling would be pointless.
    if (m_zoom > 1.0) {
        const qint64 span = visibleSpanMs();
        if (m_playheadMs < m_scrollMs || m_playheadMs > m_scrollMs + span) {
            m_scrollMs = m_playheadMs - span / 2;
            clampScroll();
        }
    }
    update();
}

void TimelineWidget::setDensityTrack(const TimelineDensityTrack &track)
{
    m_density = track;
    update();
}

void TimelineWidget::setDrafts(const QHash<int, SegmentDraft> &draftsBySegmentType)
{
    m_drafts = draftsBySegmentType;
    update();
}

void TimelineWidget::setZoom(double zoom)
{
    const double clamped = std::clamp(zoom, kMinZoom, kMaxZoom);
    if (std::abs(clamped - m_zoom) < 1e-6) {
        return;
    }

    // Keep the playhead where it is on screen while the scale changes, so
    // zooming does not throw away the user's place in the file.
    const qint64 anchor = m_playheadMs;
    const double anchorRatio = contentRect().width() > 0
        ? (msToX(anchor) - contentRect().left()) / contentRect().width()
        : 0.5;

    m_zoom = clamped;
    m_scrollMs = anchor - static_cast<qint64>(anchorRatio * visibleSpanMs());
    clampScroll();

    emit zoomChanged(m_zoom);
    update();
}

void TimelineWidget::centerOnPlayhead()
{
    m_scrollMs = m_playheadMs - visibleSpanMs() / 2;
    clampScroll();
    update();
}

// MARK: - Painting

qint64 TimelineWidget::tickIntervalMs() const
{
    const QRect content = contentRect();
    if (content.width() <= 0 || m_durationMs <= 0) {
        return 60000;
    }

    // Aim for a tick roughly every 90 px, then round up to the next value on
    // the ladder so labels land on human-readable times.
    const double msPerPixel = static_cast<double>(visibleSpanMs()) / content.width();
    const qint64 target = static_cast<qint64>(msPerPixel * 90.0);

    for (const qint64 candidate : kTickLadderMs) {
        if (candidate >= target) {
            return candidate;
        }
    }
    return kTickLadderMs.last();
}

void TimelineWidget::paintRuler(QPainter &painter)
{
    const QRect ruler(kLabelColumnWidth, 0, width() - kLabelColumnWidth, kRulerHeight);
    painter.fillRect(ruler, theme::color::panelBackground);

    if (m_durationMs <= 0) {
        return;
    }

    const qint64 interval = tickIntervalMs();
    const qint64 firstTick = (m_scrollMs / interval) * interval;
    const qint64 lastVisible = m_scrollMs + visibleSpanMs();

    QFont tickFont = painter.font();
    tickFont.setPointSizeF(7.0);
    painter.setFont(tickFont);

    for (qint64 t = firstTick; t <= lastVisible; t += interval) {
        const double x = msToX(t);
        if (x < ruler.left() - 40 || x > ruler.right() + 40) {
            continue;
        }

        painter.setPen(theme::color::border);
        painter.drawLine(QPointF(x, ruler.bottom() - 5), QPointF(x, ruler.bottom()));

        painter.setPen(theme::color::textMuted);
        painter.drawText(QRectF(x + 3, 1, 70, kRulerHeight - 2),
                         Qt::AlignLeft | Qt::AlignVCenter,
                         formatTimecode(static_cast<int>(t)));
    }
}

void TimelineWidget::paintAudioTrack(QPainter &painter)
{
    const QRect lane = laneRect(kAudioTrackIndex);
    painter.fillRect(lane, theme::color::trackBackground);

    if (m_density.buckets.isEmpty() || m_durationMs <= 0) {
        return;
    }

    const qint64 span = visibleSpanMs();
    const double centreY = lane.center().y() + 0.5;
    const double halfHeight = lane.height() / 2.0 - 2.0;

    // One vertical line per pixel column, taking the peak of whatever buckets
    // fall inside it. Drawing every bucket instead would over-plot at 1x, where
    // 2400 buckets share ~1400 pixels.
    for (int x = lane.left(); x <= lane.right(); ++x) {
        const qint64 timeAtX = m_scrollMs + static_cast<qint64>(
            (static_cast<double>(x - lane.left()) / lane.width()) * span);
        const qint64 timeAtNext = m_scrollMs + static_cast<qint64>(
            (static_cast<double>(x + 1 - lane.left()) / lane.width()) * span);

        const int bucketStart = static_cast<int>(
            (static_cast<double>(timeAtX) / m_durationMs) * m_density.buckets.size());
        const int bucketEnd = std::max(bucketStart + 1, static_cast<int>(
            (static_cast<double>(timeAtNext) / m_durationMs) * m_density.buckets.size()));

        float peak = 0.0f;
        float music = 0.0f;
        for (int b = bucketStart; b < bucketEnd && b < m_density.buckets.size(); ++b) {
            if (b < 0) {
                continue;
            }
            peak = std::max(peak, m_density.buckets[b]);
            if (b < m_density.musicLikelihoodBuckets.size()) {
                music = std::max(music, m_density.musicLikelihoodBuckets[b]);
            }
        }

        if (peak <= 0.0f) {
            continue;
        }

        // Music likelihood tints the waveform rather than occupying its own
        // lane: it is the same audio, and a second row would double the height
        // of the track for information the colour already carries.
        const QColor colour = music > 0.5f
            ? QColor::fromRgbF(
                  theme::color::waveform.redF() * (1.0 - music) + theme::color::waveformMusic.redF() * music,
                  theme::color::waveform.greenF() * (1.0 - music) + theme::color::waveformMusic.greenF() * music,
                  theme::color::waveform.blueF() * (1.0 - music) + theme::color::waveformMusic.blueF() * music)
            : theme::color::waveform;

        painter.setPen(colour);
        const double amplitude = peak * halfHeight;
        painter.drawLine(QPointF(x, centreY - amplitude), QPointF(x, centreY + amplitude));
    }
}

void TimelineWidget::paintSegmentTracks(QPainter &painter)
{
    const QVector<SegmentType> &types = allSegmentTypes();

    for (int i = 0; i < types.size(); ++i) {
        const SegmentType type = types.at(i);
        const QRect lane = laneRect(kFirstSegmentTrackIndex + i);

        painter.fillRect(lane, theme::color::trackBackground);
        painter.setPen(theme::color::border);
        painter.drawLine(lane.bottomLeft(), lane.bottomRight());

        const auto it = m_drafts.constFind(static_cast<int>(type));
        if (it == m_drafts.constEnd() || it->isEmpty() || m_durationMs <= 0) {
            continue;
        }

        // An open-ended credits draft still has to be visible, so a missing end
        // draws to the end of the file rather than nothing at all.
        const qint64 startMs = it->startMs.value_or(0);
        const qint64 endMs = it->endMs.value_or(m_durationMs);

        const double x1 = msToX(startMs);
        const double x2 = msToX(endMs);
        if (x2 < lane.left() || x1 > lane.right()) {
            continue;
        }

        const QRectF block(std::max<double>(x1, lane.left()), lane.top() + 4,
                           std::max(2.0, std::min<double>(x2, lane.right())
                                             - std::max<double>(x1, lane.left())),
                           lane.height() - 8);

        QColor fill = segmentTypeColor(type);
        fill.setAlpha(150);
        painter.setBrush(fill);
        painter.setPen(QPen(segmentTypeColor(type), 1.5));
        painter.drawRoundedRect(block, 3, 3);
    }
}

void TimelineWidget::paintPlayhead(QPainter &painter)
{
    if (m_durationMs <= 0) {
        return;
    }
    const double x = msToX(m_playheadMs);
    if (x < kLabelColumnWidth || x > width()) {
        return;
    }
    painter.setPen(QPen(theme::color::playhead, 1.5));
    painter.drawLine(QPointF(x, 0), QPointF(x, height()));
}

void TimelineWidget::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.fillRect(rect(), theme::color::windowBackground);

    paintRuler(painter);
    paintAudioTrack(painter);
    paintSegmentTracks(painter);

    // Track name column, drawn last so lane fills cannot bleed into it.
    QFont labelFont = painter.font();
    labelFont.setPointSizeF(7.5);
    labelFont.setBold(true);
    painter.setFont(labelFont);

    const auto drawLabel = [&](int trackIndex, const QString &text, const QColor &colour) {
        const QRect labelRect(0, trackTop(trackIndex), kLabelColumnWidth,
                              trackIndex == kAudioTrackIndex ? kAudioTrackHeight
                                                             : kSegmentTrackHeight);
        painter.fillRect(labelRect, theme::color::panelBackground);
        painter.setPen(theme::color::border);
        painter.drawLine(labelRect.bottomLeft(), labelRect.bottomRight());
        painter.setPen(colour);
        painter.drawText(labelRect.adjusted(8, 0, -4, 0), Qt::AlignLeft | Qt::AlignVCenter, text);
    };

    drawLabel(kAudioTrackIndex, tr("Audio"), theme::color::textSecondary);

    const QVector<SegmentType> &types = allSegmentTypes();
    for (int i = 0; i < types.size(); ++i) {
        drawLabel(kFirstSegmentTrackIndex + i,
                  segmentTypeDisplayName(types.at(i)),
                  theme::color::textSecondary);
    }

    painter.fillRect(QRect(0, 0, kLabelColumnWidth, kRulerHeight), theme::color::panelBackground);

    paintPlayhead(painter);
}

// MARK: - Interaction

void TimelineWidget::mousePressEvent(QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton || m_durationMs <= 0) {
        return;
    }

    const int x = static_cast<int>(event->position().x());
    const int y = static_cast<int>(event->position().y());

    if (x < kLabelColumnWidth) {
        return;
    }

    // A click in a segment lane either grabs an edge, grabs the whole block, or
    // falls through to scrubbing.
    const QVector<SegmentType> &types = allSegmentTypes();
    for (int i = 0; i < types.size(); ++i) {
        const QRect lane = laneRect(kFirstSegmentTrackIndex + i);
        if (!lane.contains(x, y)) {
            continue;
        }

        const SegmentType type = types.at(i);
        const auto it = m_drafts.constFind(static_cast<int>(type));
        if (it == m_drafts.constEnd() || it->isEmpty()) {
            break;
        }

        const double x1 = msToX(it->startMs.value_or(0));
        const double x2 = msToX(it->endMs.value_or(m_durationMs));

        m_dragSegment = type;
        m_dragOriginal = *it;
        m_dragAnchorMs = xToMs(x);

        if (std::abs(x - x1) <= kEdgeGrabPx) {
            m_dragMode = DragMode::SegmentStart;
        } else if (std::abs(x - x2) <= kEdgeGrabPx) {
            m_dragMode = DragMode::SegmentEnd;
        } else if (x > x1 && x < x2) {
            m_dragMode = DragMode::SegmentWhole;
        } else {
            break;
        }

        emit draftDragStarted();
        setCursor(m_dragMode == DragMode::SegmentWhole ? Qt::ClosedHandCursor : Qt::SizeHorCursor);
        return;
    }

    m_dragMode = DragMode::Playhead;
    emit seekRequested(xToMs(x));
}

void TimelineWidget::mouseMoveEvent(QMouseEvent *event)
{
    const int x = static_cast<int>(event->position().x());

    if (m_dragMode == DragMode::None) {
        // Hovering an edge advertises that it can be dragged.
        Qt::CursorShape shape = Qt::ArrowCursor;
        const QVector<SegmentType> &types = allSegmentTypes();
        for (int i = 0; i < types.size(); ++i) {
            const QRect lane = laneRect(kFirstSegmentTrackIndex + i);
            if (!lane.contains(x, static_cast<int>(event->position().y()))) {
                continue;
            }
            const auto it = m_drafts.constFind(static_cast<int>(types.at(i)));
            if (it != m_drafts.constEnd() && !it->isEmpty()) {
                const double x1 = msToX(it->startMs.value_or(0));
                const double x2 = msToX(it->endMs.value_or(m_durationMs));
                if (std::abs(x - x1) <= kEdgeGrabPx || std::abs(x - x2) <= kEdgeGrabPx) {
                    shape = Qt::SizeHorCursor;
                } else if (x > x1 && x < x2) {
                    shape = Qt::OpenHandCursor;
                }
            }
        }
        setCursor(shape);
        return;
    }

    if (m_dragMode == DragMode::Playhead) {
        emit seekRequested(xToMs(x));
        return;
    }

    const qint64 cursorMs = xToMs(x);
    SegmentDraft edited = m_dragOriginal;

    switch (m_dragMode) {
    case DragMode::SegmentStart:
        // Never let the start cross the end; the range would invert and the
        // validator would reject it on upload.
        edited.startMs = static_cast<int>(
            std::min<qint64>(cursorMs, edited.endMs.value_or(m_durationMs)));
        break;

    case DragMode::SegmentEnd:
        edited.endMs = static_cast<int>(
            std::max<qint64>(cursorMs, edited.startMs.value_or(0)));
        break;

    case DragMode::SegmentWhole: {
        const qint64 delta = cursorMs - m_dragAnchorMs;
        const qint64 originalStart = m_dragOriginal.startMs.value_or(0);
        const qint64 originalEnd = m_dragOriginal.endMs.value_or(m_durationMs);
        const qint64 length = originalEnd - originalStart;

        qint64 newStart = std::clamp<qint64>(originalStart + delta, 0, m_durationMs - length);
        edited.startMs = static_cast<int>(newStart);
        edited.endMs = static_cast<int>(newStart + length);
        break;
    }

    default:
        break;
    }

    m_drafts.insert(static_cast<int>(m_dragSegment), edited);
    emit draftEdited(m_dragSegment, edited);
    update();
}

void TimelineWidget::mouseReleaseEvent(QMouseEvent *)
{
    if (m_dragMode == DragMode::SegmentStart || m_dragMode == DragMode::SegmentEnd
        || m_dragMode == DragMode::SegmentWhole) {
        emit draftDragFinished();
    }
    m_dragMode = DragMode::None;
    unsetCursor();
}

void TimelineWidget::wheelEvent(QWheelEvent *event)
{
    if (m_durationMs <= 0) {
        return;
    }

    // Ctrl+wheel zooms, plain wheel pans — the convention every timeline editor
    // uses, and what a trackpad's horizontal scroll maps onto.
    if (event->modifiers().testFlag(Qt::ControlModifier)) {
        const double steps = event->angleDelta().y() / 120.0;
        setZoom(m_zoom * std::pow(1.25, steps));
        event->accept();
        return;
    }

    const int delta = event->angleDelta().x() != 0 ? event->angleDelta().x()
                                                   : event->angleDelta().y();
    m_scrollMs -= static_cast<qint64>((delta / 120.0) * (visibleSpanMs() / 8.0));
    clampScroll();
    update();
    event->accept();
}

bool TimelineWidget::event(QEvent *event)
{
    if (event->type() == QEvent::Gesture) {
        auto *gestureEvent = static_cast<QGestureEvent *>(event);
        if (QGesture *gesture = gestureEvent->gesture(Qt::PinchGesture)) {
            auto *pinch = static_cast<QPinchGesture *>(gesture);
            if (pinch->changeFlags().testFlag(QPinchGesture::ScaleFactorChanged)) {
                setZoom(m_zoom * pinch->scaleFactor());
            }
            return true;
        }
    }
    return QWidget::event(event);
}

void TimelineWidget::resizeEvent(QResizeEvent *event)
{
    QWidget::resizeEvent(event);
    clampScroll();
}

} // namespace segmenter
