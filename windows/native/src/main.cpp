#include <cstdio>
#include <cstring>

#include <windows.h>

#include "Application.h"

namespace {

/// The GUI subsystem gives the process no console, so stdout goes nowhere.
/// Borrow the launching shell's console when there is one, and fall back to
/// allocating a fresh one so a double-clicked `--scan` still shows output.
void attachConsole()
{
    // When the caller redirected stdout to a file or pipe, the handle is
    // already valid and must be left alone: reopening it on CONOUT$ would
    // send the output to a console instead of the file the caller asked for.
    const HANDLE existing = GetStdHandle(STD_OUTPUT_HANDLE);
    if (existing != nullptr && existing != INVALID_HANDLE_VALUE) {
        return;
    }

    if (!AttachConsole(ATTACH_PARENT_PROCESS) && !AllocConsole()) {
        return;
    }
    FILE *stream = nullptr;
    freopen_s(&stream, "CONOUT$", "w", stdout);
    freopen_s(&stream, "CONOUT$", "w", stderr);
}

bool wantsHeadlessScan(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--scan") == 0) {
            return true;
        }
    }
    return false;
}

} // namespace

int main(int argc, char *argv[])
{
    // Only for --scan: attaching a console to a normal GUI launch would flash
    // a window up behind the app.
    if (wantsHeadlessScan(argc, argv)) {
        attachConsole();
    }
    return segmenter::runApplication(argc, argv);
}
