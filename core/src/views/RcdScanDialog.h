#pragma once

#include <QDialog>

#include <atomic>
#include <memory>

#include "models/Models.h"
#include "services/RcdEngine.h"

class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QPlainTextEdit;
class QProgressBar;
class QPushButton;

namespace segmenter {

/// The RCD scan window: pick a source, pick a detection method, watch it run.
///
/// The source is a season directory for the three cross-episode methods and a
/// single video file for Single Episode — the picker switches with the method
/// rather than making the user work out which one applies.
class RcdScanDialog : public QDialog {
    Q_OBJECT

public:
    explicit RcdScanDialog(QWidget *parent = nullptr);
    ~RcdScanDialog() override;

    /// Pre-fills the source from the currently loaded video, so scanning the
    /// season a file belongs to is one click.
    void setInitialSource(const QString &videoPath);

    /// Matches keyed by episode filename, valid once the dialog is accepted.
    const RcdEngine::Results &results() const { return m_results; }

private slots:
    void onSelectSource();
    void onMethodChanged();
    void onStartScan();
    void onCancelScan();

private:
    void buildUi();
    void appendLog(const QString &line);
    void setRunning(bool running);
    bool needsSeasonFolder() const;

    QComboBox *m_methodCombo = nullptr;
    QLabel *m_methodDescription = nullptr;
    QLabel *m_sourceLabel = nullptr;
    QLabel *m_sourceHeading = nullptr;
    QLabel *m_accelerationLabel = nullptr;
    QPushButton *m_selectSourceButton = nullptr;
    QDoubleSpinBox *m_minLengthSpin = nullptr;
    QDoubleSpinBox *m_thresholdSpin = nullptr;
    QProgressBar *m_progressBar = nullptr;
    QLabel *m_statusLabel = nullptr;
    QPlainTextEdit *m_logView = nullptr;
    QPushButton *m_startButton = nullptr;
    QPushButton *m_closeButton = nullptr;

    QString m_sourcePath;
    QString m_lastVideoPath;

    RcdEngine::Results m_results;

    // Read by the engine's worker threads, written by the GUI thread.
    std::unique_ptr<std::atomic_bool> m_cancelFlag;
    bool m_running = false;
};

} // namespace segmenter
