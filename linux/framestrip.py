import os
import subprocess
import math
from PySide6.QtCore import Qt, QObject, Signal, Slot, QRunnable, QThreadPool, QTimer
from PySide6.QtWidgets import QWidget, QHBoxLayout, QVBoxLayout, QPushButton, QLabel, QFrame
from PySide6.QtGui import QPixmap, QColor, QPalette

class FrameExtractSignals(QObject):
    ready = Signal(int, bytes)  # ms, raw_png_data

class FrameExtractRunnable(QRunnable):
    def __init__(self, video_path: str, ms: int, width: int = 96, height: int = 54):
        super().__init__()
        self.video_path = video_path
        self.ms = ms
        self.width = width
        self.height = height
        self.signals = FrameExtractSignals()

    def run(self):
        # Convert ms to seconds
        seconds = self.ms / 1000.0
        
        # Seek first (-ss before -i) for near-instant execution
        cmd = [
            "ffmpeg",
            "-y",
            "-nostdin",
            "-loglevel", "quiet",
            "-threads", "1",
            "-ss", f"{seconds:.3f}",
            "-an",
            "-i", self.video_path,
            "-vframes", "1",
            "-s", f"{self.width}x{self.height}",
            "-f", "image2",
            "-vcodec", "mjpeg",
            "-"
        ]
        
        try:
            startupinfo = None
            if os.name == 'nt':
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                startupinfo=startupinfo
            )
            
            try:
                # Use a larger 15s timeout to support slow files/concurrency
                jpeg_data, stderr_data = process.communicate(timeout=15)
                if jpeg_data:
                    self.signals.ready.emit(self.ms, jpeg_data)
                else:
                    print(f"[FrameExtractRunnable] No jpeg data returned for {self.ms}ms. Stderr: {stderr_data.decode('utf-8', errors='replace')}")
            except subprocess.TimeoutExpired:
                # Critical: kill the timed out ffmpeg process to prevent CPU/memory leak
                process.kill()
                process.communicate() # flush output and clean up zombie process
                print(f"[FrameExtractRunnable] Timeout expired for {self.ms}ms seeking.")
        except Exception as e:
            print(f"[FrameExtractRunnable] Exception during ffmpeg extract: {str(e)}")


class FrameThumbCell(QFrame):
    clicked_at_ms = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.time_ms = 0
        self.is_current = False
        
        self.setFrameShape(QFrame.StyledPanel)
        self.setStyleSheet("""
            FrameThumbCell {
                border: 1px solid #1c1c1f;
                border-radius: 4px;
                background-color: #0b0b0d;
            }
            FrameThumbCell:hover {
                border: 1px solid #50505b;
            }
            FrameThumbCell[current="true"] {
                border: 2px solid #007aff;
            }
        """)

        # Layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(2, 2, 2, 2)
        layout.setSpacing(2)

        # Image thumbnail container
        self.img_lbl = QLabel(self)
        self.img_lbl.setAlignment(Qt.AlignCenter)
        self.img_lbl.setScaledContents(True)
        self.img_lbl.setStyleSheet("background-color: #000000; border-radius: 2px;")
        layout.addWidget(self.img_lbl, stretch=1)

        # Time label
        self.time_lbl = QLabel("00:00.000", self)
        self.time_lbl.setAlignment(Qt.AlignCenter)
        self.time_lbl.setStyleSheet("font-size: 9px; font-family: monospace; color: #a0a0b0;")
        layout.addWidget(self.time_lbl)

    def set_thumbnail(self, pixmap: Optional[QPixmap]):
        if pixmap:
            self.img_lbl.setPixmap(pixmap)
        else:
            self.img_lbl.clear()

    def set_time(self, ms: int):
        self.time_ms = ms
        # Format time as mm:ss.mmm
        total_sec = ms // 1000
        m = total_sec // 60
        s = total_sec % 60
        millis = ms % 1000
        self.time_lbl.setText(f"{m:02d}:{s:02d}.{millis:03d}")

    def set_current(self, current: bool):
        self.is_current = current
        self.setProperty("current", "true" if current else "false")
        if current:
            self.time_lbl.setStyleSheet("font-size: 9px; font-family: monospace; color: #007aff; font-weight: bold;")
        else:
            self.time_lbl.setStyleSheet("font-size: 9px; font-family: monospace; color: #a0a0b0;")
        self.style().unpolish(self)
        self.style().polish(self)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.clicked_at_ms.emit(self.time_ms)
            event.accept()
        else:
            super().mousePressEvent(event)


class FrameStripWidget(QWidget):
    seek_requested = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.video_path = ""
        self.duration_ms = 0
        self.current_time_ms = 0
        self.frame_rate = 23.976
        
        self.temporal_mode = "coarse"  # "coarse" or "fine"
        self.focused_time_ms = None
        self.half_count = 6  # 13 cells total
        self.cell_width = 86
        self.cell_height = 48
        
        self.cache = {}
        self.pending_requests = set()
        
        # Dedicated thread pool for thumbnail seeking (max 3 concurrent ffmpegs)
        self.thread_pool = QThreadPool(self)
        self.thread_pool.setMaxThreadCount(3)
        
        # Debounce timer for thumbnail rendering during fast scrubbing
        self.reload_timer = QTimer(self)
        self.reload_timer.setSingleShot(True)
        self.reload_timer.setInterval(200)  # 200ms debounce
        self.reload_timer.timeout.connect(self._load_visible_thumbnails)

        # UI Layout
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(4)

        # Mode indicator bar
        header_layout = QHBoxLayout()
        header_layout.setContentsMargins(6, 0, 6, 0)
        
        self.mode_badge = QLabel("Overview", self)
        self.mode_badge.setStyleSheet("""
            background-color: #1e293b;
            color: #38bdf8;
            font-size: 9px;
            font-weight: bold;
            padding: 2px 6px;
            border-radius: 4px;
        """)
        header_layout.addWidget(self.mode_badge)
        
        self.mode_detail = QLabel("step = 6/fps", self)
        self.mode_detail.setStyleSheet("font-size: 10px; color: #8e8e93;")
        header_layout.addWidget(self.mode_detail)
        header_layout.addStretch()
        
        main_layout.addLayout(header_layout)

        # Horizontal list of thumbnails
        self.strip_layout = QHBoxLayout()
        self.strip_layout.setSpacing(2)
        self.strip_layout.setContentsMargins(0, 0, 0, 0)
        
        self.cells = []
        for i in range(self.half_count * 2 + 1):
            cell = FrameThumbCell(self)
            cell.setFixedSize(self.cell_width, self.cell_height + 18)
            cell.clicked_at_ms.connect(self._on_cell_clicked)
            self.strip_layout.addWidget(cell)
            self.cells.append(cell)
            
        main_layout.addLayout(self.strip_layout)
        
        # Set height constraint
        self.setFixedHeight(self.cell_height + 38)

    def set_video_context(self, video_path: str, duration_ms: int, frame_rate: float):
        self.video_path = video_path
        self.duration_ms = duration_ms
        self.frame_rate = frame_rate if frame_rate > 0 else 23.976
        self.thread_pool.clear()
        self.cache.clear()
        self.pending_requests.clear()
        self.temporal_mode = "coarse"
        self.focused_time_ms = None
        self._update_mode_label()
        
        if duration_ms > 0:
            self.update_position(self.current_time_ms)

    def update_position(self, current_time_ms: int, is_stepping: bool = False):
        self.current_time_ms = current_time_ms
        
        if is_stepping:
            self.temporal_mode = "fine"
            self.focused_time_ms = self._snap_to_fine_frame(current_time_ms)
        
        self._update_mode_label()
        
        # Calculate cell timestamps
        timestamps = self._calculate_timestamps()
        
        # Immediately set text labels & highlight matching cell
        for i, ms in enumerate(timestamps):
            cell = self.cells[i]
            cell.set_time(ms)
            
            # Draw QPixmap if cached, else show blank placeholder
            if ms in self.cache:
                cell.set_thumbnail(self.cache[ms])
            else:
                cell.set_thumbnail(None)
                
            # Current playhead highlight
            # In fine mode, highlights the cell closest to playhead
            # In coarse mode, centers around the current playhead
            is_curr = False
            if self.temporal_mode == "coarse":
                is_curr = (i == self.half_count)
            else:
                # Closest frame
                is_curr = (abs(ms - current_time_ms) < (500.0 / self.frame_rate))
            cell.set_current(is_curr)
            
        # Trigger delayed background load
        self.reload_timer.start()

    def set_temporal_mode(self, mode: str):
        if mode in ("coarse", "fine"):
            self.temporal_mode = mode
            if mode == "coarse":
                self.focused_time_ms = None
            self._update_mode_label()

    def _update_mode_label(self):
        fps_text = f"{self.frame_rate:.2f}"
        if self.temporal_mode == "coarse":
            self.mode_badge.setText("Overview")
            self.mode_badge.setStyleSheet("background-color: #1e293b; color: #38bdf8; font-size: 9px; font-weight: bold; padding: 2px 6px; border-radius: 4px;")
            step_ms = self._coarse_step_ms()
            self.mode_detail.setText(f"step = {step_ms} ms, fps {fps_text}")
        else:
            self.mode_badge.setText("Single Frames")
            self.mode_badge.setStyleSheet("background-color: #064e3b; color: #34d399; font-size: 9px; font-weight: bold; padding: 2px 6px; border-radius: 4px;")
            self.mode_detail.setText(f"1 frame step, fps {fps_text}")

    def _coarse_step_ms(self) -> int:
        seconds = 6.0 / max(self.frame_rate, 1.0)
        return max(1, int(round(seconds * 1000.0)))

    def _snap_to_fine_frame(self, ms: int) -> int:
        seconds = ms / 1000.0
        frame_idx = round(seconds * self.frame_rate)
        snapped_sec = frame_idx / self.frame_rate
        return max(0, min(int(round(snapped_sec * 1000.0)), self.duration_ms))

    def _calculate_timestamps(self) -> list[int]:
        timestamps = []
        anchor = self.focused_time_ms if self.focused_time_ms is not None else self.current_time_ms
        
        if self.temporal_mode == "coarse":
            step = self._coarse_step_ms()
            # Align center anchor on step boundaries
            anchor_coarse = (anchor // step) * step
            for i in range(self.half_count * 2 + 1):
                raw = anchor_coarse + (i - self.half_count) * step
                timestamps.append(max(0, min(raw, self.duration_ms)))
        else:
            # Fine mode (frame-by-frame)
            frame_duration_ms = 1000.0 / self.frame_rate
            center_idx = round(anchor / frame_duration_ms)
            for i in range(self.half_count * 2 + 1):
                idx = center_idx + (i - self.half_count)
                raw = int(round(idx * frame_duration_ms))
                timestamps.append(max(0, min(raw, self.duration_ms)))
                
        return timestamps

    def _load_visible_thumbnails(self):
        if not self.video_path:
            return
            
        # Get visible timestamps
        timestamps = self._calculate_timestamps()
        
        # Sort queue: load center-most timestamps first
        sorted_indices = sorted(
            range(len(timestamps)),
            key=lambda idx: abs(idx - self.half_count)
        )
        
        for idx in sorted_indices:
            ms = timestamps[idx]
            if ms in self.cache or ms in self.pending_requests:
                continue
                
            self.pending_requests.add(ms)
            
            runnable = FrameExtractRunnable(self.video_path, ms, self.cell_width, self.cell_height)
            runnable.signals.ready.connect(self._on_thumbnail_ready)
            self.thread_pool.start(runnable)

    @Slot(int, bytes)
    def _on_thumbnail_ready(self, ms: int, jpeg_data: bytes):
        self.pending_requests.discard(ms)
        
        pixmap = QPixmap()
        if pixmap.loadFromData(jpeg_data):
            if len(self.cache) > 300:
                keys = list(self.cache.keys())
                for k in keys[:50]:
                    self.cache.pop(k, None)
                    
            self.cache[ms] = pixmap
            
            # Check if this frame is currently displayed in any visible cells and update
            timestamps = self._calculate_timestamps()
            for i, cell_ms in enumerate(timestamps):
                # Tolerance of 5ms due to rounding approximations
                if abs(cell_ms - ms) <= 5:
                    self.cells[i].set_thumbnail(pixmap)
        else:
            print(f"[FrameStrip] Failed to load pixmap from jpeg data for {ms}ms, data len: {len(jpeg_data)}")

    def _on_cell_clicked(self, ms: int):
        self.temporal_mode = "fine"
        self.focused_time_ms = self._snap_to_fine_frame(ms)
        self._update_mode_label()
        self.seek_requested.emit(ms)
