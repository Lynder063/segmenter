#include "services/DiscordRpcService.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QProcessEnvironment>
#include <QTimer>
#include <QUuid>
#include <QtEndian>

#include <algorithm>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

constexpr int kHandshakeOp = 0;
constexpr int kFrameOp = 1;
constexpr int kCloseOp = 2;

constexpr int kDebounceMs = 500;
constexpr int kReconnectMs = 15000;
// Discord (and anything else speaking this protocol, e.g. a second instance)
// takes pipe 0, 1, 2... in order, so a fixed handful of attempts is enough —
// there is no discovery mechanism, just probing.
constexpr int kPipeAttempts = 10;

QString ipcSocketPath(int index)
{
#ifdef Q_OS_WIN
    return QStringLiteral("\\\\.\\pipe\\discord-ipc-%1").arg(index);
#else
    // The same base-directory lookup order Discord's own clients use.
    const QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    QString base = env.value(QStringLiteral("XDG_RUNTIME_DIR"));
    if (base.isEmpty()) {
        base = env.value(QStringLiteral("TMPDIR"));
    }
    if (base.isEmpty()) {
        base = env.value(QStringLiteral("TMP"));
    }
    if (base.isEmpty()) {
        base = env.value(QStringLiteral("TEMP"));
    }
    if (base.isEmpty()) {
        base = QStringLiteral("/tmp");
    }
    return QDir(base).filePath(QStringLiteral("discord-ipc-%1").arg(index));
#endif
}

QString truncateName(QString name, int maxLen)
{
    if (name.isEmpty()) {
        return name;
    }
    const int sepIdx = std::max(name.lastIndexOf(QLatin1Char('/')), name.lastIndexOf(QLatin1Char('\\')));
    if (sepIdx >= 0) {
        name = name.mid(sepIdx + 1);
    }
    const int dotIdx = name.lastIndexOf(QLatin1Char('.'));
    if (dotIdx > 0) {
        name = name.left(dotIdx);
    }
    if (name.length() > maxLen) {
        name = name.left(maxLen) + QStringLiteral("…");
    }
    return name;
}

QString formatDuration(qint64 ms)
{
    const qint64 totalSec = ms / 1000;
    const qint64 h = totalSec / 3600;
    const qint64 m = (totalSec % 3600) / 60;
    const qint64 s = totalSec % 60;
    if (h > 0) {
        return QStringLiteral("%1:%2:%3").arg(h).arg(m, 2, 10, QLatin1Char('0')).arg(s, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2").arg(m).arg(s, 2, 10, QLatin1Char('0'));
}

} // namespace

DiscordRpcService &DiscordRpcService::instance()
{
    static DiscordRpcService service;
    return service;
}

QString DiscordRpcService::clientId()
{
#ifdef SEGMENTER_DISCORD_CLIENT_ID
    return QStringLiteral(SEGMENTER_DISCORD_CLIENT_ID);
#else
    return QString();
#endif
}

DiscordRpcService::DiscordRpcService()
{
    if (!isEnabled()) {
        // No .env at build time — the default for every checkout but the
        // maintainer's own, so this stays quiet rather than warning.
        return;
    }

    m_sessionStartEpochSec = QDateTime::currentSecsSinceEpoch();

    m_socket = new QLocalSocket(this);
    connect(m_socket, &QLocalSocket::connected, this, &DiscordRpcService::onConnected);
    connect(m_socket, &QLocalSocket::disconnected, this, &DiscordRpcService::onDisconnected);
    connect(m_socket, &QLocalSocket::errorOccurred, this, &DiscordRpcService::onErrorOccurred);
    connect(m_socket, &QLocalSocket::readyRead, this, &DiscordRpcService::onReadyRead);

    m_debounceTimer = new QTimer(this);
    m_debounceTimer->setSingleShot(true);
    m_debounceTimer->setInterval(kDebounceMs);
    connect(m_debounceTimer, &QTimer::timeout, this, &DiscordRpcService::flushQueuedActivity);

    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setInterval(kReconnectMs);
    connect(m_reconnectTimer, &QTimer::timeout, this, &DiscordRpcService::connectToDiscord);

    connectToDiscord();
}

DiscordRpcService::~DiscordRpcService()
{
    if (m_socket != nullptr && m_socket->state() == QLocalSocket::ConnectedState) {
        m_socket->disconnectFromServer();
    }
}

void DiscordRpcService::connectToDiscord()
{
    if (m_socket == nullptr || m_socket->state() != QLocalSocket::UnconnectedState) {
        return;
    }

    const QString path = ipcSocketPath(m_nextPipeIndex);
    m_nextPipeIndex = (m_nextPipeIndex + 1) % kPipeAttempts;
    m_socket->connectToServer(path);
}

void DiscordRpcService::scheduleReconnect()
{
    m_handshakeAcked = false;
    if (m_reconnectTimer != nullptr && !m_reconnectTimer->isActive()) {
        m_reconnectTimer->start();
    }
}

void DiscordRpcService::onConnected()
{
    m_reconnectTimer->stop();
    sendHandshake();
}

void DiscordRpcService::onDisconnected()
{
    scheduleReconnect();
}

void DiscordRpcService::onErrorOccurred()
{
    // Discord not running, or this pipe index belongs to something else —
    // both routine (there is no way to tell them apart, and either way the
    // fix is the same: try again later). Logged at info, not warn/error.
    LoggerService::instance().info(
        QStringLiteral("[DiscordRpc] %1 not reachable, will retry").arg(ipcSocketPath(m_nextPipeIndex)));
    scheduleReconnect();
}

void DiscordRpcService::sendHandshake()
{
    QJsonObject payload;
    payload.insert(QStringLiteral("v"), 1);
    payload.insert(QStringLiteral("client_id"), clientId());
    writeFrame(kHandshakeOp, payload);
}

void DiscordRpcService::writeFrame(int opcode, const QJsonObject &payload)
{
    if (m_socket == nullptr || m_socket->state() != QLocalSocket::ConnectedState) {
        return;
    }

    const QByteArray json = QJsonDocument(payload).toJson(QJsonDocument::Compact);

    QByteArray header(8, Qt::Uninitialized);
    qToLittleEndian<qint32>(opcode, reinterpret_cast<uchar *>(header.data()));
    qToLittleEndian<qint32>(json.size(), reinterpret_cast<uchar *>(header.data()) + 4);

    m_socket->write(header);
    m_socket->write(json);
}

void DiscordRpcService::onReadyRead()
{
    m_readBuffer.append(m_socket->readAll());

    while (m_readBuffer.size() >= 8) {
        const auto *bytes = reinterpret_cast<const uchar *>(m_readBuffer.constData());
        const qint32 opcode = qFromLittleEndian<qint32>(bytes);
        const qint32 length = qFromLittleEndian<qint32>(bytes + 4);
        if (length < 0 || m_readBuffer.size() < 8 + length) {
            return; // rest of this frame has not arrived yet
        }

        m_readBuffer.remove(0, 8 + length);

        if (opcode == kHandshakeOp || opcode == kFrameOp) {
            // The first frame back after a handshake is Discord's own READY
            // dispatch; anything queued before the connection went live can
            // go out now.
            if (!m_handshakeAcked) {
                m_handshakeAcked = true;
                flushQueuedActivity();
            }
        } else if (opcode == kCloseOp) {
            m_socket->disconnectFromServer();
        }
    }
}

QJsonObject DiscordRpcService::buildActivity(const QString &details, const QString &state,
                                              const QString &largeImageText, qint64 startEpochSec,
                                              qint64 endEpochSec) const
{
    QJsonObject activity;
    activity.insert(QStringLiteral("details"), details);
    activity.insert(QStringLiteral("state"), state);

    // "segmenter_logo" has to exist as an uploaded Rich Presence asset on
    // whichever Discord application DISCORD_CLIENT_ID names — see
    // .env.example.
    QJsonObject assets;
    assets.insert(QStringLiteral("large_image"), QStringLiteral("segmenter_logo"));
    assets.insert(QStringLiteral("large_text"), largeImageText);
    assets.insert(QStringLiteral("small_image"), QStringLiteral("segmenter_logo"));
    assets.insert(QStringLiteral("small_text"), QStringLiteral("Video Segmenter"));
    activity.insert(QStringLiteral("assets"), assets);

    if (startEpochSec > 0 || endEpochSec > 0) {
        QJsonObject timestamps;
        if (startEpochSec > 0) {
            timestamps.insert(QStringLiteral("start"), startEpochSec);
        }
        if (endEpochSec > 0) {
            timestamps.insert(QStringLiteral("end"), endEpochSec);
        }
        activity.insert(QStringLiteral("timestamps"), timestamps);
    }

    QJsonObject button;
    button.insert(QStringLiteral("label"), QStringLiteral("Download Segmenter"));
    button.insert(QStringLiteral("url"), QStringLiteral("https://github.com/Lynder063/segmenter"));
    activity.insert(QStringLiteral("buttons"), QJsonArray{button});

    return activity;
}

void DiscordRpcService::queueActivity(const QJsonObject &activity)
{
    if (!isEnabled()) {
        return;
    }
    m_queuedActivity = activity;
    m_hasQueuedActivity = true;
    // Restarts the countdown if it is already running — the debounce itself.
    // Dragging the seek slider would otherwise spam Discord's IPC socket once
    // per timeChanged() tick.
    m_debounceTimer->start();
}

void DiscordRpcService::flushQueuedActivity()
{
    if (!m_hasQueuedActivity || !m_handshakeAcked) {
        return;
    }
    m_hasQueuedActivity = false;

    QJsonObject args;
    args.insert(QStringLiteral("pid"), QCoreApplication::applicationPid());
    args.insert(QStringLiteral("activity"), m_queuedActivity);

    QJsonObject payload;
    payload.insert(QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY"));
    payload.insert(QStringLiteral("args"), args);
    payload.insert(QStringLiteral("nonce"), QUuid::createUuid().toString(QUuid::WithoutBraces));

    writeFrame(kFrameOp, payload);
}

void DiscordRpcService::setIdle()
{
    queueActivity(buildActivity(tr("Idle"), tr("Waiting for video..."), tr("Segmenter"),
                                 m_sessionStartEpochSec, 0));
}

void DiscordRpcService::setVideoLoaded(const QString &videoName, const QString &formattedShowName)
{
    const QString details = formattedShowName.isEmpty() ? truncateName(videoName, 60) : formattedShowName;
    const QString state = formattedShowName.isEmpty()
                               ? tr("Editing Segments")
                               : tr("Editing: %1").arg(truncateName(videoName, 40));
    queueActivity(buildActivity(details, state, tr("Segmenter — Ready"), m_sessionStartEpochSec, 0));
}

void DiscordRpcService::setPlaying(const QString &videoName, qint64 positionMs, qint64 durationMs,
                                    const QString &formattedShowName)
{
    const QString details = formattedShowName.isEmpty() ? truncateName(videoName, 60) : formattedShowName;
    const QString state = formattedShowName.isEmpty()
                               ? tr("Editing Segments")
                               : tr("Segmenting: %1").arg(truncateName(videoName, 40));

    // Discord renders a native progress bar when both ends of the timestamp
    // range are set, so play/pause is the one state that reports real ones
    // instead of the session start.
    const qint64 nowSec = QDateTime::currentSecsSinceEpoch();
    const qint64 startSec = nowSec - positionMs / 1000;
    const qint64 endSec = startSec + durationMs / 1000;

    queueActivity(buildActivity(details, state, tr("Segmenter — Playing"), startSec, endSec));
}

void DiscordRpcService::setPaused(const QString &videoName, qint64 positionMs, qint64 durationMs,
                                   const QString &formattedShowName)
{
    const QString details = formattedShowName.isEmpty() ? truncateName(videoName, 60) : formattedShowName;
    const QString timeText = formatDuration(positionMs) + QStringLiteral(" / ") + formatDuration(durationMs);
    const QString state = formattedShowName.isEmpty()
                               ? QStringLiteral("[%1]").arg(timeText)
                               : tr("Segmenting: %1 [%2]").arg(truncateName(videoName, 30), timeText);

    queueActivity(buildActivity(details, state, tr("Segmenter — Paused"), m_sessionStartEpochSec, 0));
}

void DiscordRpcService::setAnalyzing(const QString &videoName)
{
    queueActivity(buildActivity(tr("Analyzing audio waveform..."), truncateName(videoName, 60),
                                 tr("Segmenter — Analyzing"), m_sessionStartEpochSec, 0));
}

void DiscordRpcService::clear()
{
    if (!isEnabled() || m_socket == nullptr || m_socket->state() != QLocalSocket::ConnectedState) {
        return;
    }

    // No "activity" key at all is how this protocol clears the presence.
    QJsonObject args;
    args.insert(QStringLiteral("pid"), QCoreApplication::applicationPid());

    QJsonObject payload;
    payload.insert(QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY"));
    payload.insert(QStringLiteral("args"), args);
    payload.insert(QStringLiteral("nonce"), QUuid::createUuid().toString(QUuid::WithoutBraces));

    writeFrame(kFrameOp, payload);
}

} // namespace segmenter
