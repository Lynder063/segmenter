#include "services/FFmpegService.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>
#include <QStringList>

#ifdef Q_OS_WIN
// CREATE_NO_WINDOW, used to keep ffmpeg from flashing a console per invocation.
#  include <windows.h>
#endif

#include "services/LoggerService.h"

namespace segmenter {

FFmpegService &FFmpegService::instance()
{
    static FFmpegService service;
    return service;
}

const QStringList &FFmpegService::supportedVideoExtensions()
{
    static const QStringList extensions = {
        QStringLiteral("mp4"),
        QStringLiteral("mkv"),
        QStringLiteral("avi"),
        QStringLiteral("mov"),
        QStringLiteral("webm"),
        QStringLiteral("m4v"),
    };
    return extensions;
}

QString FFmpegService::findBinary(const QString &name)
{
    const QString exeName = name + QStringLiteral(".exe");

    // 1. Bundled next to Segmenter.exe, for a self-contained distribution.
    const QDir appDir(QCoreApplication::applicationDirPath());
    for (const QString &relative : {QStringLiteral("bin"), QString()}) {
        const QString candidate = relative.isEmpty()
                                      ? appDir.filePath(exeName)
                                      : appDir.filePath(relative + QLatin1Char('/') + exeName);
        if (QFileInfo::exists(candidate)) {
            return QDir::toNativeSeparators(candidate);
        }
    }

    // 2. PATH.
    const QString onPath = QStandardPaths::findExecutable(name);
    if (!onPath.isEmpty()) {
        return QDir::toNativeSeparators(onPath);
    }

    // 3. Where winget and Chocolatey drop it. winget installs the Gyan build
    // into a versioned folder, so the leaf directory has to be globbed.
    const QString localAppData =
        QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);

    QStringList searchRoots = {
        QStringLiteral("C:/ProgramData/chocolatey/bin"),
        QStringLiteral("C:/ffmpeg/bin"),
        QStringLiteral("C:/Program Files/ffmpeg/bin"),
    };

    const QString wingetPackages =
        QDir::home().filePath(QStringLiteral("AppData/Local/Microsoft/WinGet/Packages"));
    if (QDir(wingetPackages).exists()) {
        const QFileInfoList packages =
            QDir(wingetPackages).entryInfoList(QStringList{QStringLiteral("*FFmpeg*")},
                                               QDir::Dirs | QDir::NoDotAndDotDot);
        for (const QFileInfo &package : packages) {
            const QFileInfoList builds =
                QDir(package.absoluteFilePath()).entryInfoList(QStringList{QStringLiteral("ffmpeg*")},
                                                               QDir::Dirs | QDir::NoDotAndDotDot);
            for (const QFileInfo &build : builds) {
                searchRoots << build.absoluteFilePath() + QStringLiteral("/bin");
            }
        }
    }
    Q_UNUSED(localAppData)

    for (const QString &root : std::as_const(searchRoots)) {
        const QString candidate = QDir(root).filePath(exeName);
        if (QFileInfo::exists(candidate)) {
            return QDir::toNativeSeparators(candidate);
        }
    }

    return QString();
}

void FFmpegService::resolveBinaries()
{
    m_ffmpegPath = findBinary(QStringLiteral("ffmpeg"));
    m_ffprobePath = findBinary(QStringLiteral("ffprobe"));

    LoggerService::instance().info(
        QStringLiteral("[FFmpegService] ffmpeg: %1")
            .arg(m_ffmpegPath.isEmpty() ? QStringLiteral("NOT FOUND") : m_ffmpegPath));
    LoggerService::instance().info(
        QStringLiteral("[FFmpegService] ffprobe: %1")
            .arg(m_ffprobePath.isEmpty() ? QStringLiteral("NOT FOUND") : m_ffprobePath));
}

QByteArray FFmpegService::runProcess(const QString &program,
                                     const QStringList &arguments,
                                     int timeoutMs)
{
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setProcessChannelMode(QProcess::SeparateChannels);

#ifdef Q_OS_WIN
    // No console window for the child; the GUI build would otherwise flash one
    // per frame extraction while the frame strip fills in. X11 and Wayland have
    // no equivalent problem, so this is Windows-only rather than abstracted.
    process.setCreateProcessArgumentsModifier(
        [](QProcess::CreateProcessArguments *args) {
            args->flags |= CREATE_NO_WINDOW;
        });
#endif

    process.start();
    if (!process.waitForStarted(10000)) {
        LoggerService::instance().error(
            QStringLiteral("[FFmpegService] failed to start %1: %2")
                .arg(program, process.errorString()));
        return {};
    }

    process.closeWriteChannel();

    if (!process.waitForFinished(timeoutMs)) {
        LoggerService::instance().warn(
            QStringLiteral("[FFmpegService] %1 timed out after %2 ms; killing")
                .arg(program)
                .arg(timeoutMs));
        process.kill();
        process.waitForFinished(2000);
        // Whatever arrived before the timeout is still returned: a truncated
        // PCM snippet yields fewer chroma frames but stays usable, and the
        // alternative is discarding an otherwise-good extraction.
    }

    return process.readAllStandardOutput();
}

std::optional<MediaInfo> FFmpegService::inspectMedia(const QString &filePath) const
{
    if (m_ffprobePath.isEmpty()) {
        LoggerService::instance().warn(
            QStringLiteral("[FFmpegService] ffprobe not found, using fallback metadata"));
        return std::nullopt;
    }

    const QStringList arguments = {
        QStringLiteral("-v"), QStringLiteral("error"),
        QStringLiteral("-show_entries"),
        QStringLiteral("format=duration:stream=r_frame_rate,codec_name,codec_type,width,height"),
        QStringLiteral("-of"), QStringLiteral("json"),
        QDir::toNativeSeparators(filePath),
    };

    const QByteArray output = runProcess(m_ffprobePath, arguments, 30000);
    if (output.isEmpty()) {
        return std::nullopt;
    }

    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(output, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        LoggerService::instance().error(
            QStringLiteral("[FFmpegService] ffprobe returned unparseable JSON: %1")
                .arg(parseError.errorString()));
        return std::nullopt;
    }

    const QJsonObject root = document.object();
    MediaInfo info;

    const QJsonObject format = root.value(QStringLiteral("format")).toObject();
    const double durationSec = format.value(QStringLiteral("duration")).toString().toDouble();
    info.durationMs = static_cast<int>(durationSec * 1000.0);

    // Same fallback as the macOS port: most catalogue content is 23.976, and a
    // wrong frame rate only affects the size of a single-frame step.
    info.frameRate = 23.976;
    info.videoCodec = QStringLiteral("unknown");
    info.audioCodec = QStringLiteral("unknown");

    const QJsonArray streams = root.value(QStringLiteral("streams")).toArray();
    for (const QJsonValue &value : streams) {
        const QJsonObject stream = value.toObject();
        const QString type = stream.value(QStringLiteral("codec_type")).toString();

        if (type == QLatin1String("video")) {
            info.videoCodec = stream.value(QStringLiteral("codec_name"))
                                  .toString(QStringLiteral("video"));
            info.width = stream.value(QStringLiteral("width")).toInt();
            info.height = stream.value(QStringLiteral("height")).toInt();

            const QString rate = stream.value(QStringLiteral("r_frame_rate")).toString();
            const QStringList parts = rate.split(QLatin1Char('/'));
            if (parts.size() == 2) {
                const double numerator = parts.at(0).toDouble();
                const double denominator = parts.at(1).toDouble();
                if (denominator > 0.0) {
                    info.frameRate = numerator / denominator;
                }
            }
        } else if (type == QLatin1String("audio")) {
            info.audioCodec = stream.value(QStringLiteral("codec_name"))
                                  .toString(QStringLiteral("audio"));
        }
    }

    LoggerService::instance().info(
        QStringLiteral("[FFmpegService] Inspected %1 -> %2 ms, %3 fps, video %4, audio %5")
            .arg(QFileInfo(filePath).fileName())
            .arg(info.durationMs)
            .arg(info.frameRate, 0, 'f', 3)
            .arg(info.videoCodec, info.audioCodec));

    return info;
}

QVector<qint16> FFmpegService::extractPcmAudioSnippet(const QString &filePath,
                                                      int startSec,
                                                      int durationSec,
                                                      int sampleRate) const
{
    if (m_ffmpegPath.isEmpty()) {
        return {};
    }

    // -ss before -i seeks by keyframe without decoding everything up to the
    // start point, which is what keeps a credits-region extraction on a
    // 50-minute file down to a couple of seconds.
    const QStringList arguments = {
        QStringLiteral("-nostdin"),
        QStringLiteral("-ss"), QString::number(startSec),
        QStringLiteral("-t"), QString::number(durationSec),
        QStringLiteral("-vn"), QStringLiteral("-sn"),
        QStringLiteral("-i"), QDir::toNativeSeparators(filePath),
        QStringLiteral("-f"), QStringLiteral("s16le"),
        QStringLiteral("-ac"), QStringLiteral("1"),
        QStringLiteral("-ar"), QString::number(sampleRate),
        QStringLiteral("-threads"), QStringLiteral("0"),
        QStringLiteral("pipe:1"),
    };

    const QByteArray raw = runProcess(m_ffmpegPath, arguments, 300000);
    if (raw.isEmpty()) {
        return {};
    }

    const int sampleCount = static_cast<int>(raw.size() / static_cast<qsizetype>(sizeof(qint16)));
    QVector<qint16> samples(sampleCount);
    std::memcpy(samples.data(), raw.constData(), static_cast<std::size_t>(sampleCount) * sizeof(qint16));
    return samples;
}

QByteArray FFmpegService::extractThumbnailData(const QString &filePath,
                                               int timeMs,
                                               const QString &size) const
{
    if (m_ffmpegPath.isEmpty()) {
        return {};
    }

    const double seconds = static_cast<double>(timeMs) / 1000.0;
    const QStringList arguments = {
        QStringLiteral("-nostdin"),
        QStringLiteral("-ss"), QString::number(seconds, 'f', 3),
        QStringLiteral("-i"), QDir::toNativeSeparators(filePath),
        QStringLiteral("-vframes"), QStringLiteral("1"),
        QStringLiteral("-s"), size,
        QStringLiteral("-f"), QStringLiteral("image2pipe"),
        QStringLiteral("-c:v"), QStringLiteral("mjpeg"),
        QStringLiteral("pipe:1"),
    };

    return runProcess(m_ffmpegPath, arguments, 20000);
}

std::optional<double> FFmpegService::meanLuminance(const QString &filePath, int timeSec) const
{
    if (m_ffmpegPath.isEmpty()) {
        return std::nullopt;
    }

    // Downscale to a single pixel and read its luma: ffmpeg's scaler does the
    // averaging, so no image decode is needed on this side.
    const QStringList arguments = {
        QStringLiteral("-nostdin"),
        QStringLiteral("-ss"), QString::number(timeSec),
        QStringLiteral("-i"), QDir::toNativeSeparators(filePath),
        QStringLiteral("-vframes"), QStringLiteral("1"),
        QStringLiteral("-vf"), QStringLiteral("scale=1:1"),
        QStringLiteral("-pix_fmt"), QStringLiteral("gray"),
        QStringLiteral("-f"), QStringLiteral("rawvideo"),
        QStringLiteral("pipe:1"),
    };

    const QByteArray raw = runProcess(m_ffmpegPath, arguments, 20000);
    if (raw.isEmpty()) {
        return std::nullopt;
    }

    return static_cast<double>(static_cast<unsigned char>(raw.at(0)));
}

} // namespace segmenter
