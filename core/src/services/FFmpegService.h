#pragma once

#include <QByteArray>
#include <QString>
#include <QVector>

#include <cstdint>
#include <optional>

#include "models/Models.h"

namespace segmenter {

/// Wraps the ffmpeg/ffprobe command-line binaries, matching the macOS port's
/// FFmpegService. Every call blocks the calling thread and is meant to be run
/// from a worker (QtConcurrent), never from the GUI thread.
class FFmpegService {
public:
    static FFmpegService &instance();

    /// Locates ffmpeg and ffprobe. Search order: a `bin` folder next to the
    /// executable (for a bundled distribution), then PATH, then the install
    /// locations winget and Chocolatey use.
    void resolveBinaries();

    QString ffmpegPath() const { return m_ffmpegPath; }
    QString ffprobePath() const { return m_ffprobePath; }
    bool hasBinaries() const { return !m_ffmpegPath.isEmpty() && !m_ffprobePath.isEmpty(); }

    /// Duration, frame rate, resolution and codec names via ffprobe.
    std::optional<MediaInfo> inspectMedia(const QString &filePath) const;

    /// Mono 16-bit PCM. The default 4000 Hz is what the chroma extractor
    /// expects; the timeline waveform and music classifier ask for 8000 Hz,
    /// where the 80-3000 Hz analysis band needs the extra headroom.
    /// Returns an empty vector when ffmpeg is missing or the file has no audio.
    QVector<qint16> extractPcmAudioSnippet(const QString &filePath,
                                           int startSec = 0,
                                           int durationSec = 900,
                                           int sampleRate = 4000) const;

    /// A single JPEG frame at `timeMs`, piped straight out of ffmpeg's stdout.
    ///
    /// `size` defaults to the frame strip's 160x90. Anything doing image
    /// *analysis* rather than display must ask for a larger frame: OCR needs
    /// glyphs several pixels tall, and at 160x90 a credit crawl is
    /// unresolvable, so text detection silently finds nothing.
    QByteArray extractThumbnailData(const QString &filePath,
                                    int timeMs,
                                    const QString &size = QStringLiteral("160x90")) const;

    /// Mean luminance of the frame at `timeSec`, 0-255. Used to snap credit
    /// boundaries onto the black frame that usually precedes them.
    /// Returns nullopt when the frame could not be decoded.
    std::optional<double> meanLuminance(const QString &filePath, int timeSec) const;

    /// File extensions the season scanner will pick up out of a directory.
    static const QStringList &supportedVideoExtensions();

private:
    FFmpegService() = default;

    static QString findBinary(const QString &name);

    /// Runs `program` with `arguments`, returns raw stdout. `timeoutMs` of -1
    /// waits indefinitely.
    static QByteArray runProcess(const QString &program,
                                 const QStringList &arguments,
                                 int timeoutMs = 120000);

    QString m_ffmpegPath;
    QString m_ffprobePath;
};

} // namespace segmenter
