#!/usr/bin/env python3
"""
Segmenter — macOS Native Entry Point
Supports both Apple Silicon (arm64) and Intel (x86_64) Macs.
"""

import sys
import os
import platform
import logging

# Ensure linux/ module directory is accessible for core logic
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
LINUX_SRC = os.path.join(PROJECT_ROOT, "linux")

if LINUX_SRC not in sys.path:
    sys.path.insert(0, LINUX_SRC)

from PySide6.QtCore import Qt, QCoreApplication
from PySide6.QtWidgets import QApplication, QMenuBar, QMenu
from PySide6.QtGui import QIcon, QKeySequence, QAction

# Import UI components from shared core
from ui import MainWindow, DARK_STYLESHEET
from gpu import GPU_NAME, GPU_BACKEND, GPU_AVAILABLE

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("Segmenter.macOS")


def setup_macos_menu_bar(app: QApplication, main_window: MainWindow):
    """
    Build native macOS top menu bar with Cmd shortcuts.
    """
    menu_bar = QMenuBar()
    
    # App Menu (About / Quit)
    app_menu = menu_bar.addMenu("Segmenter")
    
    about_action = QAction("About Segmenter", main_window)
    about_action.triggered.connect(main_window._show_about_dialog if hasattr(main_window, '_show_about_dialog') else lambda: None)
    app_menu.addAction(about_action)
    app_menu.addSeparator()
    
    quit_action = QAction("Quit Segmenter", main_window)
    quit_action.setShortcut(QKeySequence.Quit)  # Cmd+Q on macOS
    quit_action.triggered.connect(app.quit)
    app_menu.addAction(quit_action)

    # File Menu
    file_menu = menu_bar.addMenu("File")
    
    open_action = QAction("Open Local Video...", main_window)
    open_action.setShortcut(QKeySequence.Open)  # Cmd+O on macOS
    open_action.triggered.connect(main_window._on_open_video_clicked)
    file_menu.addAction(open_action)
    
    file_menu.addSeparator()
    
    upload_action = QAction("Upload All Drafts", main_window)
    upload_action.setShortcut("Ctrl+U")
    upload_action.triggered.connect(main_window._on_upload_all_clicked)
    file_menu.addAction(upload_action)

    # Tools Menu
    tools_menu = menu_bar.addMenu("Tools")
    
    rcd_action = QAction("Scan Season (Fingerprint)...", main_window)
    rcd_action.setShortcut("Ctrl+F")
    rcd_action.triggered.connect(main_window._on_scan_season_clicked)
    tools_menu.addAction(rcd_action)

    main_window.setMenuBar(menu_bar)


def main():
    arch = platform.machine()
    logger.info("Starting Segmenter on macOS (%s)", arch)
    logger.info("GPU Environment: %s (%s)", GPU_NAME or "N/A", GPU_BACKEND)

    # Enable High DPI scaling for macOS Retina Displays
    os.environ["QT_ENABLE_HIGHDPI_SCALING"] = "1"
    os.environ["QT_AUTO_SCREEN_SCALE_FACTOR"] = "1"

    app = QApplication(sys.argv)
    app.setApplicationName("Segmenter")
    app.setOrganizationName("TheIntroDB")
    app.setOrganizationDomain("theintrodb.org")

    # Set icon if available
    icon_path = os.path.join(LINUX_SRC, "app_icon.png")
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))

    window = MainWindow()
    window.setWindowTitle(f"Segmenter (macOS {arch})")
    
    # Configure macOS native menu bar
    setup_macos_menu_bar(app, window)

    window.resize(1340, 840)
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
