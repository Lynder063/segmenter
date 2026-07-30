#pragma once

#include <QFile>
#include <QMutex>
#include <QObject>
#include <QString>

namespace segmenter {

/// Application log, mirroring the macOS LoggerService: timestamped lines to a
/// rolling file under the user's local app data, plus a signal the RCD scan
/// dialog subscribes to so debug output appears live in its log pane.
class LoggerService : public QObject {
    Q_OBJECT

public:
    enum class Level {
        Debug,
        Info,
        Warn,
        Error,
    };

    static LoggerService &instance();

    void debug(const QString &message);
    void info(const QString &message);
    void warn(const QString &message);
    void error(const QString &message);

    void log(Level level, const QString &message);

    /// Absolute path of the current log file, shown in the About box so a user
    /// filing an issue can find it.
    QString logFilePath() const;

signals:
    void messageLogged(int level, const QString &formattedLine);

private:
    LoggerService();
    ~LoggerService() override;

    Q_DISABLE_COPY_MOVE(LoggerService)

    static QString levelName(Level level);

    mutable QMutex m_mutex;
    QFile m_file;
};

} // namespace segmenter
