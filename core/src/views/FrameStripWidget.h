#pragma once

#include <QHash>
#include <QPixmap>
#include <QWidget>

class QLabel;
class QTimer;

namespace segmenter {

/// The 13-frame preview strip centred on the playhead, for placing a boundary
/// on an exact frame. Thumbnails come from ffmpeg's stdout pipe rather than the
/// player, which keeps it working for containers VLC seeks poorly in.
class FrameStripWidget : public QWidget {
    Q_OBJECT

public:
    explicit FrameStripWidget(QWidget *parent = nullptr);
    ~FrameStripWidget() override;

    void setVideo(const QString &filePath, double frameRate, qint64 durationMs);
    void clear();

    /// Moves the strip. Extraction is debounced, so this is safe to call from
    /// the 5 ms player poll.
    void setPlayheadMs(qint64 milliseconds);

    /// Distance between adjacent frames. Defaults to 250 ms, matching the
    /// macOS build's strip.
    void setStepMs(int stepMs);
    int stepMs() const { return m_stepMs; }

signals:
    /// A thumbnail was clicked; the caller should seek there.
    void seekRequested(qint64 milliseconds);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;

private:
    static constexpr int kFrameCount = 13;
    static constexpr int kThumbWidth = 96;
    static constexpr int kThumbHeight = 54;

    void scheduleExtraction();
    void extractVisibleFrames();
    QRect thumbnailRect(int index) const;

    QString m_filePath;
    double m_frameRate = 23.976;
    qint64 m_durationMs = 0;
    qint64 m_playheadMs = 0;
    int m_stepMs = 250;

    // Keyed by the frame's timestamp so panning back and forth over the same
    // region reuses what was already decoded.
    QHash<qint64, QPixmap> m_cache;

    QTimer *m_debounce = nullptr;
    bool m_extracting = false;
};

} // namespace segmenter
