import os
import sys
from PySide6.QtGui import QPainter, QPixmap, QLinearGradient, QColor, QBrush
from PySide6.QtCore import Qt, QRectF
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtWidgets import QApplication

def generate():
    app = QApplication(sys.argv)
    
    # 512x512 high resolution icon
    size = 512
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.transparent)
    
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.Antialiasing)
    
    # Draw rounded rect (squircle) macOS icon background
    # Gradient: bright green to emerald green
    grad = QLinearGradient(0, 0, 0, size)
    grad.setColorAt(0.0, QColor("#28cd41"))
    grad.setColorAt(1.0, QColor("#1b8e2b"))
    
    painter.setBrush(QBrush(grad))
    painter.setPen(Qt.NoPen)
    
    # Squircle padding
    padding = 24
    rect = QRectF(padding, padding, size - 2 * padding, size - 2 * padding)
    painter.drawRoundedRect(rect, 96, 96)
    
    # Render SVG on top
    svg_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "IntroStamp.icon", "Assets", "timeline.selection.svg"))
    if not os.path.exists(svg_path):
        print(f"SVG file not found: {svg_path}")
        return

    renderer = QSvgRenderer(svg_path)
    
    # Center the SVG inside the rounded rect
    svg_width = size * 0.55
    svg_height = svg_width * (17.998 / 33.9453)  # Match aspect ratio from viewBox
    
    svg_rect = QRectF(
        (size - svg_width) / 2.0,
        (size - svg_height) / 2.0,
        svg_width,
        svg_height
    )
    
    renderer.render(painter, svg_rect)
    painter.end()
    
    out_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "app_icon.png"))
    pixmap.save(out_path, "PNG")
    print(f"Generated icon at {out_path}")

if __name__ == "__main__":
    generate()
