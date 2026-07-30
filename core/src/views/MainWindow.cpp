#include "views/MainWindow.h"

#include <QApplication>
#include <QCloseEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QMessageBox>
#include <QScrollArea>
#include <QSlider>
#include <QSplitter>
#include <QToolButton>
#include <QVBoxLayout>
#include <QtConcurrent>

#include "Theme.h"
#include "services/ApiClient.h"
#include "services/AudioExtractorService.h"
#include "platform/CredentialStore.h"
#include "services/FFmpegService.h"
#include "services/FilenameMediaParser.h"
#include "services/LoggerService.h"
#include "services/SegmentValidator.h"
#include "views/FrameStripWidget.h"
#include "views/RcdScanDialog.h"
#include "views/SidebarPanel.h"
#include "views/TimelineWidget.h"
#include "views/VlcVideoPlayer.h"

namespace segmenter {
namespace {

constexpr int kMaxUndoDepth = 60;

// Wide enough for the draft rows' two timecode fields plus four buttons, and
// for "Load Segments" and "Upload All Drafts" to sit side by side without
// either being elided.
constexpr int kSidebarWidth = 450;

} // namespace

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle(QStringLiteral("Segmenter"));
    resize(1680, 980);

    FFmpegService::instance().resolveBinaries();

    buildUi();
    wireSignals();
    loadStoredKeys();

    if (!FFmpegService::instance().hasBinaries()) {
        setStatusError(tr("ffmpeg/ffprobe not found — frame strip, waveform and RCD scanning "
                          "are unavailable. Install with: winget install Gyan.FFmpeg"));
    } else {
        setStatusInfo(tr("Ready."));
    }
}

MainWindow::~MainWindow() = default;

// MARK: - Construction

void MainWindow::buildUi()
{
    auto *central = new QWidget(this);
    auto *centralLayout = new QVBoxLayout(central);
    centralLayout->setContentsMargins(0, 0, 0, 0);
    centralLayout->setSpacing(0);

    auto *splitter = new QSplitter(Qt::Horizontal, central);

    // --- Left: sidebar in a scroll area ------------------------------------
    // Deliberately parentless: passing `splitter` here would add the panel as a
    // pane of its own before setWidget reparents it, leaving an empty third
    // pane behind and throwing off every setSizes call.
    m_sidebar = new SidebarPanel;

    auto *sidebarScroll = new QScrollArea(splitter);
    sidebarScroll->setWidget(m_sidebar);
    sidebarScroll->setWidgetResizable(true);
    sidebarScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    // Below this the draft rows start clipping their upload button.
    sidebarScroll->setMinimumWidth(kSidebarWidth);
    splitter->addWidget(sidebarScroll);

    // --- Right: player, transport, frame strip, timeline -------------------
    auto *rightPane = new QWidget(splitter);
    auto *rightLayout = new QVBoxLayout(rightPane);
    rightLayout->setContentsMargins(6, 6, 6, 6);
    rightLayout->setSpacing(6);

    m_player = new VlcVideoPlayer(rightPane);
    m_player->setMinimumHeight(280);
    rightLayout->addWidget(m_player, 1);

    buildTransportBar(rightPane, rightLayout);

    m_frameStrip = new FrameStripWidget(rightPane);
    rightLayout->addWidget(m_frameStrip);

    buildZoomToolbar(rightPane, rightLayout);

    // No stretch: the timeline is exactly as tall as its tracks, so the video
    // pane absorbs the remaining height instead of leaving dead space below the
    // last track.
    m_timeline = new TimelineWidget(rightPane);
    rightLayout->addWidget(m_timeline);

    splitter->addWidget(rightPane);
    splitter->setStretchFactor(0, 0);
    splitter->setStretchFactor(1, 1);
    splitter->setSizes({kSidebarWidth, 1280});

    centralLayout->addWidget(splitter, 1);

    // --- Status bar --------------------------------------------------------
    auto *statusBar = new QWidget(central);
    statusBar->setObjectName(QStringLiteral("statusBar"));
    auto *statusLayout = new QHBoxLayout(statusBar);
    statusLayout->setContentsMargins(10, 4, 10, 4);

    m_statusLabel = new QLabel(tr("Ready."), statusBar);
    m_statusLabel->setObjectName(QStringLiteral("statusMsg"));
    statusLayout->addWidget(m_statusLabel, 1);

    m_usageLabel = new QLabel(statusBar);
    m_usageLabel->setObjectName(QStringLiteral("hintText"));
    statusLayout->addWidget(m_usageLabel);

    centralLayout->addWidget(statusBar);

    setCentralWidget(central);
}

void MainWindow::buildTransportBar(QWidget *parent, QLayout *parentLayout)
{
    auto *bar = new QWidget(parent);
    auto *layout = new QHBoxLayout(bar);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    m_playButton = new QToolButton(bar);
    m_playButton->setText(QStringLiteral("▶"));
    m_playButton->setToolTip(tr("Play / Pause (Space)"));
    layout->addWidget(m_playButton);

    m_stepBackButton = new QToolButton(bar);
    m_stepBackButton->setText(QStringLiteral("⏪"));
    m_stepBackButton->setToolTip(tr("Step one frame back (Left / ,)"));
    layout->addWidget(m_stepBackButton);

    m_stepForwardButton = new QToolButton(bar);
    m_stepForwardButton->setText(QStringLiteral("⏩"));
    m_stepForwardButton->setToolTip(tr("Step one frame forward (Right / .)"));
    layout->addWidget(m_stepForwardButton);

    m_currentTimeLabel = new QLabel(QStringLiteral("00:00.000"), bar);
    m_currentTimeLabel->setFont(QFont(QStringLiteral("Consolas"), 9));
    m_currentTimeLabel->setMinimumWidth(78);
    layout->addWidget(m_currentTimeLabel);

    m_seekSlider = new QSlider(Qt::Horizontal, bar);
    m_seekSlider->setRange(0, 0);
    layout->addWidget(m_seekSlider, 1);

    m_durationLabel = new QLabel(QStringLiteral("00:00.000"), bar);
    m_durationLabel->setFont(QFont(QStringLiteral("Consolas"), 9));
    m_durationLabel->setMinimumWidth(78);
    m_durationLabel->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    layout->addWidget(m_durationLabel);

    parentLayout->addWidget(bar);
}

void MainWindow::buildZoomToolbar(QWidget *parent, QLayout *parentLayout)
{
    auto *bar = new QWidget(parent);
    auto *layout = new QHBoxLayout(bar);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto *label = new QLabel(tr("Zoom:"), bar);
    label->setObjectName(QStringLiteral("hintText"));
    layout->addWidget(label);

    auto *zoomOut = new QToolButton(bar);
    zoomOut->setText(QStringLiteral("−"));
    layout->addWidget(zoomOut);

    // The slider is linear in 0.1x steps over 1.0x-50.0x; QSlider is integer
    // only, hence the x10 scaling on both sides.
    m_zoomSlider = new QSlider(Qt::Horizontal, bar);
    m_zoomSlider->setRange(static_cast<int>(TimelineWidget::kMinZoom * 10),
                           static_cast<int>(TimelineWidget::kMaxZoom * 10));
    m_zoomSlider->setValue(10);
    m_zoomSlider->setMaximumWidth(240);
    layout->addWidget(m_zoomSlider);

    auto *zoomIn = new QToolButton(bar);
    zoomIn->setText(QStringLiteral("+"));
    layout->addWidget(zoomIn);

    auto *resetZoom = new QToolButton(bar);
    resetZoom->setText(QStringLiteral("1x"));
    layout->addWidget(resetZoom);

    auto *scope = new QToolButton(bar);
    scope->setText(QStringLiteral("🎯 Scope"));
    scope->setToolTip(tr("Centre the timeline on the playhead"));
    layout->addWidget(scope);

    m_zoomLabel = new QLabel(QStringLiteral("1.0x"), bar);
    m_zoomLabel->setObjectName(QStringLiteral("hintText"));
    m_zoomLabel->setMinimumWidth(44);
    layout->addWidget(m_zoomLabel);

    layout->addStretch(1);
    parentLayout->addWidget(bar);

    connect(zoomOut, &QToolButton::clicked, this, [this] {
        m_timeline->setZoom(m_timeline->zoom() / 1.5);
    });
    connect(zoomIn, &QToolButton::clicked, this, [this] {
        m_timeline->setZoom(m_timeline->zoom() * 1.5);
    });
    connect(resetZoom, &QToolButton::clicked, this, [this] {
        m_timeline->setZoom(1.0);
    });
    connect(scope, &QToolButton::clicked, this, [this] {
        m_timeline->centerOnPlayhead();
    });
    connect(m_zoomSlider, &QSlider::valueChanged, this, [this](int value) {
        m_timeline->setZoom(value / 10.0);
    });
}

void MainWindow::wireSignals()
{
    // --- Sidebar ---
    connect(m_sidebar, &SidebarPanel::openVideoRequested, this, &MainWindow::onOpenVideo);
    connect(m_sidebar, &SidebarPanel::saveKeysRequested, this, &MainWindow::onSaveKeys);
    connect(m_sidebar, &SidebarPanel::searchTmdbRequested, this, &MainWindow::onSearchTmdb);
    connect(m_sidebar, &SidebarPanel::lookupResultSelected, this, &MainWindow::onLookupResultSelected);
    connect(m_sidebar, &SidebarPanel::loadSegmentsRequested, this, &MainWindow::onLoadSegments);
    connect(m_sidebar, &SidebarPanel::uploadAllRequested, this, &MainWindow::onUploadAll);
    connect(m_sidebar, &SidebarPanel::scanSeasonRequested, this, &MainWindow::onScanSeason);
    connect(m_sidebar, &SidebarPanel::draftEdited, this, &MainWindow::onDraftEdited);
    connect(m_sidebar, &SidebarPanel::clearDraftRequested, this, &MainWindow::onClearDraft);
    connect(m_sidebar, &SidebarPanel::setStartFromPlayheadRequested,
            this, &MainWindow::onSetStartFromPlayhead);
    connect(m_sidebar, &SidebarPanel::setEndFromPlayheadRequested,
            this, &MainWindow::onSetEndFromPlayhead);
    connect(m_sidebar, &SidebarPanel::uploadSegmentRequested, this, &MainWindow::onUploadSegment);

    // --- Player ---
    connect(m_player, &VlcVideoPlayer::timeChanged, this, &MainWindow::onPlayerTimeChanged);
    connect(m_player, &VlcVideoPlayer::durationChanged, this, &MainWindow::onPlayerDurationChanged);
    connect(m_player, &VlcVideoPlayer::playingStateChanged, this, &MainWindow::onPlayingStateChanged);
    connect(m_player, &VlcVideoPlayer::errorOccurred, this, &MainWindow::setStatusError);

    // The first launch after a build spends ~20 s rebuilding LibVLC's plugin
    // cache. Say so, rather than letting it look like the app has hung.
    connect(m_player, &VlcVideoPlayer::engineInitializing, this, [this] {
        setStatusInfo(tr("Starting video engine (first run after an update takes a moment)..."));
    });
    connect(m_player, &VlcVideoPlayer::engineReady, this, [this](const QString &version) {
        setStatusInfo(tr("Ready. LibVLC %1").arg(version));
    });

    // --- Transport ---
    connect(m_playButton, &QToolButton::clicked, this, [this] { m_player->togglePlayPause(); });
    connect(m_stepBackButton, &QToolButton::clicked, this, [this] { m_player->stepFrame(-1); });
    connect(m_stepForwardButton, &QToolButton::clicked, this, [this] { m_player->stepFrame(1); });

    connect(m_seekSlider, &QSlider::sliderPressed, this, [this] { m_userIsSeeking = true; });
    connect(m_seekSlider, &QSlider::sliderReleased, this, [this] {
        m_userIsSeeking = false;
        m_player->seek(m_seekSlider->value());
    });
    connect(m_seekSlider, &QSlider::sliderMoved, this, [this](int value) {
        m_currentTimeLabel->setText(formatTimecode(value));
    });

    // --- Frame strip & timeline ---
    connect(m_frameStrip, &FrameStripWidget::seekRequested, this, [this](qint64 ms) {
        m_player->seek(ms);
    });
    connect(m_timeline, &TimelineWidget::seekRequested, this, [this](qint64 ms) {
        m_player->seek(ms);
    });
    connect(m_timeline, &TimelineWidget::draftDragStarted, this, &MainWindow::pushUndoSnapshot);
    connect(m_timeline, &TimelineWidget::draftEdited, this, [this](SegmentType type,
                                                                  const SegmentDraft &draft) {
        // A drag already pushed one snapshot at draftDragStarted; recording per
        // mouse-move would make undo step through every pixel of the drag.
        m_drafts.insert(static_cast<int>(type), draft);
        m_sidebar->setDrafts(m_drafts);
    });
    connect(m_timeline, &TimelineWidget::zoomChanged, this, [this](double zoom) {
        QSignalBlocker blocker(m_zoomSlider);
        m_zoomSlider->setValue(static_cast<int>(zoom * 10));
        m_zoomLabel->setText(QStringLiteral("%1x").arg(zoom, 0, 'f', 1));
    });
}

void MainWindow::loadStoredKeys()
{
    CredentialStore &store = CredentialStore::instance();
    m_sidebar->setApiKeys(store.read(CredentialStore::kTheIntroDbToken),
                          store.read(CredentialStore::kIntroDbApiKey),
                          store.read(CredentialStore::kTmdbApiKey));

    m_sidebar->setLookupHint(m_sidebar->tmdbKey().isEmpty()
                                 ? tr("TMDB Key missing. Fill key to lookup.")
                                 : QString());
}

// MARK: - Status

void MainWindow::setStatus(const QString &message, const QColor &colour)
{
    m_statusLabel->setText(message);
    m_statusLabel->setStyleSheet(QStringLiteral("color: %1; font-weight: 500;").arg(colour.name()));
}

void MainWindow::setStatusInfo(const QString &message)
{
    setStatus(message, theme::color::textMuted);
}

void MainWindow::setStatusSuccess(const QString &message)
{
    setStatus(message, theme::color::statusSuccess);
}

void MainWindow::setStatusError(const QString &message)
{
    setStatus(message, theme::color::statusError);
    LoggerService::instance().error(message);
}

// MARK: - Video

void MainWindow::onOpenVideo()
{
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Open Video"),
        m_videoPath.isEmpty() ? QString() : QFileInfo(m_videoPath).absolutePath(),
        tr("Video files (*.mp4 *.mkv *.avi *.mov *.webm *.m4v);;All files (*)"));

    if (!path.isEmpty()) {
        loadVideo(path);
    }
}

void MainWindow::openVideo(const QString &filePath)
{
    if (!QFileInfo::exists(filePath)) {
        setStatusError(tr("File not found: %1").arg(filePath));
        return;
    }
    loadVideo(filePath);
}

void MainWindow::loadVideo(const QString &filePath)
{
    m_videoPath = filePath;
    const QString fileName = QFileInfo(filePath).fileName();

    m_sidebar->setVideoName(fileName);

    // Reset per-file state so drafts from the previous video cannot be uploaded
    // against this one.
    m_drafts.clear();
    m_undoStack.clear();
    m_redoStack.clear();
    m_pendingRcdMatches.clear();
    refreshDrafts();

    if (const auto info = FFmpegService::instance().inspectMedia(filePath)) {
        m_frameRate = info->frameRate;
        m_durationMs = info->durationMs;
        m_player->setFrameRate(info->frameRate);
    }

    if (!m_player->load(filePath)) {
        setStatusError(tr("Failed to load %1").arg(fileName));
        return;
    }

    m_frameStrip->setVideo(filePath, m_frameRate, m_durationMs);
    m_timeline->setDurationMs(m_durationMs);

    // Pre-fill the identification fields from the filename; the user corrects
    // it from the lookup results when the guess is wrong.
    const ParsedFilenameHint hint = FilenameMediaParser::parse(filePath);
    m_sidebar->setMediaType(hint.mediaTypeHint());
    m_sidebar->setSeasonEpisode(hint.season, hint.episode);

    const QString tmdbKey = m_sidebar->tmdbKey();
    if (!tmdbKey.isEmpty() && !hint.title.isEmpty()) {
        m_sidebar->setLookupHint(QString());

        auto *watcher = new QFutureWatcher<QVector<AutoLookupResult>>(this);
        connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
            m_lookupResults = watcher->result();
            watcher->deleteLater();
            m_sidebar->setLookupResults(m_lookupResults);
            if (m_lookupResults.isEmpty()) {
                setStatusInfo(tr("No TMDB match for this filename — search manually."));
            }
        });
        watcher->setFuture(QtConcurrent::run([hint, tmdbKey] {
            return TmdbClient::instance().resolveHints(hint, tmdbKey);
        }));
    } else if (tmdbKey.isEmpty()) {
        m_sidebar->setLookupHint(tr("TMDB Key missing. Fill key to lookup."));
    }

    startAudioAnalysis();
    setStatusSuccess(tr("Loaded %1").arg(fileName));
}

void MainWindow::startAudioAnalysis()
{
    if (m_videoPath.isEmpty() || !FFmpegService::instance().hasBinaries()) {
        return;
    }

    const QString path = m_videoPath;
    const int durationMs = static_cast<int>(m_durationMs);

    auto *watcher = new QFutureWatcher<AudioExtractorService::Result>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        const AudioExtractorService::Result result = watcher->result();
        watcher->deleteLater();

        if (!result.isValid()) {
            return;
        }

        TimelineDensityTrack track;
        track.label = tr("Audio");
        track.buckets = result.waveformBuckets;
        track.musicLikelihoodBuckets = result.musicLikelihoodBuckets;
        m_timeline->setDensityTrack(track);
    });

    watcher->setFuture(QtConcurrent::run([path, durationMs] {
        return AudioExtractorService::instance().analyze(path, durationMs);
    }));
}

// MARK: - Player callbacks

void MainWindow::onPlayerTimeChanged(qint64 milliseconds)
{
    m_playheadMs = milliseconds;
    m_currentTimeLabel->setText(formatTimecode(static_cast<int>(milliseconds)));
    m_timeline->setPlayheadMs(milliseconds);
    m_frameStrip->setPlayheadMs(milliseconds);

    if (!m_userIsSeeking) {
        QSignalBlocker blocker(m_seekSlider);
        m_seekSlider->setValue(static_cast<int>(milliseconds));
    }
}

void MainWindow::onPlayerDurationChanged(qint64 milliseconds)
{
    m_durationMs = milliseconds;
    m_durationLabel->setText(formatTimecode(static_cast<int>(milliseconds)));
    m_seekSlider->setRange(0, static_cast<int>(milliseconds));
    m_timeline->setDurationMs(milliseconds);

    // Matches that arrived before the duration was known are clamped against
    // it, so they could not be applied until now.
    if (!m_pendingRcdMatches.isEmpty()) {
        const QVector<RcdMatch> pending = m_pendingRcdMatches;
        m_pendingRcdMatches.clear();

        pushUndoSnapshot();
        for (const RcdMatch &match : pending) {
            SegmentDraft draft;
            draft.startMs = static_cast<int>(match.startSec * 1000.0);
            draft.endMs = static_cast<int>(
                std::min<double>(match.endSec * 1000.0, static_cast<double>(milliseconds)));
            m_drafts.insert(static_cast<int>(match.type), draft);
        }
        refreshDrafts();
    }
}

void MainWindow::onPlayingStateChanged(bool playing)
{
    m_playButton->setText(playing ? QStringLiteral("⏸") : QStringLiteral("▶"));
}

// MARK: - Drafts

void MainWindow::refreshDrafts()
{
    m_sidebar->setDrafts(m_drafts);
    m_timeline->setDrafts(m_drafts);
}

void MainWindow::pushUndoSnapshot()
{
    m_undoStack.append(m_drafts);
    if (m_undoStack.size() > kMaxUndoDepth) {
        m_undoStack.removeFirst();
    }
    // Any new edit invalidates the redo branch.
    m_redoStack.clear();
}

void MainWindow::undo()
{
    if (m_undoStack.isEmpty()) {
        return;
    }
    m_redoStack.append(m_drafts);
    m_drafts = m_undoStack.takeLast();
    refreshDrafts();
    setStatusInfo(tr("Undo"));
}

void MainWindow::redo()
{
    if (m_redoStack.isEmpty()) {
        return;
    }
    m_undoStack.append(m_drafts);
    m_drafts = m_redoStack.takeLast();
    refreshDrafts();
    setStatusInfo(tr("Redo"));
}

void MainWindow::onDraftEdited(SegmentType type, const SegmentDraft &draft)
{
    pushUndoSnapshot();
    m_drafts.insert(static_cast<int>(type), draft);
    refreshDrafts();
}

void MainWindow::onClearDraft(SegmentType type)
{
    pushUndoSnapshot();
    m_drafts.remove(static_cast<int>(type));
    refreshDrafts();
    setStatusInfo(tr("Cleared %1 draft").arg(segmentTypeDisplayName(type)));
}

void MainWindow::onSetStartFromPlayhead(SegmentType type)
{
    pushUndoSnapshot();
    SegmentDraft draft = m_drafts.value(static_cast<int>(type));
    draft.startMs = static_cast<int>(m_playheadMs);
    m_drafts.insert(static_cast<int>(type), draft);
    refreshDrafts();
}

void MainWindow::onSetEndFromPlayhead(SegmentType type)
{
    pushUndoSnapshot();
    SegmentDraft draft = m_drafts.value(static_cast<int>(type));
    draft.endMs = static_cast<int>(m_playheadMs);
    m_drafts.insert(static_cast<int>(type), draft);
    refreshDrafts();
}

// MARK: - Identification

void MainWindow::onSaveKeys()
{
    CredentialStore &store = CredentialStore::instance();
    const bool ok = store.write(CredentialStore::kTheIntroDbToken, m_sidebar->theIntroDbKey())
                  && store.write(CredentialStore::kIntroDbApiKey, m_sidebar->introDbKey())
                  && store.write(CredentialStore::kTmdbApiKey, m_sidebar->tmdbKey());

    if (ok) {
        setStatusSuccess(tr("API keys saved to Windows Credential Manager"));
        m_sidebar->setLookupHint(m_sidebar->tmdbKey().isEmpty()
                                     ? tr("TMDB Key missing. Fill key to lookup.")
                                     : QString());
    } else {
        setStatusError(tr("Could not save one or more API keys"));
    }
}

void MainWindow::onSearchTmdb(const QString &query)
{
    const QString tmdbKey = m_sidebar->tmdbKey();
    if (tmdbKey.isEmpty()) {
        setStatusError(tr("TMDB API key is required to search"));
        return;
    }

    const MediaType mediaType = m_sidebar->mediaType();
    setStatusInfo(tr("Searching TMDB for \"%1\"...").arg(query));

    auto *watcher = new QFutureWatcher<QVector<AutoLookupResult>>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        m_lookupResults = watcher->result();
        watcher->deleteLater();

        m_sidebar->setLookupResults(m_lookupResults);
        if (m_lookupResults.isEmpty()) {
            setStatusError(tr("No TMDB results"));
        } else {
            setStatusSuccess(tr("Found %1 result(s)").arg(m_lookupResults.size()));
        }
    });

    watcher->setFuture(QtConcurrent::run([query, mediaType, tmdbKey] {
        return TmdbClient::instance().searchByTitle(query, mediaType, tmdbKey);
    }));
}

void MainWindow::onLookupResultSelected(int index)
{
    if (index < 0 || index >= m_lookupResults.size()) {
        return;
    }

    const AutoLookupResult &result = m_lookupResults.at(index);
    m_sidebar->setTmdbId(QString::number(result.tmdbId));
    m_sidebar->setImdbId(result.imdbId);
    m_sidebar->setMediaType(result.mediaType);
    if (result.season.has_value() || result.episode.has_value()) {
        m_sidebar->setSeasonEpisode(result.season, result.episode);
    }
}

void MainWindow::onLoadSegments()
{
    MediaQuery query;
    bool ok = false;
    const int tmdbId = m_sidebar->tmdbId().toInt(&ok);
    if (ok && tmdbId > 0) {
        query.tmdbId = tmdbId;
    }
    query.imdbId = m_sidebar->imdbId();
    query.season = m_sidebar->season();
    query.episode = m_sidebar->episode();
    if (m_durationMs > 0) {
        query.durationMs = static_cast<int>(m_durationMs);
    }

    if (!query.tmdbId.has_value() && query.imdbId.isEmpty()) {
        setStatusError(tr("Enter a TMDB ID or IMDB ID first"));
        return;
    }

    const QString apiKey = m_sidebar->theIntroDbKey();
    setStatusInfo(tr("Loading segments from TheIntroDB..."));

    auto *watcher = new QFutureWatcher<ApiResponse>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        const ApiResponse response = watcher->result();
        watcher->deleteLater();

        if (!response.usage.shortDescription().isEmpty()) {
            m_usageLabel->setText(response.usage.shortDescription());
        }

        if (!response.ok) {
            setStatusError(tr("Load failed: %1").arg(response.error));
            return;
        }

        const QJsonArray segments = response.json.value(QStringLiteral("segments")).toArray();
        if (segments.isEmpty()) {
            setStatusInfo(tr("No segments recorded for this title yet"));
            return;
        }

        pushUndoSnapshot();
        int applied = 0;
        for (const QJsonValue &value : segments) {
            const QJsonObject segment = value.toObject();
            const auto type = segmentTypeFromApiValue(
                segment.value(QStringLiteral("segment")).toString());
            if (!type.has_value()) {
                continue;
            }

            SegmentDraft draft;
            if (segment.contains(QStringLiteral("start_ms"))) {
                draft.startMs = segment.value(QStringLiteral("start_ms")).toInt();
            }
            const QJsonValue endValue = segment.value(QStringLiteral("end_ms"));
            if (!endValue.isNull() && endValue.isDouble()) {
                draft.endMs = endValue.toInt();
            }

            m_drafts.insert(static_cast<int>(*type), draft);
            ++applied;
        }

        refreshDrafts();
        setStatusSuccess(tr("Loaded %1 segment(s)").arg(applied));
    });

    watcher->setFuture(QtConcurrent::run([query, apiKey] {
        return TheIntroDbClient::instance().fetchMedia(query, apiKey);
    }));
}

// MARK: - Upload

bool MainWindow::makeSubmissionDraft(SegmentType type, SubmissionDraft *out, QString *error) const
{
    const auto it = m_drafts.constFind(static_cast<int>(type));
    if (it == m_drafts.constEnd() || it->isEmpty()) {
        *error = tr("%1 has no draft").arg(segmentTypeDisplayName(type));
        return false;
    }

    bool ok = false;
    const int tmdbId = m_sidebar->tmdbId().toInt(&ok);

    out->tmdbId = ok ? tmdbId : 0;
    out->imdbId = m_sidebar->imdbId();
    out->mediaType = m_sidebar->mediaType();
    out->segment = type;
    out->season = m_sidebar->season();
    out->episode = m_sidebar->episode();
    out->startMs = it->startMs;
    out->endMs = it->endMs;
    if (m_durationMs > 0) {
        out->videoDurationMs = static_cast<int>(m_durationMs);
    }

    if (out->tmdbId <= 0 && out->imdbId.isEmpty()) {
        *error = tr("Set a TMDB ID or IMDB ID before uploading");
        return false;
    }
    return true;
}

void MainWindow::onUploadSegment(SegmentType type)
{
    const QString apiKey = m_sidebar->theIntroDbKey();
    if (apiKey.isEmpty()) {
        setStatusError(tr("TheIntroDB API key is required to upload"));
        return;
    }

    SubmissionDraft submission;
    QString error;
    if (!makeSubmissionDraft(type, &submission, &error)) {
        setStatusError(error);
        return;
    }

    QJsonObject payload;
    try {
        payload = SegmentValidator::makeTheIntroDbSubmissionRequest(submission);
    } catch (const SegmentValidationError &validationError) {
        setStatusError(validationError.message());
        return;
    }

    setStatusInfo(tr("Uploading %1...").arg(segmentTypeDisplayName(type)));

    auto *watcher = new QFutureWatcher<ApiResponse>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher, type] {
        const ApiResponse response = watcher->result();
        watcher->deleteLater();

        if (!response.usage.shortDescription().isEmpty()) {
            m_usageLabel->setText(response.usage.shortDescription());
        }

        if (response.ok) {
            setStatusSuccess(tr("Uploaded %1").arg(segmentTypeDisplayName(type)));
        } else {
            setStatusError(tr("Upload of %1 failed: %2")
                               .arg(segmentTypeDisplayName(type), response.error));
        }
    });

    watcher->setFuture(QtConcurrent::run([payload, apiKey] {
        return TheIntroDbClient::instance().submit(payload, apiKey);
    }));
}

void MainWindow::onUploadAll()
{
    QVector<SegmentType> pending;
    for (const SegmentType type : allSegmentTypes()) {
        const auto it = m_drafts.constFind(static_cast<int>(type));
        if (it != m_drafts.constEnd() && !it->isEmpty()) {
            pending.append(type);
        }
    }

    if (pending.isEmpty()) {
        setStatusError(tr("No drafts to upload"));
        return;
    }

    // Uploading is an outward-facing, hard-to-undo action against a shared
    // public database, so it gets a confirmation naming exactly what will go.
    QStringList names;
    for (const SegmentType type : pending) {
        names << segmentTypeDisplayName(type);
    }

    const auto answer = QMessageBox::question(
        this, tr("Upload all drafts"),
        tr("Submit %1 segment(s) to TheIntroDB?\n\n%2")
            .arg(pending.size()).arg(names.join(QStringLiteral(", "))),
        QMessageBox::Yes | QMessageBox::No, QMessageBox::No);

    if (answer != QMessageBox::Yes) {
        return;
    }

    for (const SegmentType type : pending) {
        onUploadSegment(type);
    }
}

// MARK: - RCD

void MainWindow::onScanSeason()
{
    RcdScanDialog dialog(this);
    dialog.setInitialSource(m_videoPath);

    if (dialog.exec() != QDialog::Accepted) {
        return;
    }

    applyRcdMatches(dialog.results());
}

void MainWindow::applyRcdMatches(const QHash<QString, QVector<RcdMatch>> &results)
{
    if (m_videoPath.isEmpty()) {
        setStatusInfo(tr("Scan complete. Open a video from the scanned set to see its segments."));
        return;
    }

    const QString currentName = QFileInfo(m_videoPath).fileName();
    const auto it = results.constFind(currentName);
    if (it == results.constEnd() || it->isEmpty()) {
        setStatusInfo(tr("Scan complete — no segments found for %1").arg(currentName));
        return;
    }

    // Without a duration the end of an open-ended credits match cannot be
    // clamped; hold them until the player reports one.
    if (m_durationMs <= 0) {
        m_pendingRcdMatches = *it;
        return;
    }

    pushUndoSnapshot();
    for (const RcdMatch &match : *it) {
        SegmentDraft draft;
        draft.startMs = static_cast<int>(match.startSec * 1000.0);
        draft.endMs = static_cast<int>(
            std::min<double>(match.endSec * 1000.0, static_cast<double>(m_durationMs)));
        m_drafts.insert(static_cast<int>(match.type), draft);
    }
    refreshDrafts();

    setStatusSuccess(tr("Applied %1 detected segment(s) to %2").arg(it->size()).arg(currentName));
}

// MARK: - Keyboard

void MainWindow::keyPressEvent(QKeyEvent *event)
{
    // Typing in a text field must not trigger playback shortcuts.
    if (auto *focused = QApplication::focusWidget()) {
        if (focused->inherits("QLineEdit") || focused->inherits("QPlainTextEdit")
            || focused->inherits("QTextEdit") || focused->inherits("QAbstractSpinBox")) {
            if (event->key() == Qt::Key_Escape || event->key() == Qt::Key_Return
                || event->key() == Qt::Key_Enter) {
                focused->clearFocus();
                setFocus();
                event->accept();
                return;
            }
            QMainWindow::keyPressEvent(event);
            return;
        }
    }

    const bool shift = event->modifiers().testFlag(Qt::ShiftModifier);
    const bool control = event->modifiers().testFlag(Qt::ControlModifier);

    if (control && event->key() == Qt::Key_Z) {
        shift ? redo() : undo();
        event->accept();
        return;
    }
    if (control && event->key() == Qt::Key_Y) {
        redo();
        event->accept();
        return;
    }

    const auto markSegment = [this, shift](SegmentType type) {
        shift ? onSetEndFromPlayhead(type) : onSetStartFromPlayhead(type);
    };

    switch (event->key()) {
    case Qt::Key_Space:
        m_player->togglePlayPause();
        break;
    case Qt::Key_Left:
    case Qt::Key_Comma:
        m_player->stepFrame(-1);
        break;
    case Qt::Key_Right:
    case Qt::Key_Period:
        m_player->stepFrame(1);
        break;
    case Qt::Key_I:
        markSegment(SegmentType::Intro);
        break;
    case Qt::Key_R:
        markSegment(SegmentType::Recap);
        break;
    case Qt::Key_C:
        markSegment(SegmentType::Credits);
        break;
    case Qt::Key_P:
        markSegment(SegmentType::Preview);
        break;
    default:
        QMainWindow::keyPressEvent(event);
        return;
    }

    event->accept();
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    bool hasDrafts = false;
    for (const SegmentDraft &draft : std::as_const(m_drafts)) {
        if (!draft.isEmpty()) {
            hasDrafts = true;
            break;
        }
    }

    if (hasDrafts) {
        const auto answer = QMessageBox::question(
            this, tr("Unsaved drafts"),
            tr("You have segment drafts that have not been uploaded. Quit anyway?"),
            QMessageBox::Yes | QMessageBox::No, QMessageBox::No);
        if (answer != QMessageBox::Yes) {
            event->ignore();
            return;
        }
    }

    event->accept();
}

} // namespace segmenter
