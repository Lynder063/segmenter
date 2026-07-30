#pragma once

#include <QImage>
#include <QMutex>
#include <QString>
#include <QWidget>

struct libvlc_instance_t;
struct libvlc_media_player_t;
class QTimer;

namespace segmenter {

/// LibVLC playback surface.
///
/// On Windows, VLC renders straight into this widget's native HWND — zero
/// copy, DirectX hardware decoding underneath.
///
/// On Linux this instead uses LibVLC's raw video callbacks
/// (libvlc_video_set_callbacks): VLC has no public embedding API for Wayland
/// surfaces the way it does for X11 windows (libvlc_media_player_set_xwindow)
/// or Win32 HWNDs, and the project targets Wayland rather than falling back
/// to XWayland. Decoded frames land in a plain RGB32 buffer that this widget
/// paints itself, which works identically under X11 and Wayland because it
/// never asks LibVLC to own a window at all. Hardware *decode* is unaffected
/// (--avcodec-hw=any in VlcVideoPlayer.cpp); only the final blit to screen
/// becomes a CPU copy instead of direct scanout, which a timestamp-annotation
/// tool built around frame-by-frame stepping is not sensitive to the way a
/// general-purpose player would be.
class VlcVideoPlayer : public QWidget {
    Q_OBJECT

public:
    explicit VlcVideoPlayer(QWidget *parent = nullptr);
    ~VlcVideoPlayer() override;

    bool isAvailable() const { return m_instance != nullptr; }

    /// Creates the LibVLC instance if it does not exist yet.
    ///
    /// This is deliberately not done in the constructor: on the first run after
    /// a build, libvlc_new() spends ~20 s rebuilding its plugin cache, and
    /// doing that before the window is shown leaves the user staring at nothing
    /// with no way to tell the app from a hung one.
    void ensureEngine();

    bool load(const QString &filePath);
    void unload();

    void play();
    void pause();
    void togglePlayPause();
    bool isPlaying() const;

    qint64 timeMs() const;
    qint64 durationMs() const;
    void seek(qint64 milliseconds);

    /// Steps one frame in either direction. VLC only offers a native
    /// next-frame; stepping back is a seek by one frame duration, which is why
    /// it needs the frame rate the caller resolved via ffprobe.
    void stepFrame(int direction);

    void setFrameRate(double fps);
    double frameRate() const { return m_frameRate; }

    void setVolume(int volume);
    int volume() const;
    void setMuted(bool muted);
    bool isMuted() const;

signals:
    /// Raised around the blocking libvlc_new() call so the window can say what
    /// it is waiting on.
    void engineInitializing();
    void engineReady(const QString &version);

    void timeChanged(qint64 milliseconds);
    void durationChanged(qint64 milliseconds);
    void playingStateChanged(bool playing);
    void errorOccurred(const QString &message);

protected:
#ifdef Q_OS_WIN
    // The widget owns a native window that VLC draws into, so Qt must not
    // paint over it or try to composite it.
    QPaintEngine *paintEngine() const override { return nullptr; }
#else
    // Linux paints the frame LibVLC's callbacks deposit into m_frontBuffer —
    // see the class comment above for why.
    void paintEvent(QPaintEvent *event) override;
#endif

private:
    void pollState();

#ifndef Q_OS_WIN
    static unsigned formatCallback(void **opaque, char *chroma,
                                    unsigned *width, unsigned *height,
                                    unsigned *pitches, unsigned *lines);
    static void *lockCallback(void *opaque, void **planes);
    static void unlockCallback(void *opaque, void *picture, void *const *planes);
    static void displayCallback(void *opaque, void *picture);

    // Written by lockCallback/unlockCallback on LibVLC's decode thread,
    // swapped into m_frontBuffer by displayCallback (also LibVLC's thread)
    // and read by paintEvent on the GUI thread — m_frameMutex guards every
    // access to either image from any thread.
    QMutex m_frameMutex;
    QImage m_backBuffer;
    QImage m_frontBuffer;
#endif

    libvlc_instance_t *m_instance = nullptr;
    libvlc_media_player_t *m_player = nullptr;

    QTimer *m_pollTimer = nullptr;

    // Polled rather than driven by libvlc events: VLC fires its callbacks on
    // its own threads, and marshalling every one into the GUI thread costs more
    // than a 5 ms timer that reads three integers.
    qint64 m_lastTimeMs = -1;
    qint64 m_lastDurationMs = -1;
    bool m_lastPlaying = false;

    double m_frameRate = 23.976;
};

} // namespace segmenter
