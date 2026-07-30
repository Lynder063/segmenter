#include "services/LoggerService.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QMutexLocker>
#include <QStandardPaths>
#include <QTextStream>

#include <cstdio>

namespace segmenter {

LoggerService &LoggerService::instance()
{
    static LoggerService logger;
    return logger;
}

LoggerService::LoggerService()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    if (!dir.isEmpty() && QDir().mkpath(dir)) {
        m_file.setFileName(QDir(dir).filePath(QStringLiteral("segmenter.log")));

        // Truncate a log that has grown past ~5 MB rather than rotating: the
        // file exists for the current session's diagnostics, and keeping
        // archives of it has never been asked for.
        const QIODevice::OpenMode mode =
            (m_file.exists() && m_file.size() > 5 * 1024 * 1024)
                ? (QIODevice::WriteOnly | QIODevice::Text)
                : (QIODevice::Append | QIODevice::Text);

        m_file.open(mode);
    }
}

LoggerService::~LoggerService()
{
    QMutexLocker locker(&m_mutex);
    if (m_file.isOpen()) {
        m_file.close();
    }
}

QString LoggerService::levelName(Level level)
{
    switch (level) {
    case Level::Debug: return QStringLiteral("DEBUG");
    case Level::Info:  return QStringLiteral("INFO");
    case Level::Warn:  return QStringLiteral("WARN");
    case Level::Error: return QStringLiteral("ERROR");
    }
    return QStringLiteral("INFO");
}

void LoggerService::log(Level level, const QString &message)
{
    const QString line = QStringLiteral("[%1] [%2] %3")
                             .arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs),
                                  levelName(level),
                                  message);

    {
        QMutexLocker locker(&m_mutex);
        if (m_file.isOpen()) {
            QTextStream stream(&m_file);
            stream << line << Qt::endl;
        }
    }

    // stderr keeps output visible when the app is launched from a console for
    // debugging; the WIN32 build simply has no console attached and drops it.
    std::fputs(qPrintable(line + QLatin1Char('\n')), stderr);

    emit messageLogged(static_cast<int>(level), line);
}

void LoggerService::debug(const QString &message) { log(Level::Debug, message); }
void LoggerService::info(const QString &message)  { log(Level::Info, message); }
void LoggerService::warn(const QString &message)  { log(Level::Warn, message); }
void LoggerService::error(const QString &message) { log(Level::Error, message); }

QString LoggerService::logFilePath() const
{
    QMutexLocker locker(&m_mutex);
    return m_file.fileName();
}

} // namespace segmenter
