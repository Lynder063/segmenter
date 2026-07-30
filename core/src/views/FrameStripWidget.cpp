#include "views/FrameStripWidget.h"

#include <QMouseEvent>
#include <QPainter>
#include <QTimer>
#include <QtConcurrent>

#include "Theme.h"
#include "services/FFmpegService.h"

namespace segmenter {
namespace {

constexpr int kLabelHeight = 14;
constexpr int kHeaderHeight = 18;
constexpr int kGap = 14;

// Extraction is only worth starting once the playhead settles; during playback
// this would otherwise queue a decode per poll.
constexpr int kDebounceMs = 120;

} // namespace

FrameStripWidget::FrameStripWidget(QWidget *parent)
    : QWidget(parent)
{
    setMinimumHeight(kHeaderHeight + kThumbHeight + kLabelHeight + 16);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);

    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(kDebounceMs);
    connect(m_debounce, &QTimer::timeout, this, &FrameStripWidget::extractVisibleFrames);
}

FrameStripWidget::~FrameStripWidget() = default;

void FrameStripWidget::setVideo(const QString &filePath, double frameRate, qint64 durationMs)
{
    m_filePath = filePath;
    m_frameRate = frameRate > 0.0 ? frameRate : 23.976;
    m_durationMs = durationMs;
    m_cache.clear();
    scheduleExtraction();
    update();
}

void FrameStripWidget::clear()
{
    m_filePath.clear();
    m_durationMs = 0;
    m_playheadMs = 0;
    m_cache.clear();
    update();
}

void FrameStripWidget::setStepMs(int stepMs)
{
    m_stepMs = std::max(1, stepMs);
    scheduleExtraction();
    update();
}

void FrameStripWidget::setPlayheadMs(qint64 milliseconds)
{
    // Snap to the step grid so the strip does not re-extract 13 new timestamps
    // for every millisecond the playhead advances.
    const qint64 snapped = (milliseconds / m_stepMs) * m_stepMs;
    if (snapped == m_playheadMs) {
        return;
    }
    m_playheadMs = snapped;
    scheduleExtraction();
    update();
}

void FrameStripWidget::scheduleExtraction()
{
    if (!m_filePath.isEmpty()) {
        m_debounce->start();
    }
}

void FrameStripWidget::extractVisibleFrames()
{
    if (m_filePath.isEmpty() || m_extracting) {
        return;
    }

    QVector<qint64> wanted;
    for (int i = 0; i < kFrameCount; ++i) {
        const qint64 offset = static_cast<qint64>(i - kFrameCount / 2) * m_stepMs;
        const qint64 time = m_playheadMs + offset;
        if (time >= 0 && (m_durationMs <= 0 || time <= m_durationMs) && !m_cache.contains(time)) {
            wanted.append(time);
        }
    }

    if (wanted.isEmpty()) {
        return;
    }

    m_extracting = true;
    const QString path = m_filePath;

    auto *watcher = new QFutureWatcher<QPair<qint64, QPixmap>>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        for (const QPair<qint64, QPixmap> &entry : watcher->future().results()) {
            if (!entry.second.isNull()) {
                m_cache.insert(entry.first, entry.second);
            }
        }

        // Bound the cache so scrubbing a long file does not accumulate every
        // frame it ever passed over.
        if (m_cache.size() > 400) {
            m_cache.clear();
        }

        m_extracting = false;
        watcher->deleteLater();
        update();
    });

    watcher->setFuture(QtConcurrent::mapped(
        wanted,
        std::function<QPair<qint64, QPixmap>(const qint64 &)>(
            [path](const qint64 &timeMs) -> QPair<qint64, QPixmap> {
                const QByteArray jpeg = FFmpegService::instance().extractThumbnailData(
                    path, static_cast<int>(timeMs),
                    QStringLiteral("%1x%2").arg(kThumbWidth * 2).arg(kThumbHeight * 2));
                QPixmap pixmap;
                if (!jpeg.isEmpty()) {
                    pixmap.loadFromData(jpeg, "JPEG");
                }
                return {timeMs, pixmap};
            })));
}

QRect FrameStripWidget::thumbnailRect(int index) const
{
    const int totalWidth = kFrameCount * kThumbWidth + (kFrameCount - 1) * kGap;
    const int startX = (width() - totalWidth) / 2;
    const int x = startX + index * (kThumbWidth + kGap);
    return QRect(x, kHeaderHeight + 4, kThumbWidth, kThumbHeight);
}

void FrameStripWidget::resizeEvent(QResizeEvent *event)
{
    QWidget::resizeEvent(event);
    update();
}

void FrameStripWidget::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.fillRect(rect(), theme::color::windowBackground);

    // Header: an "Overview" chip and the current step, mirroring the macOS strip.
    const QRect badgeRect(6, 2, 54, 14);
    painter.setPen(Qt::NoPen);
    painter.setBrush(theme::color::accent);
    painter.drawRoundedRect(badgeRect, 3, 3);
    painter.setPen(Qt::white);
    QFont badgeFont = painter.font();
    badgeFont.setPointSizeF(7.5);
    badgeFont.setBold(true);
    painter.setFont(badgeFont);
    painter.drawText(badgeRect, Qt::AlignCenter, tr("Overview"));

    QFont infoFont = painter.font();
    infoFont.setBold(false);
    infoFont.setPointSizeF(7.5);
    painter.setFont(infoFont);
    painter.setPen(theme::color::textMuted);
    painter.drawText(QRect(badgeRect.right() + 8, 2, 260, 14), Qt::AlignVCenter,
                     tr("step = %1 ms, fps %2").arg(m_stepMs).arg(m_frameRate, 0, 'f', 2));

    if (m_filePath.isEmpty()) {
        return;
    }

    QFont timeFont = painter.font();
    timeFont.setPointSizeF(7.0);
    timeFont.setFamily(QStringLiteral("Consolas"));

    for (int i = 0; i < kFrameCount; ++i) {
        const qint64 offset = static_cast<qint64>(i - kFrameCount / 2) * m_stepMs;
        const qint64 time = m_playheadMs + offset;
        if (time < 0 || (m_durationMs > 0 && time > m_durationMs)) {
            continue;
        }

        const QRect target = thumbnailRect(i);
        const bool isCenter = (i == kFrameCount / 2);

        const auto cached = m_cache.constFind(time);
        if (cached != m_cache.constEnd()) {
            painter.drawPixmap(target, *cached);
        } else {
            painter.fillRect(target, theme::color::panelBackground);
        }

        // The centre frame is the one the playhead is actually on; the blue
        // outline is how the user tells it apart at a glance.
        painter.setBrush(Qt::NoBrush);
        painter.setPen(QPen(isCenter ? theme::color::accent : theme::color::border,
                            isCenter ? 2 : 1));
        painter.drawRect(target.adjusted(0, 0, -1, -1));

        painter.setFont(timeFont);
        painter.setPen(isCenter ? theme::color::accent : theme::color::textMuted);
        painter.drawText(QRect(target.left(), target.bottom() + 2, target.width(), kLabelHeight),
                         Qt::AlignCenter, formatTimecode(static_cast<int>(time)));
    }
}

void FrameStripWidget::mousePressEvent(QMouseEvent *event)
{
    if (m_filePath.isEmpty()) {
        return;
    }

    for (int i = 0; i < kFrameCount; ++i) {
        if (thumbnailRect(i).contains(event->pos())) {
            const qint64 offset = static_cast<qint64>(i - kFrameCount / 2) * m_stepMs;
            const qint64 time = m_playheadMs + offset;
            if (time >= 0) {
                emit seekRequested(time);
            }
            return;
        }
    }
}

} // namespace segmenter
