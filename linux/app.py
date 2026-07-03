import os
import sys
from PySide6.QtWidgets import QApplication
from PySide6.QtGui import QIcon
from ui import SegmenterWindow

def main():
    # Configure high DPI scaling
    QApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough
    ) if hasattr(Qt, "HighDpiScaleFactorRoundingPolicy") else None

    app = QApplication(sys.argv)
    app.setApplicationName("Segmenter")
    app.setApplicationVersion("1.0.0")
    
    # Load and set application window icon
    icon_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "app_icon.png"))
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))

    window = SegmenterWindow()
    window.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    # Ensure Qt class names are available
    from PySide6.QtCore import Qt
    main()
