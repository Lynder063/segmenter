#include "Application.h"

#include <QApplication>
#include <QFileInfo>
#include <QIcon>
#include <QMutex>
#include <QMutexLocker>
#include <QStringList>
#include <QStyleFactory>
#include <QTextStream>
#include <QTimer>

#include <atomic>
#include <cstdio>

#include "Theme.h"
#include "models/Models.h"
#include "services/FFmpegService.h"
#include "services/LoggerService.h"
#include "services/RcdEngine.h"
#include "views/MainWindow.h"

namespace segmenter {

int runHeadlessScan(const QString &sourcePath)
{
    QTextStream out(stdout);

    if (!QFileInfo::exists(sourcePath)) {
        out << "Source not found: " << sourcePath << Qt::endl;
        return 2;
    }

    FFmpegService::instance().resolveBinaries();

    const bool isDirectory = QFileInfo(sourcePath).isDir();
    RcdEngine::Options options;
    options.method = isDirectory ? RcdDetectionMethod::HardwareAccelerated
                                 : RcdDetectionMethod::SingleEpisode;

    std::atomic_bool cancelFlag{false};

    // The engine invokes both callbacks from its worker pools. QTextStream is
    // not thread-safe, and without this the lines interleave mid-word.
    QMutex outputMutex;

    const auto progress = [&out, &outputMutex](const QString &message, int percent) {
        QMutexLocker locker(&outputMutex);
        out << "[" << percent << "%] " << message << Qt::endl;
    };
    const auto debugLogger = [&out, &outputMutex](const QString &line) {
        QMutexLocker locker(&outputMutex);
        out << "    " << line << Qt::endl;
    };

    try {
        const RcdEngine::Results results =
            isDirectory
                ? RcdEngine::instance().scanSeason(sourcePath, options, cancelFlag,
                                                   progress, debugLogger)
                : RcdEngine::instance().scanSingleEpisode(sourcePath, options, cancelFlag,
                                                          progress, debugLogger);

        out << Qt::endl << "=== RESULTS ===" << Qt::endl;
        for (auto it = results.constBegin(); it != results.constEnd(); ++it) {
            out << it.key() << Qt::endl;
            for (const RcdMatch &match : it.value()) {
                out << "    " << segmentTypeDisplayName(match.type)
                    << "  " << formatTimecode(static_cast<int>(match.startSec * 1000))
                    << " - " << formatTimecode(static_cast<int>(match.endSec * 1000))
                    << QStringLiteral("  (%1s, %2%)")
                           .arg(match.durationSec(), 0, 'f', 1)
                           .arg(match.confidence * 100.0f, 0, 'f', 1)
                    << Qt::endl;
            }
        }
        return 0;
    } catch (const RcdEngine::Cancelled &) {
        out << "Cancelled." << Qt::endl;
        return 3;
    } catch (const std::exception &error) {
        out << "ERROR: " << error.what() << Qt::endl;
        return 1;
    }
}

int runApplication(int argc, char *argv[])
{
    // Fusion is the only built-in style that honours a QPalette consistently
    // across platforms; the native styles paint several widgets with system
    // colours no stylesheet can reach, leaving light patches in a dark window.
    QApplication::setStyle(QStyleFactory::create(QStringLiteral("Fusion")));

    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Segmenter"));
    app.setApplicationDisplayName(QStringLiteral("Segmenter"));
    app.setOrganizationName(QStringLiteral("Segmenter"));
    app.setApplicationVersion(QStringLiteral(SEGMENTER_VERSION));
    // The installed .desktop file's basename varies by packaging: plain
    // "segmenter" for the .deb/.rpm/AppImage/PKGBUILD (all install
    // segmenter.desktop), but Flatpak renames it to the app-id
    // (dev.lynder.Segmenter.desktop) because that's a hard requirement of
    // its portal sandboxing — xdg-desktop-portal validates every portal call
    // (file dialogs, secrets, notifications) against /.flatpak-info's
    // recorded app-id, and rejects them on a mismatch. Flatpak always
    // exports FLATPAK_ID into the sandbox, so preferring it when set keeps
    // this correct for both without a compile-time branch.
    const QByteArray flatpakId = qgetenv("FLATPAK_ID");
    app.setDesktopFileName(flatpakId.isEmpty() ? QStringLiteral("segmenter")
                                                : QString::fromUtf8(flatpakId));
    app.setWindowIcon(QIcon(QStringLiteral(":/resources/app_icon.png")));

    LoggerService::instance().info(
        QStringLiteral("Segmenter %1 starting").arg(app.applicationVersion()));

    const QStringList arguments = app.arguments();

    // Headless mode runs before any widget is built, so it needs no display.
    const int scanIndex = arguments.indexOf(QStringLiteral("--scan"));
    if (scanIndex >= 0) {
        if (scanIndex + 1 >= arguments.size()) {
            std::fputs("usage: Segmenter --scan <season-directory|video-file>\n", stdout);
            return 2;
        }
        return runHeadlessScan(arguments.at(scanIndex + 1));
    }

    theme::apply();

    MainWindow window;
    window.show();

    // Optional file argument. Deferred to the event loop so the window is
    // mapped before LibVLC is handed its window handle.
    if (arguments.size() > 1 && !arguments.at(1).startsWith(QLatin1Char('-'))) {
        const QString path = arguments.at(1);
        QTimer::singleShot(0, &window, [&window, path] { window.openVideo(path); });
    }

    const int exitCode = app.exec();
    LoggerService::instance().info(
        QStringLiteral("Segmenter exiting with code %1").arg(exitCode));
    return exitCode;
}

} // namespace segmenter
