#include "views/VlcVideoPlayer.h"

#include <QCoreApplication>
#include <QDir>
#include <QPalette>
#include <QTimer>

#include <vlc/vlc.h>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

/// 5 ms keeps the displayed timecode inside one millisecond of the truth at
/// normal playback speed, which is what makes frame-accurate marking possible.
constexpr int kPollIntervalMs = 5;

} // namespace

VlcVideoPlayer::VlcVideoPlayer(QWidget *parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("videoStage"));
    setAttribute(Qt::WA_NativeWindow);
    setAttribute(Qt::WA_DontCreateNativeAncestors);
    setAttribute(Qt::WA_OpaquePaintEvent);
    setAutoFillBackground(true);

    QPalette blackPalette = palette();
    blackPalette.setColor(QPalette::Window, Qt::black);
    setPalette(blackPalette);

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(kPollIntervalMs);
    connect(m_pollTimer, &QTimer::timeout, this, &VlcVideoPlayer::pollState);

    // Start the engine once the event loop is running, so the window is painted
    // and interactive before the blocking plugin-cache build begins.
    QTimer::singleShot(0, this, &VlcVideoPlayer::ensureEngine);
}

void VlcVideoPlayer::ensureEngine()
{
    if (m_instance != nullptr) {
        return;
    }

    emit engineInitializing();

    // --no-video-title-show suppresses the filename overlay VLC draws over the
    // first seconds of playback, which sits exactly where a title card would.
    const char *args[] = {
        "--intf", "dummy",
        "--no-video-title-show",
        "--no-snapshot-preview",
        "--quiet",
        "--no-stats",
        "--avcodec-hw=any",
    };

    m_instance = libvlc_new(static_cast<int>(std::size(args)), args);
    if (m_instance == nullptr) {
        LoggerService::instance().error(
            QStringLiteral("[VlcVideoPlayer] libvlc_new failed — is the plugins folder present?"));
        return;
    }

    m_player = libvlc_media_player_new(m_instance);
    if (m_player == nullptr) {
        LoggerService::instance().error(
            QStringLiteral("[VlcVideoPlayer] libvlc_media_player_new failed"));
        return;
    }

    libvlc_media_player_set_hwnd(m_player, reinterpret_cast<void *>(winId()));

    m_pollTimer->start();

    const QString version = QString::fromLatin1(libvlc_get_version());
    LoggerService::instance().info(
        QStringLiteral("[VlcVideoPlayer] LibVLC %1 ready").arg(version));
    emit engineReady(version);
}

VlcVideoPlayer::~VlcVideoPlayer()
{
    if (m_pollTimer != nullptr) {
        m_pollTimer->stop();
    }
    if (m_player != nullptr) {
        libvlc_media_player_stop(m_player);
        libvlc_media_player_release(m_player);
        m_player = nullptr;
    }
    if (m_instance != nullptr) {
        libvlc_release(m_instance);
        m_instance = nullptr;
    }
}

bool VlcVideoPlayer::load(const QString &filePath)
{
    // A file passed on the command line can arrive before the deferred
    // initialisation has run.
    ensureEngine();

    if (m_player == nullptr || m_instance == nullptr) {
        emit errorOccurred(tr("Video engine unavailable — check that libvlc.dll "
                              "and the plugins folder sit next to Segmenter.exe"));
        return false;
    }

    libvlc_media_t *media = libvlc_media_new_path(
        m_instance, QDir::toNativeSeparators(filePath).toUtf8().constData());
    if (media == nullptr) {
        emit errorOccurred(tr("Could not open %1").arg(filePath));
        return false;
    }

    libvlc_media_player_set_media(m_player, media);
    libvlc_media_release(media);

    // Reset the change-detection state so the first poll after loading always
    // reports the new duration and a zeroed playhead.
    m_lastTimeMs = -1;
    m_lastDurationMs = -1;
    m_lastPlaying = false;

    // Play then immediately pause: VLC will not report a duration or render a
    // first frame until the demuxer has actually started, so a file loaded but
    // never played would otherwise show a black pane and a 00:00 duration.
    libvlc_media_player_play(m_player);
    QTimer::singleShot(220, this, [this] {
        if (m_player != nullptr) {
            libvlc_media_player_set_pause(m_player, 1);
            libvlc_media_player_set_time(m_player, 0);
        }
    });

    LoggerService::instance().info(
        QStringLiteral("[VlcVideoPlayer] loaded %1").arg(filePath));
    return true;
}

void VlcVideoPlayer::unload()
{
    if (m_player != nullptr) {
        libvlc_media_player_stop(m_player);
    }
    m_lastTimeMs = -1;
    m_lastDurationMs = -1;
}

void VlcVideoPlayer::play()
{
    if (m_player != nullptr) {
        libvlc_media_player_play(m_player);
    }
}

void VlcVideoPlayer::pause()
{
    if (m_player != nullptr) {
        libvlc_media_player_set_pause(m_player, 1);
    }
}

void VlcVideoPlayer::togglePlayPause()
{
    if (m_player != nullptr) {
        libvlc_media_player_pause(m_player);
    }
}

bool VlcVideoPlayer::isPlaying() const
{
    return m_player != nullptr && libvlc_media_player_is_playing(m_player) != 0;
}

qint64 VlcVideoPlayer::timeMs() const
{
    if (m_player == nullptr) {
        return 0;
    }
    return std::max<qint64>(0, libvlc_media_player_get_time(m_player));
}

qint64 VlcVideoPlayer::durationMs() const
{
    if (m_player == nullptr) {
        return 0;
    }
    return std::max<qint64>(0, libvlc_media_player_get_length(m_player));
}

void VlcVideoPlayer::seek(qint64 milliseconds)
{
    if (m_player == nullptr) {
        return;
    }
    libvlc_media_player_set_time(m_player, std::max<qint64>(0, milliseconds));
}

void VlcVideoPlayer::setFrameRate(double fps)
{
    if (fps > 0.0) {
        m_frameRate = fps;
    }
}

void VlcVideoPlayer::stepFrame(int direction)
{
    if (m_player == nullptr) {
        return;
    }

    // Stepping only makes sense against a still image; leaving playback running
    // would have the frame move on before the user saw it.
    if (isPlaying()) {
        pause();
    }

    if (direction > 0) {
        // VLC decodes and displays exactly the next frame, which is more
        // accurate than seeking by a computed frame duration.
        libvlc_media_player_next_frame(m_player);
        return;
    }

    const qint64 frameMs = static_cast<qint64>(std::llround(1000.0 / m_frameRate));
    seek(std::max<qint64>(0, timeMs() - frameMs));
}

void VlcVideoPlayer::setVolume(int volume)
{
    if (m_player != nullptr) {
        libvlc_audio_set_volume(m_player, std::clamp(volume, 0, 100));
    }
}

int VlcVideoPlayer::volume() const
{
    return m_player != nullptr ? libvlc_audio_get_volume(m_player) : 0;
}

void VlcVideoPlayer::setMuted(bool muted)
{
    if (m_player != nullptr) {
        libvlc_audio_set_mute(m_player, muted ? 1 : 0);
    }
}

bool VlcVideoPlayer::isMuted() const
{
    return m_player != nullptr && libvlc_audio_get_mute(m_player) == 1;
}

void VlcVideoPlayer::pollState()
{
    if (m_player == nullptr) {
        return;
    }

    const qint64 time = timeMs();
    if (time != m_lastTimeMs) {
        m_lastTimeMs = time;
        emit timeChanged(time);
    }

    const qint64 duration = durationMs();
    if (duration != m_lastDurationMs && duration > 0) {
        m_lastDurationMs = duration;
        emit durationChanged(duration);
    }

    const bool playing = isPlaying();
    if (playing != m_lastPlaying) {
        m_lastPlaying = playing;
        emit playingStateChanged(playing);
    }
}

} // namespace segmenter
