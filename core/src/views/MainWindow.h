#pragma once

#include <QHash>
#include <QMainWindow>
#include <QVector>

#include "models/Models.h"

class QLabel;
class QPushButton;
class QSlider;
class QToolButton;

namespace segmenter {

class FrameStripWidget;
class SidebarPanel;
class TimelineWidget;
class VlcVideoPlayer;

/// The application window: sidebar, player, transport, frame strip and
/// timeline, plus the keyboard shortcuts that make marking boundaries fast.
class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;

    /// Opens a video without going through the file dialog — used for the
    /// command-line argument, so `Segmenter.exe <file>` works from a shell and
    /// from a "Open with" association.
    void openVideo(const QString &filePath);

protected:
    void keyPressEvent(QKeyEvent *event) override;
    void closeEvent(QCloseEvent *event) override;

private slots:
    void onOpenVideo();
    void onSaveKeys();
    void onSearchTmdb(const QString &query);
    void onLookupResultSelected(int index);
    void onLoadSegments();
    void onUploadAll();
    void onUploadSegment(SegmentType type);
    void onScanSeason();

    void onPlayerTimeChanged(qint64 milliseconds);
    void onPlayerDurationChanged(qint64 milliseconds);
    void onPlayingStateChanged(bool playing);

    void onDraftEdited(SegmentType type, const SegmentDraft &draft);
    void onClearDraft(SegmentType type);
    void onSetStartFromPlayhead(SegmentType type);
    void onSetEndFromPlayhead(SegmentType type);

private:
    void buildUi();
    void buildTransportBar(QWidget *parent, QLayout *parentLayout);
    void buildZoomToolbar(QWidget *parent, QLayout *parentLayout);
    void wireSignals();
    void loadStoredKeys();
    void loadVideo(const QString &filePath);
    void startAudioAnalysis();

    void setStatus(const QString &message, const QColor &colour);
    void setStatusInfo(const QString &message);
    void setStatusSuccess(const QString &message);
    void setStatusError(const QString &message);

    void refreshDrafts();
    void pushUndoSnapshot();
    void undo();
    void redo();

    /// Builds the submission draft for one segment from the current sidebar
    /// state. Returns false and reports why when identification is incomplete.
    bool makeSubmissionDraft(SegmentType type, SubmissionDraft *out, QString *error) const;

    void applyRcdMatches(const QHash<QString, QVector<RcdMatch>> &results);

    // --- Widgets ---
    SidebarPanel *m_sidebar = nullptr;
    VlcVideoPlayer *m_player = nullptr;
    FrameStripWidget *m_frameStrip = nullptr;
    TimelineWidget *m_timeline = nullptr;

    QToolButton *m_playButton = nullptr;
    QToolButton *m_stepBackButton = nullptr;
    QToolButton *m_stepForwardButton = nullptr;
    QLabel *m_currentTimeLabel = nullptr;
    QLabel *m_durationLabel = nullptr;
    QSlider *m_seekSlider = nullptr;
    QSlider *m_zoomSlider = nullptr;
    QLabel *m_zoomLabel = nullptr;
    QLabel *m_statusLabel = nullptr;
    QLabel *m_usageLabel = nullptr;

    // --- State ---
    QString m_videoPath;
    qint64 m_durationMs = 0;
    qint64 m_playheadMs = 0;
    double m_frameRate = 23.976;

    QHash<int, SegmentDraft> m_drafts;
    QVector<AutoLookupResult> m_lookupResults;

    // Snapshots for undo/redo. Bounded, because a drag can produce a lot of
    // them and the whole history is only worth a few dozen steps.
    QVector<QHash<int, SegmentDraft>> m_undoStack;
    QVector<QHash<int, SegmentDraft>> m_redoStack;

    // The seek slider must not fight the player: while the user drags it, the
    // player's own time updates stop moving it.
    bool m_userIsSeeking = false;

    // Matches from a scan that arrived before the duration was known.
    QVector<RcdMatch> m_pendingRcdMatches;
};

} // namespace segmenter
