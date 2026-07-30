#include "Theme.h"

#include <QApplication>
#include <QPalette>

namespace segmenter::theme {

QString darkStylesheet()
{
    // Rules down to QLabel#statusMsg are a direct carry-over of the Linux port's
    // DARK_STYLESHEET. Everything after it covers widgets that only exist in the
    // native build (menu bar, tabs, header labels, the timeline gutter).
    return QStringLiteral(R"QSS(
QMainWindow {
    background-color: #121214;
}

QWidget {
    color: #e1e1e6;
    font-family: "Segoe UI", "SF Pro Display", "Outfit", "Inter", sans-serif;
    font-size: 13px;
}

QGroupBox {
    border: 1px solid #2a2a30;
    border-radius: 8px;
    margin-top: 12px;
    padding-top: 12px;
    font-weight: bold;
    color: #a0a0b0;
    background-color: #1c1c1f;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 10px;
    padding: 0 4px;
}

QLineEdit {
    background-color: #26262b;
    border: 1px solid #323238;
    border-radius: 4px;
    padding: 6px 10px;
    color: #ffffff;
    selection-background-color: #007aff;
}

QLineEdit:focus {
    border: 1px solid #007aff;
    background-color: #2c2c32;
}

QLineEdit:disabled {
    background-color: #1f1f24;
    color: #606068;
}

QComboBox {
    background-color: #26262b;
    border: 1px solid #323238;
    border-radius: 4px;
    padding: 6px 10px;
    color: #ffffff;
    min-width: 6em;
}

QComboBox:on-select {
    background-color: #007aff;
}

QComboBox::drop-down {
    subcontrol-origin: padding;
    subcontrol-position: top right;
    width: 20px;
    border-left-width: 0px;
}

QComboBox QAbstractItemView {
    background-color: #26262b;
    border: 1px solid #323238;
    selection-background-color: #007aff;
    outline: none;
}

QPushButton {
    background-color: #2a2a30;
    border: 1px solid #383840;
    border-radius: 6px;
    padding: 6px 14px;
    font-weight: 500;
    color: #e1e1e6;
}

QPushButton:hover {
    background-color: #383840;
    border: 1px solid #484852;
}

QPushButton:pressed {
    background-color: #1f1f24;
}

QPushButton:disabled {
    background-color: #1c1c1f;
    color: #606068;
    border: 1px solid #26262b;
}

QPushButton#uploadAllBtn {
    background-color: #007aff;
    border: 1px solid #0a84ff;
    color: #ffffff;
    font-weight: bold;
}

QPushButton#uploadAllBtn:hover {
    background-color: #0a84ff;
}

QPushButton#uploadAllBtn:pressed {
    background-color: #0062cc;
}

QScrollArea {
    border: none;
    background-color: #121214;
}

QScrollBar:horizontal {
    border: none;
    background-color: #1c1c1f;
    height: 10px;
    margin: 0px 0px 0px 0px;
}

QScrollBar::handle:horizontal {
    background-color: #3e3e46;
    min-width: 20px;
    border-radius: 5px;
}

QScrollBar::handle:horizontal:hover {
    background-color: #50505b;
}

QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
    border: none;
    background: none;
    width: 0px;
}

QScrollBar:vertical {
    border: none;
    background-color: #1c1c1f;
    width: 10px;
    margin: 0px 0px 0px 0px;
}

QScrollBar::handle:vertical {
    background-color: #3e3e46;
    min-height: 20px;
    border-radius: 5px;
}

QScrollBar::handle:vertical:hover {
    background-color: #50505b;
}

QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    border: none;
    background: none;
    height: 0px;
}

QSplitter::handle {
    background-color: #222226;
}

QSplitter::handle:horizontal {
    width: 4px;
}

QSplitter::handle:vertical {
    height: 4px;
}

QProgressBar {
    border: 1px solid #2a2a30;
    border-radius: 4px;
    text-align: center;
    background-color: #161618;
}

QProgressBar::chunk {
    background-color: #007aff;
    border-radius: 3px;
}

QLabel#statusMsg {
    font-weight: 500;
}

/* --- Native-build additions ------------------------------------------- */

SegmentEditorRow {
    background-color: #232328;
    border-radius: 6px;
    padding: 4px;
}

QLabel#sectionHeader {
    color: #a0a0b0;
    font-size: 11px;
    font-weight: bold;
    padding: 4px 6px;
    background-color: #1c1c1f;
    border-bottom: 1px solid #2a2a30;
}

QLabel#trackLabel {
    color: #a0a0b0;
    font-size: 11px;
    font-weight: bold;
    padding-left: 6px;
    background-color: #1c1c1f;
    border-bottom: 1px solid #2a2a30;
}

QLabel#hintText {
    color: #8e8e93;
    font-size: 11px;
}

QLabel#videoTitle {
    color: #a0a0b0;
    font-size: 11px;
}

QWidget#statusBar {
    background-color: #1a1a1c;
    border-top: 1px solid #2a2a30;
}

QWidget#videoStage {
    background-color: #000000;
}

QSlider::groove:horizontal {
    border: none;
    height: 4px;
    background-color: #2a2a30;
    border-radius: 2px;
}

QSlider::sub-page:horizontal {
    background-color: #0a84ff;
    border-radius: 2px;
}

QSlider::handle:horizontal {
    background-color: #d0d0d8;
    border: none;
    width: 10px;
    height: 10px;
    margin: -4px 0;
    border-radius: 2px;
}

QSlider::handle:horizontal:hover {
    background-color: #ffffff;
}

QToolButton {
    background-color: #2a2a30;
    border: 1px solid #383840;
    border-radius: 6px;
    padding: 4px 10px;
    color: #e1e1e6;
}

QToolButton:hover {
    background-color: #383840;
}

QToolButton:pressed {
    background-color: #1f1f24;
}

QToolButton:checked {
    background-color: #007aff;
    border: 1px solid #0a84ff;
}

QMenuBar {
    background-color: #1a1a1c;
    border-bottom: 1px solid #2a2a30;
}

QMenuBar::item:selected {
    background-color: #2a2a30;
}

QMenu {
    background-color: #1c1c1f;
    border: 1px solid #2a2a30;
    padding: 4px;
}

QMenu::item {
    padding: 6px 24px 6px 12px;
    border-radius: 4px;
}

QMenu::item:selected {
    background-color: #007aff;
}

QListWidget, QTreeWidget, QTableWidget {
    background-color: #1c1c1f;
    border: 1px solid #2a2a30;
    border-radius: 6px;
    outline: none;
}

QListWidget::item:selected, QTreeWidget::item:selected {
    background-color: #007aff;
}

QTextEdit, QPlainTextEdit {
    background-color: #161618;
    border: 1px solid #2a2a30;
    border-radius: 6px;
    color: #d0d0d8;
    selection-background-color: #007aff;
}

QCheckBox::indicator, QRadioButton::indicator {
    width: 15px;
    height: 15px;
    border: 1px solid #383840;
    border-radius: 3px;
    background-color: #26262b;
}

QCheckBox::indicator:checked, QRadioButton::indicator:checked {
    background-color: #007aff;
    border: 1px solid #0a84ff;
}

QToolTip {
    background-color: #26262b;
    color: #e1e1e6;
    border: 1px solid #383840;
    border-radius: 4px;
    padding: 4px 6px;
}

QDialog {
    background-color: #121214;
}
)QSS");
}

void apply()
{
    QPalette palette;
    palette.setColor(QPalette::Window, color::windowBackground);
    palette.setColor(QPalette::WindowText, color::textPrimary);
    palette.setColor(QPalette::Base, color::controlBackground);
    palette.setColor(QPalette::AlternateBase, color::panelBackground);
    palette.setColor(QPalette::Text, color::textPrimary);
    palette.setColor(QPalette::Button, color::border);
    palette.setColor(QPalette::ButtonText, color::textPrimary);
    palette.setColor(QPalette::Highlight, color::accent);
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::ToolTipBase, color::controlBackground);
    palette.setColor(QPalette::ToolTipText, color::textPrimary);
    palette.setColor(QPalette::PlaceholderText, color::textMuted);
    palette.setColor(QPalette::Disabled, QPalette::Text, QColor(0x60, 0x60, 0x68));
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, QColor(0x60, 0x60, 0x68));

    qApp->setPalette(palette);
    qApp->setStyleSheet(darkStylesheet());
}

} // namespace segmenter::theme
