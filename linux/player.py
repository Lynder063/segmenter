from PySide6.QtCore import QUrl, Qt, Signal, Slot, QTimer
from PySide6.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QSlider, QLabel, QStyle
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
from PySide6.QtMultimediaWidgets import QVideoWidget
import math

class VideoPlayerWidget(QWidget):
    time_changed = Signal(int)  # ms
    duration_changed = Signal(int)  # ms
    playback_state_changed = Signal(bool)  # playing/paused
    framerate_resolved = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.frame_rate = 23.976
        self.frame_duration_ms = 1000.0 / self.frame_rate
        self._is_seeking = False
        
        # Create media player and audio output
        self.media_player = QMediaPlayer(self)
        self.audio_output = QAudioOutput(self)
        self.media_player.setAudioOutput(self.audio_output)
        
        # Create video widget
        self.video_widget = QVideoWidget(self)
        self.media_player.setVideoOutput(self.video_widget)
        
        # Set up UI layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.video_widget, stretch=1)
        
        # Control bar layout
        controls_layout = QHBoxLayout()
        controls_layout.setContentsMargins(6, 4, 6, 4)
        
        # Play/Pause button
        self.play_btn = QPushButton(self)
        self.play_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))
        self.play_btn.clicked.connect(self.toggle_play)
        controls_layout.addWidget(self.play_btn)
        
        # Step back button
        self.step_back_btn = QPushButton(self)
        self.step_back_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaSeekBackward))
        self.step_back_btn.clicked.connect(self.step_backward)
        self.step_back_btn.setToolTip("Step 1 frame backward (Left Arrow)")
        controls_layout.addWidget(self.step_back_btn)
        
        # Step forward button
        self.step_fwd_btn = QPushButton(self)
        self.step_fwd_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaSeekForward))
        self.step_fwd_btn.clicked.connect(self.step_forward)
        self.step_fwd_btn.setToolTip("Step 1 frame forward (Right Arrow)")
        controls_layout.addWidget(self.step_fwd_btn)
        
        # Current time label
        self.time_label = QLabel("00:00.000", self)
        controls_layout.addWidget(self.time_label)
        
        # Position slider
        self.slider = QSlider(Qt.Horizontal, self)
        self.slider.setRange(0, 0)
        self.slider.sliderPressed.connect(self._on_slider_pressed)
        self.slider.sliderMoved.connect(self._on_slider_moved)
        self.slider.sliderReleased.connect(self._on_slider_released)
        controls_layout.addWidget(self.slider, stretch=1)
        
        # Total duration label
        self.duration_label = QLabel("00:00.000", self)
        controls_layout.addWidget(self.duration_label)
        
        layout.addLayout(controls_layout)
        
        # Connect signals
        self.media_player.positionChanged.connect(self._on_position_changed)
        self.media_player.durationChanged.connect(self._on_duration_changed)
        self.media_player.playbackStateChanged.connect(self._on_playback_state_changed)
        
        # Timer to read frame rate from media metadata when available
        self.metadata_timer = QTimer(self)
        self.metadata_timer.setInterval(1000)
        self.metadata_timer.timeout.connect(self._check_metadata)

    def load_video(self, file_path: str):
        self.media_player.stop()
        if file_path.startswith(("http://", "https://", "smb://", "nfs://", "sftp://", "ftp://", "file://")):
            self.media_player.setSource(QUrl(file_path))
        else:
            self.media_player.setSource(QUrl.fromLocalFile(file_path))
        self.metadata_timer.start()

    def play(self):
        self.media_player.play()

    def pause(self):
        self.media_player.pause()

    def toggle_play(self):
        if self.media_player.playbackState() == QMediaPlayer.PlayingState:
            self.media_player.pause()
        else:
            self.media_player.play()

    def seek(self, ms: int):
        clamped = max(0, min(ms, self.media_player.duration()))
        self.media_player.setPosition(clamped)

    def step_forward(self):
        # Step 1 frame forward
        pos = self.media_player.position()
        self.seek(int(pos + self.frame_duration_ms))

    def step_backward(self):
        # Step 1 frame backward
        pos = self.media_player.position()
        self.seek(int(pos - self.frame_duration_ms))

    def current_position(self) -> int:
        return self.media_player.position()

    def is_playing(self) -> bool:
        return self.media_player.playbackState() == QMediaPlayer.PlayingState

    def _on_position_changed(self, position: int):
        if not self._is_seeking:
            self.slider.setValue(position)
            self.time_label.setText(self._format_time(position))
            self.time_changed.emit(position)

    def _on_duration_changed(self, duration: int):
        self.slider.setRange(0, duration)
        self.duration_label.setText(self._format_time(duration))
        self.duration_changed.emit(duration)

    def _on_playback_state_changed(self, state):
        is_playing = (state == QMediaPlayer.PlayingState)
        self.playback_state_changed.emit(is_playing)
        
        if is_playing:
            self.play_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPause))
            self.metadata_timer.stop()
        else:
            self.play_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))
            # Snap to nearest frame boundary when playback stops
            pos = self.media_player.position()
            snapped = self._snap_to_frame(pos)
            if snapped != pos:
                self.seek(snapped)

    def _on_slider_pressed(self):
        self._is_seeking = True

    def _on_slider_moved(self, position: int):
        self.time_label.setText(self._format_time(position))
        self.time_changed.emit(position)

    def _on_slider_released(self):
        self._is_seeking = False
        self.seek(self.slider.value())

    def _snap_to_frame(self, pos_ms: int) -> int:
        frame_idx = round(pos_ms / self.frame_duration_ms)
        return int(round(frame_idx * self.frame_duration_ms))

    def _format_time(self, ms: int) -> str:
        total_sec = ms // 1000
        m = total_sec // 60
        s = total_sec % 60
        millis = ms % 1000
        return f"{m:02d}:{s:02d}.{millis:03d}"

    def _check_metadata(self):
        # Attempt to retrieve nominal video framerate from metadata
        metadata = self.media_player.metaData()
        if metadata:
            # VideoFrameRate key in QMediaMetaData
            from PySide6.QtMultimedia import QMediaMetaData
            fps = metadata.value(QMediaMetaData.VideoFrameRate)
            if fps and isinstance(fps, (int, float)) and fps > 0:
                self.frame_rate = float(fps)
                self.frame_duration_ms = 1000.0 / self.frame_rate
                self.metadata_timer.stop()
                self.framerate_resolved.emit(self.frame_rate)
