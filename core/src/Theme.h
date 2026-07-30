#pragma once

#include <QColor>
#include <QString>

namespace segmenter::theme {

// Palette shared between the stylesheet and the custom-painted widgets
// (timeline, frame strip), which cannot read QSS and would otherwise drift out
// of step with the rest of the window.
namespace color {
inline const QColor windowBackground   = QColor(0x12, 0x12, 0x14);
inline const QColor panelBackground    = QColor(0x1c, 0x1c, 0x1f);
inline const QColor rowBackground      = QColor(0x23, 0x23, 0x28);
inline const QColor controlBackground  = QColor(0x26, 0x26, 0x2b);
inline const QColor trackBackground    = QColor(0x16, 0x16, 0x18);
inline const QColor border             = QColor(0x2a, 0x2a, 0x30);
inline const QColor borderStrong       = QColor(0x38, 0x38, 0x40);
inline const QColor textPrimary        = QColor(0xe1, 0xe1, 0xe6);
inline const QColor textSecondary      = QColor(0xa0, 0xa0, 0xb0);
inline const QColor textMuted          = QColor(0x8e, 0x8e, 0x93);
inline const QColor accent             = QColor(0x00, 0x7a, 0xff);
inline const QColor accentHover        = QColor(0x0a, 0x84, 0xff);
inline const QColor playhead           = QColor(0xff, 0x3b, 0x30);
inline const QColor waveform           = QColor(0xff, 0x9f, 0x0a);
inline const QColor waveformMusic      = QColor(0x64, 0xd2, 0xff);
inline const QColor statusSuccess      = QColor(0x30, 0xd1, 0x58);
inline const QColor statusError        = QColor(0xff, 0x45, 0x3a);
inline const QColor statusWarning      = QColor(0xff, 0x9f, 0x0a);
} // namespace color

// The full application stylesheet. Carried over from the Linux port's
// DARK_STYLESHEET (linux/ui.py) so both builds render the same window, with
// additional rules for the widgets only the native build uses.
QString darkStylesheet();

// Applies the stylesheet plus the matching QPalette. The palette matters for
// the handful of places Qt paints before the stylesheet applies — chiefly the
// window background during resize, which flashes light grey without it.
void apply();

} // namespace segmenter::theme
