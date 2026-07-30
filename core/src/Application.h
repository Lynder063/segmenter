#pragma once

class QString;

namespace segmenter {

/// Runs Segmenter: parses the arguments, then either performs a headless scan
/// or shows the main window and enters the event loop.
///
/// Both platform entry points funnel here so the argument handling, theming and
/// window setup exist once. Each `main()` is left with only what genuinely
/// differs — on Windows, attaching to the parent console so `--scan` can print.
///
/// Returns the process exit code.
int runApplication(int argc, char *argv[]);

/// Headless scan: `Segmenter --scan <season-directory|video-file>`.
///
/// Runs the same engine the scan dialog drives and prints the matches, for
/// batch-scanning a library from a script and for checking detection changes
/// against known-good timings without going through the UI.
int runHeadlessScan(const QString &sourcePath);

} // namespace segmenter
