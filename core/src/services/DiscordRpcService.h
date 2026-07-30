#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>

class QLocalSocket;
class QTimer;

namespace segmenter {

/// Discord Rich Presence over Discord's local IPC protocol — a length-
/// prefixed JSON frame protocol spoken over a Unix domain socket on Linux
/// and a named pipe on Windows. QLocalSocket abstracts that transport
/// difference away, so this one file is all either platform needs.
///
/// Entirely optional and silently inert without a client ID. The ID is baked
/// in from a git-ignored .env at CMake configure time (see
/// core/CMakeLists.txt and .env.example at the repo root) specifically so the
/// maintainer's own Discord application ID never has to appear in the public
/// repository. No .env, no ID, no RPC — every other checkout of this repo
/// just runs without it.
class DiscordRpcService : public QObject {
    Q_OBJECT

public:
    static DiscordRpcService &instance();

    bool isEnabled() const { return !clientId().isEmpty(); }

    void setIdle();
    void setVideoLoaded(const QString &videoName, const QString &formattedShowName = QString());
    void setPlaying(const QString &videoName, qint64 positionMs, qint64 durationMs,
                     const QString &formattedShowName = QString());
    void setPaused(const QString &videoName, qint64 positionMs, qint64 durationMs,
                    const QString &formattedShowName = QString());
    void setAnalyzing(const QString &videoName);

    /// Clears the presence rather than leaving a stale one showing after the
    /// app quits. Safe to call even when disabled or never connected.
    void clear();

private:
    DiscordRpcService();
    ~DiscordRpcService() override;
    Q_DISABLE_COPY(DiscordRpcService)

    static QString clientId();

    QJsonObject buildActivity(const QString &details, const QString &state,
                               const QString &largeImageText, qint64 startEpochSec,
                               qint64 endEpochSec) const;

    void connectToDiscord();
    void scheduleReconnect();
    void sendHandshake();
    void writeFrame(int opcode, const QJsonObject &payload);
    void queueActivity(const QJsonObject &activity);
    void flushQueuedActivity();

    void onConnected();
    void onDisconnected();
    void onErrorOccurred();
    void onReadyRead();

    QLocalSocket *m_socket = nullptr;
    QTimer *m_debounceTimer = nullptr;
    QTimer *m_reconnectTimer = nullptr;
    QByteArray m_readBuffer;

    bool m_handshakeAcked = false;
    int m_nextPipeIndex = 0;

    QJsonObject m_queuedActivity;
    bool m_hasQueuedActivity = false;

    qint64 m_sessionStartEpochSec = 0;
};

} // namespace segmenter
