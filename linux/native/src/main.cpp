#include "Application.h"

#include <cstdlib>

// The process already has a usable stdout for `--scan`, and there is no
// console-window problem to work around the way there is on Windows — the one
// thing Linux needs before the application runs is picking a Wayland window
// decoration.
//
// GNOME's Mutter does not implement server-side decoration, so Qt falls back
// to drawing its own client-side one. Its default ("bradient") plugin ends up
// double-drawn alongside GNOME's own decoration on a stock GNOME/Wayland
// session, producing two stacked titlebars. "adwaita" is Qt's decoration
// plugin that matches GNOME's own style and does not have this problem;
// setenv's 0-for-overwrite leaves QT_WAYLAND_DECORATION alone if the user (or
// a KDE/other Wayland session that does not need this) already set it.
int main(int argc, char *argv[])
{
    setenv("QT_WAYLAND_DECORATION", "adwaita", 0);
    return segmenter::runApplication(argc, argv);
}
