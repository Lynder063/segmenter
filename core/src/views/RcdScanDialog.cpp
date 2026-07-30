#include "views/RcdScanDialog.h"

#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QFutureWatcher>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QVBoxLayout>
#include <QtConcurrent>

#include "Theme.h"
#include "platform/GpuDetector.h"
#include "platform/OcrService.h"

namespace segmenter {

RcdScanDialog::RcdScanDialog(QWidget *parent)
    : QDialog(parent)
    , m_cancelFlag(std::make_unique<std::atomic_bool>(false))
{
    setWindowTitle(tr("Repeated Content Detection"));
    setModal(true);
    resize(720, 620);
    buildUi();
    onMethodChanged();
}

RcdScanDialog::~RcdScanDialog()
{
    // The worker captures the flag by pointer; make sure it is told to stop
    // before this object goes away.
    if (m_cancelFlag) {
        m_cancelFlag->store(true);
    }
}

void RcdScanDialog::buildUi()
{
    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(14, 14, 14, 14);
    root->setSpacing(10);

    // --- 1. Source --------------------------------------------------------
    auto *sourceGroup = new QGroupBox(this);
    auto *sourceLayout = new QVBoxLayout(sourceGroup);

    m_sourceHeading = new QLabel(tr("1. Season Directory"), sourceGroup);
    m_sourceHeading->setStyleSheet(QStringLiteral("font-weight: bold;"));
    sourceLayout->addWidget(m_sourceHeading);

    auto *sourceRow = new QHBoxLayout();
    m_sourceLabel = new QLabel(tr("No directory selected"), sourceGroup);
    m_sourceLabel->setObjectName(QStringLiteral("hintText"));
    m_sourceLabel->setWordWrap(true);
    sourceRow->addWidget(m_sourceLabel, 1);

    m_selectSourceButton = new QPushButton(tr("Choose..."), sourceGroup);
    sourceRow->addWidget(m_selectSourceButton);
    sourceLayout->addLayout(sourceRow);

    root->addWidget(sourceGroup);

    // --- 2. Method --------------------------------------------------------
    auto *methodGroup = new QGroupBox(this);
    auto *methodLayout = new QVBoxLayout(methodGroup);

    auto *methodHeading = new QLabel(tr("2. Detection Method"), methodGroup);
    methodHeading->setStyleSheet(QStringLiteral("font-weight: bold;"));
    methodLayout->addWidget(methodHeading);

    m_methodCombo = new QComboBox(methodGroup);
    for (const RcdDetectionMethod method : allRcdDetectionMethods()) {
        m_methodCombo->addItem(rcdMethodDisplayName(method), static_cast<int>(method));
    }
    methodLayout->addWidget(m_methodCombo);

    m_methodDescription = new QLabel(methodGroup);
    m_methodDescription->setObjectName(QStringLiteral("hintText"));
    m_methodDescription->setWordWrap(true);
    methodLayout->addWidget(m_methodDescription);

    m_accelerationLabel = new QLabel(methodGroup);
    m_accelerationLabel->setObjectName(QStringLiteral("hintText"));
    m_accelerationLabel->setText(QStringLiteral("%1 • %2")
                                     .arg(GpuDetector::accelerationSummary(),
                                          OcrService::instance().backendDescription()));
    methodLayout->addWidget(m_accelerationLabel);

    auto *tuningLayout = new QFormLayout();
    m_minLengthSpin = new QDoubleSpinBox(methodGroup);
    m_minLengthSpin->setRange(1.0, 600.0);
    m_minLengthSpin->setValue(15.0);
    m_minLengthSpin->setSuffix(tr(" s"));
    tuningLayout->addRow(tr("Minimum segment length"), m_minLengthSpin);

    m_thresholdSpin = new QDoubleSpinBox(methodGroup);
    m_thresholdSpin->setRange(0.30, 0.99);
    m_thresholdSpin->setSingleStep(0.05);
    m_thresholdSpin->setValue(0.80);
    tuningLayout->addRow(tr("Similarity threshold"), m_thresholdSpin);
    methodLayout->addLayout(tuningLayout);

    root->addWidget(methodGroup);

    // --- 3. Progress ------------------------------------------------------
    m_progressBar = new QProgressBar(this);
    m_progressBar->setRange(0, 100);
    m_progressBar->setValue(0);
    root->addWidget(m_progressBar);

    m_statusLabel = new QLabel(tr("Ready."), this);
    m_statusLabel->setObjectName(QStringLiteral("hintText"));
    root->addWidget(m_statusLabel);

    m_logView = new QPlainTextEdit(this);
    m_logView->setReadOnly(true);
    m_logView->setFont(QFont(QStringLiteral("Consolas"), 8));
    root->addWidget(m_logView, 1);

    auto *buttonRow = new QHBoxLayout();
    buttonRow->addStretch(1);

    m_closeButton = new QPushButton(tr("Close"), this);
    buttonRow->addWidget(m_closeButton);

    m_startButton = new QPushButton(tr("Start Scan"), this);
    m_startButton->setObjectName(QStringLiteral("uploadAllBtn"));
    buttonRow->addWidget(m_startButton);
    root->addLayout(buttonRow);

    connect(m_selectSourceButton, &QPushButton::clicked, this, &RcdScanDialog::onSelectSource);
    connect(m_methodCombo, &QComboBox::currentIndexChanged, this, &RcdScanDialog::onMethodChanged);
    connect(m_startButton, &QPushButton::clicked, this, &RcdScanDialog::onStartScan);
    connect(m_closeButton, &QPushButton::clicked, this, [this] {
        if (m_running) {
            onCancelScan();
        } else {
            reject();
        }
    });
}

bool RcdScanDialog::needsSeasonFolder() const
{
    return rcdMethodNeedsSeasonFolder(
        static_cast<RcdDetectionMethod>(m_methodCombo->currentData().toInt()));
}

void RcdScanDialog::setInitialSource(const QString &videoPath)
{
    m_lastVideoPath = videoPath;
    if (videoPath.isEmpty()) {
        return;
    }

    m_sourcePath = needsSeasonFolder() ? QFileInfo(videoPath).absolutePath() : videoPath;
    m_sourceLabel->setText(m_sourcePath);
}

void RcdScanDialog::onMethodChanged()
{
    const auto method = static_cast<RcdDetectionMethod>(m_methodCombo->currentData().toInt());
    m_methodDescription->setText(rcdMethodDescription(method));

    const bool seasonFolder = needsSeasonFolder();
    m_sourceHeading->setText(seasonFolder ? tr("1. Season Directory") : tr("1. Video File"));

    // The path that made sense for the previous mode usually does not for this
    // one — re-derive it from the loaded video rather than leaving a directory
    // in a field that now wants a file.
    if (!m_lastVideoPath.isEmpty()) {
        m_sourcePath = seasonFolder ? QFileInfo(m_lastVideoPath).absolutePath() : m_lastVideoPath;
    } else {
        m_sourcePath.clear();
    }

    m_sourceLabel->setText(m_sourcePath.isEmpty()
                               ? (seasonFolder ? tr("No directory selected")
                                               : tr("No video file selected"))
                               : m_sourcePath);
}

void RcdScanDialog::onSelectSource()
{
    if (needsSeasonFolder()) {
        const QString directory = QFileDialog::getExistingDirectory(
            this, tr("Select Season Directory"),
            m_sourcePath.isEmpty() ? QString() : m_sourcePath);
        if (!directory.isEmpty()) {
            m_sourcePath = directory;
        }
    } else {
        const QString file = QFileDialog::getOpenFileName(
            this, tr("Select Video File"),
            m_sourcePath.isEmpty() ? QString() : QFileInfo(m_sourcePath).absolutePath(),
            tr("Video files (*.mp4 *.mkv *.avi *.mov *.webm *.m4v);;All files (*)"));
        if (!file.isEmpty()) {
            m_sourcePath = file;
            m_lastVideoPath = file;
        }
    }

    if (!m_sourcePath.isEmpty()) {
        m_sourceLabel->setText(m_sourcePath);
    }
}

void RcdScanDialog::appendLog(const QString &line)
{
    m_logView->appendPlainText(line);
}

void RcdScanDialog::setRunning(bool running)
{
    m_running = running;
    m_startButton->setEnabled(!running);
    m_selectSourceButton->setEnabled(!running);
    m_methodCombo->setEnabled(!running);
    m_minLengthSpin->setEnabled(!running);
    m_thresholdSpin->setEnabled(!running);
    m_closeButton->setText(running ? tr("Cancel") : tr("Close"));
}

void RcdScanDialog::onCancelScan()
{
    if (m_cancelFlag) {
        m_cancelFlag->store(true);
    }
    m_statusLabel->setText(tr("Cancelling..."));
}

void RcdScanDialog::onStartScan()
{
    if (m_sourcePath.isEmpty()) {
        QMessageBox::warning(this, tr("No source selected"),
                             needsSeasonFolder()
                                 ? tr("Choose the season directory to scan.")
                                 : tr("Choose the video file to scan."));
        return;
    }

    m_logView->clear();
    m_results.clear();
    m_cancelFlag->store(false);
    setRunning(true);

    RcdEngine::Options options;
    options.method = static_cast<RcdDetectionMethod>(m_methodCombo->currentData().toInt());
    options.minSegmentLengthSec = m_minLengthSpin->value();
    options.similarityThreshold = m_thresholdSpin->value();

    const QString sourcePath = m_sourcePath;
    const bool seasonScan = needsSeasonFolder();
    std::atomic_bool *cancelFlag = m_cancelFlag.get();

    // The engine calls these from worker threads, so both hop back to the GUI
    // thread via a queued connection before touching a widget.
    auto progressHandler = [this](const QString &message, int percent) {
        QMetaObject::invokeMethod(this, [this, message, percent] {
            m_statusLabel->setText(message);
            m_progressBar->setValue(percent);
        }, Qt::QueuedConnection);
    };

    auto debugLogger = [this](const QString &line) {
        QMetaObject::invokeMethod(this, [this, line] {
            appendLog(line);
        }, Qt::QueuedConnection);
    };

    struct ScanOutcome {
        RcdEngine::Results results;
        QString error;
        bool cancelled = false;
    };

    auto *watcher = new QFutureWatcher<ScanOutcome>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        const ScanOutcome outcome = watcher->result();
        watcher->deleteLater();

        setRunning(false);

        if (outcome.cancelled) {
            m_statusLabel->setText(tr("Scan cancelled."));
            m_progressBar->setValue(0);
            return;
        }

        if (!outcome.error.isEmpty()) {
            m_statusLabel->setText(tr("Scan failed."));
            appendLog(QStringLiteral("ERROR: ") + outcome.error);
            QMessageBox::critical(this, tr("Scan failed"), outcome.error);
            return;
        }

        m_results = outcome.results;

        int totalSegments = 0;
        for (const QVector<RcdMatch> &matches : std::as_const(m_results)) {
            totalSegments += static_cast<int>(matches.size());
        }

        m_statusLabel->setText(tr("Found %1 segment(s) across %2 file(s).")
                                   .arg(totalSegments).arg(m_results.size()));

        // Nothing found is a completed scan, not a failure — leave the dialog
        // open so the log explains why rather than dropping the user back with
        // no drafts and no reason.
        if (totalSegments > 0) {
            accept();
        }
    });

    watcher->setFuture(QtConcurrent::run(
        [sourcePath, seasonScan, options, cancelFlag, progressHandler, debugLogger]() -> ScanOutcome {
            ScanOutcome outcome;
            try {
                outcome.results = seasonScan
                    ? RcdEngine::instance().scanSeason(sourcePath, options, *cancelFlag,
                                                       progressHandler, debugLogger)
                    : RcdEngine::instance().scanSingleEpisode(sourcePath, options, *cancelFlag,
                                                              progressHandler, debugLogger);
            } catch (const RcdEngine::Cancelled &) {
                outcome.cancelled = true;
            } catch (const std::exception &error) {
                outcome.error = QString::fromUtf8(error.what());
            }
            return outcome;
        }));
}

} // namespace segmenter
