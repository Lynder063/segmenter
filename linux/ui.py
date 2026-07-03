import os
import sys
import copy
import json
import urllib.parse
import logging
from typing import Dict, List, Optional, Any
from concurrent.futures import ThreadPoolExecutor

from PySide6.QtCore import Qt, QSize, Signal, Slot, QObject, QTimer, QUrl
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QLabel, QLineEdit, QComboBox, QGroupBox, QScrollArea, QSplitter,
    QFileDialog, QProgressBar, QMessageBox, QFrame, QStyle
)
from PySide6.QtGui import QIcon, QFont, QColor, QPalette, QUndoStack, QUndoCommand, QDesktopServices

from models import (
    MediaType, SegmentType, SegmentRange, SegmentDraft, TimelineDensityTrack,
    MediaQuery, SubmissionDraft, UsageHeaders, AutoLookupResult, ParsedFilenameHint
)
from parser import FilenameMediaParser
from validator import SegmentValidator, SegmentValidationError
from audio import AudioExtractorWorker
from clients import TheIntroDBClient, IntroDBClient, TMDBClient, APIClientError
from timeline import TimelineWidget
from player import VideoPlayerWidget
from framestrip import FrameStripWidget
from rcd_integration import RCDProgressDialog

# Configure module logger
logger = logging.getLogger(__name__)
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)

# QSS Stylesheet for a Premium Dark Interface
DARK_STYLESHEET = """
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
"""

class DraftChangeCommand(QUndoCommand):
    def __init__(self, window, before_drafts, after_drafts, description="Edit Drafts"):
        super().__init__(description)
        self.window = window
        self.before = copy.deepcopy(before_drafts)
        self.after = copy.deepcopy(after_drafts)

    def undo(self):
        self.window.local_drafts = copy.deepcopy(self.before)
        self.window.update_timeline_widget()

    def redo(self):
        self.window.local_drafts = copy.deepcopy(self.after)
        self.window.update_timeline_widget()


class SegmentEditorRow(QFrame):
    def __init__(self, segment_type: SegmentType, parent_window, parent=None):
        super().__init__(parent)
        self.segment_type = segment_type
        self.window = parent_window
        self.setFrameShape(QFrame.StyledPanel)
        self.setStyleSheet("SegmentEditorRow { background-color: #232328; border-radius: 6px; padding: 4px; }")

        layout = QHBoxLayout(self)
        layout.setContentsMargins(8, 4, 8, 4)
        
        # Bullet color indicator
        color_dot = QLabel(self)
        color_dot.setFixedSize(12, 12)
        color_dot.setStyleSheet(f"background-color: {segment_type.hex_color}; border-radius: 6px;")
        layout.addWidget(color_dot)
        
        # Name label
        name_lbl = QLabel(segment_type.display_name, self)
        name_lbl.setFixedWidth(65)
        name_lbl.setStyleSheet("font-weight: bold;")
        layout.addWidget(name_lbl)
        
        # Inputs
        self.start_edit = QLineEdit(self)
        self.start_edit.setPlaceholderText("--")
        self.start_edit.setFixedWidth(90)
        self.start_edit.setToolTip("Start Time (mm:ss.mmm)")
        self.start_edit.editingFinished.connect(self._on_start_changed)
        layout.addWidget(self.start_edit)
        
        # Set start anchor button
        self.set_start_btn = QPushButton(self)
        self.set_start_btn.setIcon(self.style().standardIcon(QStyle.SP_ArrowDown))
        self.set_start_btn.setFixedSize(24, 24)
        self.set_start_btn.setToolTip("Use playhead position as start")
        self.set_start_btn.clicked.connect(self._set_start_from_playhead)
        layout.addWidget(self.set_start_btn)
        
        self.end_edit = QLineEdit(self)
        self.end_edit.setPlaceholderText("--")
        self.end_edit.setFixedWidth(90)
        self.end_edit.setToolTip("End Time (mm:ss.mmm)")
        self.end_edit.editingFinished.connect(self._on_end_changed)
        layout.addWidget(self.end_edit)
        
        # Set end anchor button
        self.set_end_btn = QPushButton(self)
        self.set_end_btn.setIcon(self.style().standardIcon(QStyle.SP_ArrowDown))
        self.set_end_btn.setFixedSize(24, 24)
        self.set_end_btn.setToolTip("Use playhead position as end")
        self.set_end_btn.clicked.connect(self._set_end_from_playhead)
        layout.addWidget(self.set_end_btn)
        
        # Clear button
        clear_btn = QPushButton(self)
        clear_btn.setIcon(self.style().standardIcon(QStyle.SP_DialogDiscardButton))
        clear_btn.setFixedSize(24, 24)
        clear_btn.setToolTip("Clear segment drafts")
        clear_btn.clicked.connect(self._clear_drafts)
        layout.addWidget(clear_btn)
        
        # Upload single segment button
        self.upload_btn = QPushButton(self)
        self.upload_btn.setIcon(self.style().standardIcon(QStyle.SP_ArrowUp))
        self.upload_btn.setFixedSize(24, 24)
        self.upload_btn.setToolTip(f"Upload {segment_type.display_name} segment")
        self.upload_btn.clicked.connect(self._upload_segment)
        layout.addWidget(self.upload_btn)

    def update_draft_values(self, drafts: List[SegmentDraft]):
        # Just display the last draft values (first one or fallback)
        if drafts and not drafts[0].is_empty():
            d = drafts[0]
            self.start_edit.setText(self._format_time(d.start_ms))
            self.end_edit.setText(self._format_time(d.end_ms))
        else:
            self.start_edit.clear()
            self.end_edit.clear()

    def _format_time(self, ms: Optional[int]) -> str:
        if ms is None:
            return ""
        total_sec = ms // 1000
        m = total_sec // 60
        s = total_sec % 60
        millis = ms % 1000
        return f"{m:02d}:{s:02d}.{millis:03d}"

    def _parse_time(self, text: str) -> Optional[int]:
        text = text.strip()
        if not text:
            return None
        try:
            # Check if raw ms integer
            if text.isdigit():
                return int(text)
            
            # Format mm:ss.mmm or hh:mm:ss.mmm
            parts = text.split(":")
            if len(parts) < 2 or len(parts) > 3:
                return None
            
            sec_part = parts[-1]
            sec_subparts = sec_part.split(".")
            sec = int(sec_subparts[0])
            
            millis = 0
            if len(sec_subparts) == 2:
                fraction = sec_subparts[1][:3]
                fraction = fraction.ljust(3, "0")
                millis = int(fraction)
                
            mins = int(parts[-2])
            hours = int(parts[0]) if len(parts) == 3 else 0
            
            total_ms = (((hours * 60 + mins) * 60) + sec) * 1000 + millis
            return total_ms
        except Exception:
            return None

    def _on_start_changed(self):
        val = self._parse_time(self.start_edit.text())
        self.window.set_draft_boundary_ms(self.segment_type, "start", val)

    def _on_end_changed(self):
        val = self._parse_time(self.end_edit.text())
        self.window.set_draft_boundary_ms(self.segment_type, "end", val)

    def _set_start_from_playhead(self):
        pos = self.window.player.current_position()
        self.window.set_draft_boundary_ms(self.segment_type, "start", pos)

    def _set_end_from_playhead(self):
        pos = self.window.player.current_position()
        self.window.set_draft_boundary_ms(self.segment_type, "end", pos)

    def _clear_drafts(self):
        self.window.clear_draft(self.segment_type)

    def _upload_segment(self):
        self.window.upload_segment(self.segment_type)


class SegmenterWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Segmenter")
        self.setMinimumSize(1100, 720)
        self.setStyleSheet(DARK_STYLESHEET)

        # Clients
        self.the_introdb_client = TheIntroDBClient()
        self.introdb_client = IntroDBClient()
        self.tmdb_client = TMDBClient()
        self.thread_pool = ThreadPoolExecutor(max_workers=4)
        self.undo_stack = QUndoStack(self)

        # Models/State
        self.selected_video_url = ""
        self.video_duration_ms = 0
        self.zoom_level = 1.0
        self.minimum_zoom_level = 1.0
        
        self.server_segments = {t: [] for t in SegmentType}
        self.local_drafts = {t: [SegmentDraft.empty()] for t in SegmentType}
        self.audio_track = TimelineDensityTrack.empty()
        
        self.tmdb_candidates = []
        self.selected_candidate_tmdb_id = None
        self.rcd_results = {}
        self._pending_rcd_detections = None
        
        # Load API keys from local config file
        self.the_introdb_api_key = ""
        self.introdb_api_key = ""
        self.tmdb_api_key = ""
        self._load_keys_from_file()

        # Workers
        self.audio_worker = None
        self._is_stepping_key = False

        self._setup_ui()
        self._update_api_key_ui()

    def _setup_ui(self):
        central_widget = QWidget(self)
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # Horizontal Splitter
        splitter = QSplitter(Qt.Horizontal, self)
        main_layout.addWidget(splitter, stretch=1)

        # 1. Left Sidebar
        sidebar = QWidget(self)
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.setContentsMargins(12, 12, 12, 12)
        sidebar_layout.setSpacing(10)
        
        scroll_sidebar = QScrollArea(self)
        scroll_sidebar.setWidgetResizable(True)
        scroll_sidebar_content = QWidget()
        scroll_sidebar_content_layout = QVBoxLayout(scroll_sidebar_content)
        scroll_sidebar_content_layout.setContentsMargins(0, 0, 0, 0)
        scroll_sidebar_content_layout.setSpacing(12)
        
        # 1A. Video selection card
        video_grp = QGroupBox("Video", self)
        video_layout = QVBoxLayout(video_grp)
        self.video_title_lbl = QLabel("No video selected", self)
        self.video_title_lbl.setWordWrap(True)
        self.video_title_lbl.setStyleSheet("color: #a0a0b0; font-size: 11px;")
        video_layout.addWidget(self.video_title_lbl)
        
        open_video_btn = QPushButton("Open Local Video", self)
        open_video_btn.clicked.connect(self._on_open_video_clicked)
        video_layout.addWidget(open_video_btn)
        
        self.tmdb_match_combo = QComboBox(self)
        self.tmdb_match_combo.setVisible(False)
        self.tmdb_match_combo.currentIndexChanged.connect(self._on_tmdb_candidate_selected)
        video_layout.addWidget(self.tmdb_match_combo)
        
        self.auto_lookup_lbl = QLabel("", self)
        self.auto_lookup_lbl.setWordWrap(True)
        self.auto_lookup_lbl.setStyleSheet("color: #8e8e93; font-size: 11px;")
        video_layout.addWidget(self.auto_lookup_lbl)
        scroll_sidebar_content_layout.addWidget(video_grp)
        
        # 1B. API Keys card
        self.keys_grp = QGroupBox("API Keys", self)
        keys_layout = QVBoxLayout(self.keys_grp)
        
        self.the_introdb_key_edit = QLineEdit(self)
        self.the_introdb_key_edit.setPlaceholderText("TheIntroDB API Key")
        self.the_introdb_key_edit.setEchoMode(QLineEdit.Password)
        keys_layout.addWidget(self.the_introdb_key_edit)
        
        self.introdb_key_edit = QLineEdit(self)
        self.introdb_key_edit.setPlaceholderText("IntroDB API Key")
        self.introdb_key_edit.setEchoMode(QLineEdit.Password)
        keys_layout.addWidget(self.introdb_key_edit)
        
        self.tmdb_key_edit = QLineEdit(self)
        self.tmdb_key_edit.setPlaceholderText("TMDB API Key")
        self.tmdb_key_edit.setEchoMode(QLineEdit.Password)
        keys_layout.addWidget(self.tmdb_key_edit)
        
        save_keys_btn = QPushButton("Save Keys to Keyring", self)
        save_keys_btn.clicked.connect(self._on_save_keys_clicked)
        keys_layout.addWidget(save_keys_btn)
        scroll_sidebar_content_layout.addWidget(self.keys_grp)
        
        # 1C. Media Identification card
        media_grp = QGroupBox("Media Identification", self)
        media_layout = QVBoxLayout(media_grp)
        
        # TMDB Search field
        search_layout = QHBoxLayout()
        self.search_edit = QLineEdit(self)
        self.search_edit.setPlaceholderText("Search TMDB...")
        self.search_edit.returnPressed.connect(self._on_search_tmdb)
        search_layout.addWidget(self.search_edit)
        
        search_btn = QPushButton(self)
        search_btn.setIcon(self.style().standardIcon(QStyle.SP_FileDialogContentsView))
        search_btn.setFixedSize(30, 30)
        search_btn.clicked.connect(self._on_search_tmdb)
        search_layout.addWidget(search_btn)
        media_layout.addLayout(search_layout)
        
        self.search_results_combo = QComboBox(self)
        self.search_results_combo.setVisible(False)
        self.search_results_combo.currentIndexChanged.connect(self._on_search_result_selected)
        media_layout.addWidget(self.search_results_combo)
        
        self.tmdb_id_edit = QLineEdit(self)
        self.tmdb_id_edit.setPlaceholderText("TMDB ID")
        media_layout.addWidget(self.tmdb_id_edit)
        
        self.imdb_id_edit = QLineEdit(self)
        self.imdb_id_edit.setPlaceholderText("IMDB ID (optional)")
        media_layout.addWidget(self.imdb_id_edit)
        
        self.type_combo = QComboBox(self)
        self.type_combo.addItem("Movie", MediaType.MOVIE)
        self.type_combo.addItem("TV", MediaType.TV)
        self.type_combo.currentIndexChanged.connect(self._on_media_type_changed)
        media_layout.addWidget(self.type_combo)
        
        # Season/Episode inputs for TV
        self.tv_layout_widget = QWidget(self)
        tv_layout = QHBoxLayout(self.tv_layout_widget)
        tv_layout.setContentsMargins(0, 0, 0, 0)
        self.season_edit = QLineEdit(self)
        self.season_edit.setPlaceholderText("Season")
        tv_layout.addWidget(self.season_edit)
        self.episode_edit = QLineEdit(self)
        self.episode_edit.setPlaceholderText("Episode")
        tv_layout.addWidget(self.episode_edit)
        media_layout.addWidget(self.tv_layout_widget)
        
        buttons_layout = QHBoxLayout()
        load_segments_btn = QPushButton("Load Segments", self)
        load_segments_btn.clicked.connect(self._on_load_segments_clicked)
        buttons_layout.addWidget(load_segments_btn)
        
        upload_all_btn = QPushButton("Upload All Drafts", self)
        upload_all_btn.setObjectName("uploadAllBtn")
        upload_all_btn.clicked.connect(self.upload_all_segments)
        buttons_layout.addWidget(upload_all_btn)
        media_layout.addLayout(buttons_layout)

        # RCD Fingerprint Button
        rcd_layout = QHBoxLayout()
        self.rcd_btn = QPushButton("Scan Season (Fingerprint)", self)
        self.rcd_btn.clicked.connect(self._on_scan_season_clicked)
        rcd_layout.addWidget(self.rcd_btn)
        media_layout.addLayout(rcd_layout)

        scroll_sidebar_content_layout.addWidget(media_grp)
        
        # 1D. Segment Drafts Card
        drafts_grp = QGroupBox("Segment Drafts", self)
        drafts_layout = QVBoxLayout(drafts_grp)
        self.editor_rows = {}
        for seg_type in SegmentType:
            row = SegmentEditorRow(seg_type, self, drafts_grp)
            self.editor_rows[seg_type] = row
            drafts_layout.addWidget(row)
        scroll_sidebar_content_layout.addWidget(drafts_grp)
        
        scroll_sidebar_content_layout.addStretch()
        scroll_sidebar.setWidget(scroll_sidebar_content)
        sidebar_layout.addWidget(scroll_sidebar)
        splitter.addWidget(sidebar)

        # 2. Right Detail Pane
        detail_widget = QWidget(self)
        detail_layout = QVBoxLayout(detail_widget)
        detail_layout.setContentsMargins(12, 12, 12, 12)
        detail_layout.setSpacing(12)
        
        # 2A. Media Player Card
        self.player = VideoPlayerWidget(detail_widget)
        self.player.time_changed.connect(self._on_player_time_changed)
        self.player.duration_changed.connect(self._on_player_duration_changed)
        self.player.playback_state_changed.connect(self._on_playback_state_changed)
        self.player.framerate_resolved.connect(self._on_player_framerate_resolved)
        detail_layout.addWidget(self.player, stretch=3)

        # 2A2. Frame Strip Card
        self.framestrip = FrameStripWidget(detail_widget)
        self.framestrip.seek_requested.connect(self.seek_player)
        detail_layout.addWidget(self.framestrip)
        
        # 2B. Waveform loading bar
        self.waveform_progress_layout = QHBoxLayout()
        self.waveform_progress_lbl = QLabel("Extracting audio...", self)
        self.waveform_progress_bar = QProgressBar(self)
        self.waveform_progress_bar.setRange(0, 100)
        self.waveform_progress_bar.setValue(0)
        self.waveform_progress_layout.addWidget(self.waveform_progress_lbl)
        self.waveform_progress_layout.addWidget(self.waveform_progress_bar)
        
        self.waveform_progress_container = QWidget(self)
        self.waveform_progress_container.setLayout(self.waveform_progress_layout)
        self.waveform_progress_container.setVisible(False)
        detail_layout.addWidget(self.waveform_progress_container)

        # 2C. Timeline Row Header Label + ScrollArea Layout
        timeline_outer_layout = QHBoxLayout()
        timeline_outer_layout.setSpacing(0)
        
        # Label headers column (Audio, Intro, Recap, etc.)
        self.timeline_labels_widget = QWidget(self)
        self.timeline_labels_widget.setFixedWidth(92)
        self.timeline_labels_layout = QVBoxLayout(self.timeline_labels_widget)
        self.timeline_labels_layout.setContentsMargins(0, 0, 0, 0)
        self.timeline_labels_layout.setSpacing(0)
        
        # Setup labels inside column
        self.label_widgets = []
        # Label widgets are dynamically populated when loaded
        timeline_outer_layout.addWidget(self.timeline_labels_widget)
        
        # Scroll area for Timeline Widget
        self.timeline_scroll = QScrollArea(detail_widget)
        self.timeline_scroll.setWidgetResizable(False)
        self.timeline_scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.timeline_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        
        self.timeline = TimelineWidget(self.timeline_scroll)
        self.timeline.seek_requested.connect(self.seek_player)
        self.timeline.draft_range_created.connect(self.create_draft_range)
        self.timeline.draft_start_dragged.connect(self.set_draft_start_ms)
        self.timeline.draft_end_dragged.connect(self.set_draft_end_ms)
        self.timeline.draft_moved.connect(self.move_draft)
        self.timeline.drag_began.connect(self.begin_undo_drag_capture)
        self.timeline.drag_ended.connect(self.end_undo_drag_capture)
        
        self.timeline_scroll.setWidget(self.timeline)
        timeline_outer_layout.addWidget(self.timeline_scroll, stretch=1)
        
        detail_layout.addLayout(timeline_outer_layout, stretch=1)
        splitter.addWidget(detail_widget)
        
        # Set splitter sizes (25% sidebar, 75% detail)
        splitter.setSizes([320, 780])

        # 3. Status Bar
        self.status_bar = QFrame(self)
        self.status_bar.setFrameShape(QFrame.StyledPanel)
        self.status_bar.setStyleSheet("background-color: #1a1a1c; border-top: 1px solid #2a2a30; padding: 4px;")
        self.status_bar.setFixedHeight(28)
        
        status_bar_layout = QHBoxLayout(self.status_bar)
        status_bar_layout.setContentsMargins(12, 0, 12, 0)
        self.status_msg_lbl = QLabel("Ready", self)
        self.status_msg_lbl.setObjectName("statusMsg")
        self.status_msg_lbl.setStyleSheet("color: #8e8e93; font-size: 11px;")
        status_bar_layout.addWidget(self.status_msg_lbl)
        
        status_bar_layout.addStretch()
        self.status_rate_lbl = QLabel("", self)
        self.status_rate_lbl.setStyleSheet("color: #8e8e93; font-size: 11px;")
        status_bar_layout.addWidget(self.status_rate_lbl)
        
        main_layout.addWidget(self.status_bar)

        self._setup_timeline_labels()

    def _setup_timeline_labels(self):
        # Clear existing labels
        for w in self.label_widgets:
            self.timeline_labels_layout.removeWidget(w)
            w.deleteLater()
        self.label_widgets.clear()

        # Gather list of active label names
        names = []
        if self.audio_track.has_content:
            names.append("Audio")
        for seg in SegmentType:
            names.append(seg.display_name)
            
        row_height = 36
        for name in names:
            lbl = QLabel(name, self)
            lbl.setFixedHeight(row_height)
            lbl.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
            lbl.setStyleSheet("color: #a0a0b0; font-size: 11px; font-weight: bold; border-bottom: 1px solid #2a2a30; padding-left: 6px; background-color: #1c1c1f;")
            self.timeline_labels_layout.addWidget(lbl)
            self.label_widgets.append(lbl)

    def _update_api_key_ui(self):
        self.the_introdb_key_edit.setText(self.the_introdb_api_key)
        self.introdb_key_edit.setText(self.introdb_api_key)
        self.tmdb_key_edit.setText(self.tmdb_api_key)

    def _on_save_keys_clicked(self):
        self.the_introdb_api_key = self.the_introdb_key_edit.text().strip()
        self.introdb_api_key = self.introdb_key_edit.text().strip()
        self.tmdb_api_key = self.tmdb_key_edit.text().strip()
        
        self._save_keys_to_file()
        self.show_status_message("API Keys saved to config file.", "green")

    def _get_config_path(self) -> str:
        home = os.path.expanduser("~")
        config_dir = os.path.join(home, ".config", "Segmenter")
        os.makedirs(config_dir, exist_ok=True)
        return os.path.join(config_dir, "keys.json")

    def _load_keys_from_file(self):
        path = self._get_config_path()
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    self.the_introdb_api_key = data.get("theintrodb_api_key", "")
                    self.introdb_api_key = data.get("introdb_api_key", "")
                    self.tmdb_api_key = data.get("tmdb_api_key", "")
            except Exception:
                self.the_introdb_api_key = ""
                self.introdb_api_key = ""
                self.tmdb_api_key = ""
        else:
            self.the_introdb_api_key = ""
            self.introdb_api_key = ""
            self.tmdb_api_key = ""

    def _save_keys_to_file(self):
        path = self._get_config_path()
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump({
                    "theintrodb_api_key": self.the_introdb_api_key,
                    "introdb_api_key": self.introdb_api_key,
                    "tmdb_api_key": self.tmdb_api_key
                }, f, indent=4)
        except Exception as e:
            QMessageBox.warning(self, "Save Error", f"Could not save keys to config file: {str(e)}")

    def _on_open_video_clicked(self):
        file_filter = "Videos (*.mp4 *.mkv *.avi *.mov *.m4v *.mpeg)"
        # Support QUrl to allow remote network shares (SMB, SFTP, NFS, HTTP, etc.)
        url, _ = QFileDialog.getOpenFileUrl(self, "Open Video File", QUrl(), file_filter)
        if url.isValid() and not url.isEmpty():
            if url.isLocalFile():
                self.load_video(url.toLocalFile())
            else:
                self.load_video(url.toString())

    def load_video(self, file_path: str):
        # Cancel any running audio extractions
        if self.audio_worker:
            self.audio_worker.cancel()
            self.audio_worker.wait()
            self.audio_worker = None

        self.selected_video_url = file_path
        
        # Get filename correctly from URL or local path
        if file_path.startswith(("http://", "https://", "smb://", "nfs://", "sftp://", "ftp://", "file://")):
            parsed = urllib.parse.urlparse(file_path)
            filename = os.path.basename(urllib.parse.unquote(parsed.path))
        else:
            filename = os.path.basename(file_path)

        self.video_title_lbl.setText(filename)
        self.show_status_message(f"Loaded {filename}", "green")
        
        # Reset timeline and drafts
        self.server_segments = {t: [] for t in SegmentType}
        
        # Check if RCD has cached detections for this file
        filename = os.path.basename(file_path)
        has_rcd = hasattr(self, "rcd_results") and self.rcd_results and filename in self.rcd_results
        logger.debug(f"Loading video '{filename}'. Cache hit: {has_rcd}")

        if has_rcd:
            self.local_drafts = {t: [] for t in SegmentType}
            self._pending_rcd_detections = self.rcd_results[filename]
        else:
            self.local_drafts = {t: [SegmentDraft.empty()] for t in SegmentType}
            self._pending_rcd_detections = None

        self.audio_track = TimelineDensityTrack.empty()
        self.undo_stack.clear()

        # Defer timeline label setup and widget update until video duration is known.
        # This prevents premature width jumps.
        # self._setup_timeline_labels()
        # self.update_timeline_widget()

        self._ensure_audio_track()

        # Load video into player (duration will be set via signal)
        self.player.load_video(file_path)
        self.framestrip.set_video_context(file_path, 0, self.player.frame_rate)
        
        # Filename auto lookup
        hint = FilenameMediaParser.parse(filename)
        self.type_combo.setCurrentIndex(0 if hint.media_type_hint == MediaType.MOVIE else 1)
        self.season_edit.setText(str(hint.season) if hint.season is not None else "")
        self.episode_edit.setText(str(hint.episode) if hint.episode is not None else "")
        
        # Run TMDB resolution in thread pool
        if self.tmdb_api_key:
            self.auto_lookup_lbl.setText("Resolving filename on TMDB...")
            self.thread_pool.submit(self._run_auto_lookup, hint)
        else:
            self.auto_lookup_lbl.setText("TMDB Key missing. Fill key to lookup.")

    def _ensure_audio_track(self):
        if self.selected_video_url and self.video_duration_ms > 0 and not self.audio_track.has_content and not self.audio_worker:
            logger.debug("Ensuring audio track for %s", self.selected_video_url)
            self.waveform_progress_container.setVisible(True)
            self.waveform_progress_bar.setValue(0)
            
            self.audio_worker = AudioExtractorWorker(self.selected_video_url, self.video_duration_ms)
            self.audio_worker.progress.connect(self.waveform_progress_bar.setValue)
            self.audio_worker.waveform_ready.connect(self._on_waveform_ready)
            self.audio_worker.music_ready.connect(self._on_music_ready)
            self.audio_worker.finished.connect(self._on_audio_finished)
            self.audio_worker.start()

    def _run_auto_lookup(self, hint: ParsedFilenameHint):
        try:
            results = self.tmdb_client.resolve_hints(hint, self.tmdb_api_key, limit=6)
            # Run UI updates back on main thread
            QTimer.singleShot(0, lambda: self._on_auto_lookup_complete(results))
        except Exception as e:
            QTimer.singleShot(0, lambda: self.auto_lookup_lbl.setText(f"Lookup failed: {str(e)}"))

    def _on_auto_lookup_complete(self, results: List[AutoLookupResult]):
        self.tmdb_candidates = results
        self.tmdb_match_combo.clear()
        self.tmdb_match_combo.disconnect()
        
        if not results:
            self.auto_lookup_lbl.setText("No TMDB candidates found.")
            self.tmdb_match_combo.setVisible(False)
            return

        self.tmdb_match_combo.setVisible(True)
        for r in results:
            year_str = f" ({r.matched_year})" if r.matched_year else ""
            self.tmdb_match_combo.addItem(f"{r.title}{year_str} • TMDB {r.tmdb_id}", r.tmdb_id)
        
        self.tmdb_match_combo.currentIndexChanged.connect(self._on_tmdb_candidate_selected)
        
        # Apply the first candidate
        self._apply_auto_lookup_candidate(results[0])
        # Auto-load segments
        self._on_load_segments_clicked()

    def _on_tmdb_candidate_selected(self, index: int):
        if 0 <= index < len(self.tmdb_candidates):
            candidate = self.tmdb_candidates[index]
            self._apply_auto_lookup_candidate(candidate)
            # Auto-load segments
            self._on_load_segments_clicked()

    def _apply_auto_lookup_candidate(self, candidate: AutoLookupResult):
        self.selected_candidate_tmdb_id = candidate.tmdb_id
        self.tmdb_id_edit.setText(str(candidate.tmdb_id))
        self.imdb_id_edit.setText(candidate.imdb_id or "")
        self.type_combo.setCurrentIndex(0 if candidate.media_type == MediaType.MOVIE else 1)
        if candidate.season is not None:
            self.season_edit.setText(str(candidate.season))
        if candidate.episode is not None:
            self.episode_edit.setText(str(candidate.episode))
        self.auto_lookup_lbl.setText(f"Matched: {candidate.title} (TMDB {candidate.tmdb_id})")

    def _on_media_type_changed(self, index: int):
        is_tv = (self.type_combo.currentData() == MediaType.TV)
        self.tv_layout_widget.setVisible(is_tv)

    def _on_search_tmdb(self):
        title = self.search_edit.text().strip()
        if not title:
            return
        if not self.tmdb_api_key:
            self.show_status_message("TMDB API key is missing.", "red")
            return
        
        self.show_status_message("Searching TMDB...", "secondary")
        m_type = self.type_combo.currentData()
        self.thread_pool.submit(self._run_tmdb_search, title, m_type)

    def _run_tmdb_search(self, title: str, media_type: MediaType):
        try:
            results = self.tmdb_client.search(title, media_type, self.tmdb_api_key, limit=10)
            QTimer.singleShot(0, lambda: self._on_tmdb_search_complete(results))
        except Exception as e:
            QTimer.singleShot(0, lambda: self.show_status_message(f"Search failed: {str(e)}", "red"))

    def _on_tmdb_search_complete(self, results: List[AutoLookupResult]):
        self.tmdb_candidates = results
        self.search_results_combo.clear()
        self.search_results_combo.disconnect()
        
        if not results:
            self.show_status_message("No search results found.", "red")
            self.search_results_combo.setVisible(False)
            return

        self.search_results_combo.setVisible(True)
        self.search_results_combo.addItem("Select result...")
        for r in results:
            year_str = f" ({r.matched_year})" if r.matched_year else ""
            self.search_results_combo.addItem(f"{r.title}{year_str} • TMDB {r.tmdb_id}", r.tmdb_id)
            
        self.search_results_combo.currentIndexChanged.connect(self._on_search_result_selected)
        self.show_status_message(f"Found {len(results)} results.", "green")

    def _on_search_result_selected(self, index: int):
        if index <= 0:  # "Select result..." placeholder
            return
        candidate_idx = index - 1
        if 0 <= candidate_idx < len(self.tmdb_candidates):
            candidate = self.tmdb_candidates[candidate_idx]
            self._apply_auto_lookup_candidate(candidate)
            self.search_results_combo.setVisible(False)
            self.search_edit.clear()
            self._on_load_segments_clicked()

    def _on_load_segments_clicked(self):
        # 1. Start audio extraction if needed
        self._ensure_audio_track()

        # 2. Fetch media segments from servers
        tmdb_id = self._get_int(self.tmdb_id_edit.text())
        imdb_id = self.imdb_id_edit.text().strip() or None
        media_type = self.type_combo.currentData()
        season = self._get_int(self.season_edit.text()) if media_type == MediaType.TV else None
        episode = self._get_int(self.episode_edit.text()) if media_type == MediaType.TV else None

        if tmdb_id is None and imdb_id is None:
            self.show_status_message("Provide TMDB ID or IMDB ID to load segments.", "red")
            return

        query = MediaQuery(
            tmdb_id=tmdb_id,
            imdb_id=imdb_id,
            season=season,
            episode=episode,
            duration_ms=self.video_duration_ms if self.video_duration_ms > 0 else None
        )
        self.show_status_message("Fetching existing segments...", "secondary")
        self.thread_pool.submit(self._run_segment_fetch, query, media_type)

    def _run_segment_fetch(self, query: MediaQuery, media_type: MediaType):
        success_by_service = {}
        errors = {}

        # Parallel fetch from TheIntroDB and IntroDB
        theintro_api = self.the_introdb_api_key.strip() or None
        intro_api = self.introdb_api_key.strip() or None
        
        # 1. Fetch TheIntroDB
        try:
            payload, usage = self.the_introdb_client.fetch_media(query, theintro_api)
            # Map grouped SegmentRange
            intro = [SegmentRange.from_dict(d) for d in payload.get("intro", []) or []]
            recap = [SegmentRange.from_dict(d) for d in payload.get("recap", []) or []]
            credits = [SegmentRange.from_dict(d) for d in payload.get("credits", []) or []]
            preview = [SegmentRange.from_dict(d) for d in payload.get("preview", []) or []]
            
            success_by_service["TheIntroDB"] = {
                "segments": {
                    SegmentType.INTRO: intro,
                    SegmentType.RECAP: recap,
                    SegmentType.CREDITS: credits,
                    SegmentType.PREVIEW: preview
                },
                "tmdb_id": payload.get("tmdb_id"),
                "usage": usage
            }
        except Exception as e:
            errors["TheIntroDB"] = e

        # 2. Fetch IntroDB (TV episodes only)
        if media_type == MediaType.TV and query.imdb_id and query.season and query.episode:
            try:
                payload, usage = self.introdb_client.fetch_segments(query.imdb_id, query.season, query.episode, intro_api)
                
                # IntroDB maps outro -> credits, doesn't support preview
                intro_ag = payload.get("intro")
                recap_ag = payload.get("recap")
                outro_ag = payload.get("outro")
                
                intro = [SegmentRange(start_ms=intro_ag["start_ms"], end_ms=intro_ag["end_ms"])] if intro_ag else []
                recap = [SegmentRange(start_ms=recap_ag["start_ms"], end_ms=recap_ag["end_ms"])] if recap_ag else []
                credits = [SegmentRange(start_ms=outro_ag["start_ms"], end_ms=outro_ag["end_ms"])] if outro_ag else []
                
                success_by_service["IntroDB"] = {
                    "segments": {
                        SegmentType.INTRO: intro,
                        SegmentType.RECAP: recap,
                        SegmentType.CREDITS: credits,
                        SegmentType.PREVIEW: []
                    },
                    "usage": usage
                }
            except Exception as e:
                errors["IntroDB"] = e

        # Callback on main thread
        QTimer.singleShot(0, lambda: self._on_segment_fetch_complete(success_by_service, errors))

    def _on_segment_fetch_complete(self, success_by_service, errors):
        if not success_by_service:
            # Handle error reporting
            err_msg = ""
            for s, e in errors.items():
                if isinstance(e, APIClientError):
                    err_msg += f"{s}: {e.message} ({e.status_code}); "
                else:
                    err_msg += f"{s}: {str(e)}; "
            self.show_status_message(f"Load failed: {err_msg}", "red")
            return

        # Merge segments: TheIntroDB is primary, IntroDB fallback
        merged = {t: [] for t in SegmentType}
        theintro = success_by_service.get("TheIntroDB", {}).get("segments", {})
        introdb = success_by_service.get("IntroDB", {}).get("segments", {})

        for t in SegmentType:
            primary = theintro.get(t, [])
            fallback = introdb.get(t, [])
            merged[t] = primary if primary else fallback

        self.server_segments = merged
        
        # Populate TMDB ID if fetched
        fetched_tmdb = success_by_service.get("TheIntroDB", {}).get("tmdb_id")
        if fetched_tmdb:
            self.tmdb_id_edit.setText(str(fetched_tmdb))

        # Auto-prefill drafts from server segments
        before = copy.deepcopy(self.local_drafts)
        for t in SegmentType:
            self.local_drafts[t] = [SegmentDraft(start_ms=r.start_ms, end_ms=r.end_ms) for r in merged[t]]
            if not self.local_drafts[t]:
                self.local_drafts[t] = [SegmentDraft.empty()]
        
        # Push to undo stack
        self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Load server segments"))
        self.update_timeline_widget()

        # Update limit rate
        usage_chunks = []
        for s, data in success_by_service.items():
            u = data.get("usage")
            if u and u.short_description != "No limit headers":
                usage_chunks.append(f"{s}: {u.short_description}")
        self.status_rate_lbl.setText(" | ".join(usage_chunks))
        self.show_status_message("Loaded segments successfully.", "green")

    def _on_waveform_ready(self, buckets: list[float]):
        logger.debug("Waveform ready with %d buckets", len(buckets))
        self.audio_track.label = "Audio"
        self.audio_track.buckets = buckets
        self._setup_timeline_labels()
        self.update_timeline_widget()


    def _on_music_ready(self, buckets: list[float]):
        logger.debug("Music likelihood ready with %d buckets", len(buckets))
        self.audio_track.music_likelihood_buckets = buckets
        self.update_timeline_widget()


    def _on_audio_finished(self, success: bool, message: str):
        self.waveform_progress_container.setVisible(False)
        if not success and message != "Cancelled":
            logger.error("Audio extraction failed: %s", message)
            QMessageBox.warning(self, "Audio Error", f"Audio waveform calculation failed:\n{message}")

    def _on_player_time_changed(self, time_ms: int):
        self.timeline.current_time_ms = time_ms
        self.timeline.update()
        
        is_playing = self.player.is_playing()
        is_stepping = not is_playing and self._is_stepping_key
        self.framestrip.update_position(time_ms, is_stepping=is_stepping)
        self._is_stepping_key = False

    def _on_player_duration_changed(self, duration_ms: int):
        self.video_duration_ms = duration_ms
        self.framestrip.set_video_context(self.selected_video_url, duration_ms, self.player.frame_rate)
        
        # If we have pending RCD detections, populate them now (or apply immediately if video duration already known)
        if getattr(self, "_pending_rcd_detections", None) is not None:
            # Use already known video duration if available, otherwise wait for duration signal
            if duration_ms > 0:
                self._apply_pending_rcd_detections(duration_ms)
            else:
                # Will be handled later when duration becomes available
                pass

        self.update_timeline_widget()
        self._ensure_audio_track()

    def _apply_pending_rcd_detections(self, duration_ms: int):
        """Convert pending RCD detections (list of [start_s, end_s]) into local_drafts."""
        detections = self._pending_rcd_detections
        self._pending_rcd_detections = None

        if not detections:
            logger.debug("No pending RCD detections to apply")
            return

        logger.info("Applying %d RCD detections to timeline", len(detections))

        # Reset drafts for a clean slate
        self.local_drafts = {t: [] for t in SegmentType}

        # Heuristic mapping:
        #   1 detection  → INTRO
        #   2 detections → first=INTRO, last=CREDITS
        #   3+ detections → first=INTRO, last=CREDITS, middle=RECAP(s)
        for i, det in enumerate(detections):
            try:
                start_s, end_s = float(det[0]), float(det[1])
                start_ms = int(start_s * 1000)
                end_ms = int(end_s * 1000)

                # Clamp to video duration
                start_ms = max(0, min(start_ms, duration_ms))
                end_ms = max(0, min(end_ms, duration_ms))

                if end_ms <= start_ms:
                    continue

                draft = SegmentDraft(start_ms=start_ms, end_ms=end_ms)

                if i == 0:
                    seg_type = SegmentType.INTRO
                elif i == len(detections) - 1 and len(detections) > 1:
                    seg_type = SegmentType.CREDITS
                else:
                    seg_type = SegmentType.RECAP

                self.local_drafts[seg_type].append(draft)
                logger.debug("  RCD → %s: %d–%d ms", seg_type.value, start_ms, end_ms)
            except (IndexError, ValueError, TypeError) as e:
                logger.warning("Skipping invalid RCD detection %r: %s", det, e)

        # Ensure every type has at least an empty placeholder if nothing was assigned
        for t in SegmentType:
            if not self.local_drafts[t]:
                self.local_drafts[t] = [SegmentDraft.empty()]

        self._setup_timeline_labels()
        self.update_timeline_widget()
        self.show_status_message(f"Applied {len(detections)} RCD detections", "green")

    def _on_playback_state_changed(self, is_playing: bool):
        if is_playing:
            self.framestrip.set_temporal_mode("coarse")

    def _on_player_framerate_resolved(self, fps: float):
        if self.video_duration_ms > 0:
            self.framestrip.set_video_context(self.selected_video_url, self.video_duration_ms, fps)

    def update_timeline_widget(self):
        logger.debug("Updating timeline widget")
        # Calculate maximum bounds for timeline view duration
        max_bound = self.video_duration_ms
        for t in SegmentType:
            for s in self.server_segments.get(t, []):
                if s.end_ms: max_bound = max(max_bound, s.end_ms)
                if s.start_ms: max_bound = max(max_bound, s.start_ms)
            for d in self.local_drafts.get(t, []):
                if d.end_ms: max_bound = max(max_bound, d.end_ms)
                if d.start_ms: max_bound = max(max_bound, d.start_ms)
        
        effective_duration = max(max_bound, 60_000)
        
        # Calculate minimum zoom level to fit timeline width
        viewport_width = self.timeline_scroll.viewport().width()
        base_width = (effective_duration / 1000.0) * 8.0
        fit_zoom = viewport_width / base_width if base_width > 0 else 1.0
        self.minimum_zoom_level = min(max(fit_zoom, 0.05), 1.0)
        
        if self.zoom_level < self.minimum_zoom_level:
            self.zoom_level = self.minimum_zoom_level

        # Only refresh if we have something to display
        if effective_duration > 0:
            self.timeline.set_data(
                duration_ms=effective_duration,
                video_duration_ms=self.video_duration_ms,
                current_time_ms=self.player.current_position(),
                zoom=self.zoom_level,
                minimum_zoom=self.minimum_zoom_level,
                server_segments=self.server_segments,
                drafts=self.local_drafts,
                audio_track=self.audio_track
            )
        else:
            logger.warning("Timeline not updated: effective duration is zero")

        # Update sidebar editor row inputs
        for t in SegmentType:
            self.editor_rows[t].update_draft_values(self.local_drafts.get(t, []))

    def begin_undo_drag_capture(self):
        self._undo_capture_before = copy.deepcopy(self.local_drafts)

    def end_undo_drag_capture(self):
        if hasattr(self, "_undo_capture_before") and self._undo_capture_before != self.local_drafts:
            self.undo_stack.push(
                DraftChangeCommand(self, self._undo_capture_before, self.local_drafts, "Timeline drag action")
            )
            delattr(self, "_undo_capture_before")

    # Segment model mutations
    def create_draft_range(self, segment_type: SegmentType, start_ms: int, end_ms: int):
        before = copy.deepcopy(self.local_drafts)
        adjusted = self._adjusted_non_overlapping_range(segment_type, start_ms, end_ms)
        if not adjusted:
            self.show_status_message("Could not place segment: overlaps another segment.", "red")
            return
            
        drafts = self.local_drafts.get(segment_type, [])
        # Remove empty draft placeholder if present
        drafts = [d for d in drafts if not d.is_empty()]
        drafts.append(SegmentDraft(start_ms=adjusted[0], end_ms=adjusted[1]))
        self.local_drafts[segment_type] = self._normalize_and_sort_drafts(drafts)
        
        self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Create segment"))
        self.update_timeline_widget()

    def set_draft_boundary_ms(self, segment_type: SegmentType, edge: str, ms: Optional[int]):
        before = copy.deepcopy(self.local_drafts)
        drafts = self.local_drafts.get(segment_type, [])
        if not drafts:
            drafts = [SegmentDraft.empty()]
            
        # Modify the last/active draft
        active_idx = len(drafts) - 1
        d = drafts[active_idx]
        
        if edge == "start":
            d.start_ms = ms
        else:
            d.end_ms = ms
            
        # Re-validate overlapping constraints if full range
        if d.start_ms is not None and d.end_ms is not None:
            adjusted = self._adjusted_non_overlapping_range(segment_type, d.start_ms, d.end_ms, exclude=(segment_type, active_idx))
            if adjusted:
                d.start_ms, d.end_ms = adjusted
            else:
                self.show_status_message("Segment overlaps another.", "red")
                return
                
        drafts[active_idx] = d
        self.local_drafts[segment_type] = self._normalize_and_sort_drafts(drafts)
        
        self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, f"Set {edge} boundary"))
        self.update_timeline_widget()

    def set_draft_start_ms(self, segment_type: SegmentType, idx: int, ms: int):
        # Callback from timeline resizing drag
        drafts = self.local_drafts.get(segment_type, [])
        if 0 <= idx < len(drafts):
            d = drafts[idx]
            d.start_ms = max(0, ms)
            if d.end_ms is not None and d.start_ms >= d.end_ms:
                d.start_ms = d.end_ms - 100
                
            # Perform collision adjustment
            adj = self._adjusted_non_overlapping_range(segment_type, d.start_ms, d.end_ms or d.start_ms+1000, exclude=(segment_type, idx))
            if adj:
                d.start_ms = adj[0]
                if d.end_ms is not None:
                    d.end_ms = adj[1]
            drafts[idx] = d
            self.local_drafts[segment_type] = self._normalize_and_sort_drafts(drafts)
            self.update_timeline_widget()

    def set_draft_end_ms(self, segment_type: SegmentType, idx: int, ms: int):
        # Callback from timeline resizing drag
        drafts = self.local_drafts.get(segment_type, [])
        if 0 <= idx < len(drafts):
            d = drafts[idx]
            d.end_ms = max(0, ms)
            if d.start_ms is not None and d.end_ms <= d.start_ms:
                d.end_ms = d.start_ms + 100
                
            # Perform collision adjustment
            adj = self._adjusted_non_overlapping_range(segment_type, d.start_ms or d.end_ms-1000, d.end_ms, exclude=(segment_type, idx))
            if adj:
                if d.start_ms is not None:
                    d.start_ms = adj[0]
                d.end_ms = adj[1]
            drafts[idx] = d
            self.local_drafts[segment_type] = self._normalize_and_sort_drafts(drafts)
            self.update_timeline_widget()

    def move_draft(self, src_type: SegmentType, idx: int, target_type: SegmentType, start_ms: int, end_ms: int):
        before = copy.deepcopy(self.local_drafts)
        
        # 1. Remove from source
        src_drafts = self.local_drafts.get(src_type, [])
        if not (0 <= idx < len(src_drafts)):
            return
        src_drafts.pop(idx)
        if not src_drafts:
            src_drafts = [SegmentDraft.empty()]
        self.local_drafts[src_type] = src_drafts
        
        # 2. Add to target with non-overlap collision resolution
        target_drafts = self.local_drafts.get(target_type, [])
        # Remove empty draft placeholder if present
        target_drafts = [d for d in target_drafts if not d.is_empty()]
        
        adjusted = self._adjusted_non_overlapping_range(target_type, start_ms, end_ms)
        if adjusted:
            target_drafts.append(SegmentDraft(start_ms=adjusted[0], end_ms=adjusted[1]))
            self.local_drafts[target_type] = self._normalize_and_sort_drafts(target_drafts)
            self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Move segment track"))
        else:
            # Revert
            self.local_drafts = before
            self.show_status_message("Move failed: overlaps an existing segment.", "red")
            
        self.update_timeline_widget()

    def clear_draft(self, segment_type: SegmentType):
        before = copy.deepcopy(self.local_drafts)
        self.local_drafts[segment_type] = [SegmentDraft.empty()]
        self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Clear track"))
        self.update_timeline_widget()

    def upload_segment(self, segment_type: SegmentType):
        # Single segment upload
        drafts = [d for d in self.local_drafts.get(segment_type, []) if not d.is_empty()]
        if not drafts:
            QMessageBox.warning(self, "Upload Error", f"No draft segments to upload for {segment_type.display_name}")
            return
            
        context = self._make_upload_context()
        if not context:
            return
            
        targets = self._get_upload_targets(segment_type, context)
        if not targets:
            QMessageBox.warning(self, "Upload Error", "No compatible API configuration found (keys / IDs missing)")
            return

        self.show_status_message(f"Uploading {segment_type.display_name} segment...", "secondary")
        self.thread_pool.submit(self._run_upload, segment_type, drafts, targets, context)

    def upload_all_segments(self):
        context = self._make_upload_context()
        if not context:
            return
            
        payloads_to_run = []
        for t in SegmentType:
            drafts = [d for d in self.local_drafts.get(t, []) if not d.is_empty()]
            if not drafts:
                continue
            targets = self._get_upload_targets(t, context)
            if targets:
                payloads_to_run.append((t, drafts, targets))
                
        if not payloads_to_run:
            QMessageBox.information(self, "Upload", "No segment drafts to upload.")
            return

        self.show_status_message("Uploading all segments...", "secondary")
        self.thread_pool.submit(self._run_upload_all, payloads_to_run, context)

    def _run_upload(self, segment_type: SegmentType, drafts: List[SegmentDraft], targets: List[str], context: Dict[str, Any]):
        try:
            print(f"[UploadWorker] Starting single upload for segment {segment_type.display_name}. Targets: {targets}, drafts: {len(drafts)}")
            errors = []
            success_count = 0
            last_usage = None

            for d in drafts:
                draft_obj = SubmissionDraft(
                    tmdb_id=context["tmdb_id"] or 0,
                    imdb_id=context["imdb_id"],
                    media_type=self.type_combo.currentData(),
                    segment=segment_type,
                    season=context["season"],
                    episode=context["episode"],
                    start_ms=d.start_ms,
                    end_ms=d.end_ms,
                    video_duration_ms=self.video_duration_ms if self.video_duration_ms > 0 else None
                )
                
                for service in targets:
                    try:
                        print(f"[UploadWorker] Uploading draft {d.start_ms}ms - {d.end_ms}ms to {service}...")
                        if service == "TheIntroDB":
                            body = SegmentValidator.make_the_introdb_submission_request(draft_obj)
                            print(f"[UploadWorker] TheIntroDB payload: {body}")
                            res, usage = self.the_introdb_client.submit(body, context["theintro_key"])
                            last_usage = usage
                        else:  # IntroDB
                            body = SegmentValidator.make_introdb_submission_request(draft_obj)
                            print(f"[UploadWorker] IntroDB payload: {body}")
                            res, usage = self.introdb_client.submit(body, context["introdb_key"])
                            last_usage = usage
                        print(f"[UploadWorker] {service} submit successful!")
                        success_count += 1
                    except Exception as e:
                        print(f"[UploadWorker] Exception during {service} upload: {str(e)}")
                        errors.append(f"{service}: {str(e)}")

            print(f"[UploadWorker] Done. Success: {success_count}/{len(drafts) * len(targets)}, errors: {len(errors)}")
            QTimer.singleShot(0, lambda: self._on_upload_complete(segment_type, success_count, len(drafts) * len(targets), errors, last_usage))
        except Exception as e:
            print(f"[UploadWorker] Fatal exception in upload worker: {str(e)}")
            QTimer.singleShot(0, lambda: self.show_status_message(f"Upload execution failed: {str(e)}", "red"))

    def _on_upload_complete(self, segment_type: SegmentType, success: int, total: int, errors: List[str], usage: Optional[UsageHeaders]):
        if errors:
            self.show_status_message(f"Upload completed with errors: {'; '.join(errors[:2])}", "red")
        else:
            self.show_status_message(f"Successfully uploaded {segment_type.display_name} segments ({success}/{total})", "green")
            # Clear drafts on success
            self.clear_draft(segment_type)
            # Re-fetch segments
            self._on_load_segments_clicked()

    def _run_upload_all(self, payloads_to_run, context: Dict[str, Any]):
        try:
            print(f"[UploadWorker] Starting bulk upload for all drafts. Payloads: {len(payloads_to_run)}")
            errors = []
            success_count = 0
            total_count = 0
            last_usage = None

            for t, drafts, targets in payloads_to_run:
                print(f"[UploadWorker] Processing category {t.display_name}: drafts count={len(drafts)}, targets={targets}")
                for d in drafts:
                    draft_obj = SubmissionDraft(
                        tmdb_id=context["tmdb_id"] or 0,
                        imdb_id=context["imdb_id"],
                        media_type=self.type_combo.currentData(),
                        segment=t,
                        season=context["season"],
                        episode=context["episode"],
                        start_ms=d.start_ms,
                        end_ms=d.end_ms,
                        video_duration_ms=self.video_duration_ms if self.video_duration_ms > 0 else None
                    )
                    
                    for service in targets:
                        total_count += 1
                        try:
                            print(f"[UploadWorker] Uploading {t.display_name} draft ({d.start_ms}ms - {d.end_ms}ms) to {service}...")
                            if service == "TheIntroDB":
                                body = SegmentValidator.make_the_introdb_submission_request(draft_obj)
                                print(f"[UploadWorker] TheIntroDB payload: {body}")
                                res, usage = self.the_introdb_client.submit(body, context["theintro_key"])
                                last_usage = usage
                            else:  # IntroDB
                                body = SegmentValidator.make_introdb_submission_request(draft_obj)
                                print(f"[UploadWorker] IntroDB payload: {body}")
                                res, usage = self.introdb_client.submit(body, context["introdb_key"])
                                last_usage = usage
                            print(f"[UploadWorker] {service} submit successful!")
                            success_count += 1
                        except Exception as e:
                            print(f"[UploadWorker] Exception during {t.display_name} ({service}) upload: {str(e)}")
                            errors.append(f"{t.display_name} ({service}): {str(e)}")

            print(f"[UploadWorker] Bulk upload finished. Success: {success_count}/{total_count}, errors: {len(errors)}")
            QTimer.singleShot(0, lambda: self._on_upload_all_complete(success_count, total_count, errors, last_usage))
        except Exception as e:
            print(f"[UploadWorker] Fatal exception in bulk upload worker: {str(e)}")
            QTimer.singleShot(0, lambda: self.show_status_message(f"Upload execution failed: {str(e)}", "red"))

    def _on_upload_all_complete(self, success: int, total: int, errors: List[str], usage: Optional[UsageHeaders]):
        if errors:
            self.show_status_message(f"Upload completed with errors: {'; '.join(errors[:2])}", "red")
        else:
            self.show_status_message(f"Successfully uploaded all segments ({success}/{total})", "green")
            # Clear drafts
            before = copy.deepcopy(self.local_drafts)
            self.local_drafts = {t: [SegmentDraft.empty()] for t in SegmentType}
            self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Clear all after upload"))
            self.update_timeline_widget()
            # Re-fetch segments
            self._on_load_segments_clicked()

    def _make_upload_context(self) -> Optional[Dict[str, Any]]:
        tmdb_id = self._get_int(self.tmdb_id_edit.text())
        imdb_id = self.imdb_id_edit.text().strip() or None
        media_type = self.type_combo.currentData()
        season = self._get_int(self.season_edit.text()) if media_type == MediaType.TV else None
        episode = self._get_int(self.episode_edit.text()) if media_type == MediaType.TV else None

        theintro_key = self.the_introdb_api_key.strip()
        introdb_key = self.introdb_api_key.strip()

        if not theintro_key and not introdb_key:
            QMessageBox.critical(self, "Upload Error", "At least one API key (TheIntroDB or IntroDB) is required.")
            return None

        return {
            "tmdb_id": tmdb_id,
            "imdb_id": imdb_id,
            "season": season,
            "episode": episode,
            "theintro_key": theintro_key,
            "introdb_key": introdb_key
        }

    def _get_upload_targets(self, segment_type: SegmentType, context: Dict[str, Any]) -> List[str]:
        targets = []
        # TheIntroDB upload requirements (requires key and at least tmdb_id or imdb_id)
        has_id = (context["tmdb_id"] and context["tmdb_id"] > 0) or context["imdb_id"]
        if context["theintro_key"] and has_id:
            targets.append("TheIntroDB")
            
        # IntroDB upload requirements (TV segments only, preview not supported, requires imdb_id)
        if (context["introdb_key"] and 
            self.type_combo.currentData() == MediaType.TV and 
            context["imdb_id"] and 
            context["season"] and 
            context["episode"] and 
            segment_type in (SegmentType.INTRO, SegmentType.RECAP, SegmentType.CREDITS)):
            targets.append("IntroDB")
            
        return targets

    def keyPressEvent(self, event):
        # Keyboard shortcuts
        # Standard QShortcut can be used, or keyPressEvent overrides
        key = event.key()
        modifiers = event.modifiers()
        
        # Check hotkeys matching macOS
        # I / Shift+I = Intro start / end
        # R / Shift+R = Recap start / end
        # C / Shift+C = Credits start / end
        # P / Shift+P = Preview start / end
        # , (comma) = Move nearest boundary to playhead
        if modifiers == Qt.NoModifier:
            if key == Qt.Key_I:
                self._set_draft_marker(SegmentType.INTRO, "start")
            elif key == Qt.Key_R:
                self._set_draft_marker(SegmentType.RECAP, "start")
            elif key == Qt.Key_C:
                self._set_draft_marker(SegmentType.CREDITS, "start")
            elif key == Qt.Key_P:
                self._set_draft_marker(SegmentType.PREVIEW, "start")
            elif key == Qt.Key_Comma:
                self.move_nearest_boundary_to_playhead()
            elif key == Qt.Key_Left:
                self._is_stepping_key = True
                self.player.step_backward()
                event.accept()
                return
            elif key == Qt.Key_Right:
                self._is_stepping_key = True
                self.player.step_forward()
                event.accept()
                return
            elif key == Qt.Key_Space:
                self.player.toggle_play()
                event.accept()
                return
        elif modifiers == Qt.ShiftModifier:
            if key == Qt.Key_I:
                self._set_draft_marker(SegmentType.INTRO, "end")
            elif key == Qt.Key_R:
                self._set_draft_marker(SegmentType.RECAP, "end")
            elif key == Qt.Key_C:
                self._set_draft_marker(SegmentType.CREDITS, "end")
            elif key == Qt.Key_P:
                self._set_draft_marker(SegmentType.PREVIEW, "end")
                
        # Undo / Redo
        if modifiers == Qt.ControlModifier:
            if key == Qt.Key_Z:
                self.undo_stack.undo()
            elif key == Qt.Key_Y:
                self.undo_stack.redo()

        super().keyPressEvent(event)

    def _set_draft_marker(self, segment_type: SegmentType, edge: str):
        pos = self.player.current_position()
        self.set_draft_boundary_ms(segment_type, edge, pos)

    def move_nearest_boundary_to_playhead(self):
        playhead = self.player.current_position()
        
        # Find closest boundary (start or end) of any draft
        best_dist = float("inf")
        best_seg = None
        best_idx = None
        best_edge = None
        
        for t in SegmentType:
            drafts = self.local_drafts.get(t, [])
            for idx, d in enumerate(drafts):
                if d.start_ms is not None:
                    dist = abs(d.start_ms - playhead)
                    if dist < best_dist:
                        best_dist = dist
                        best_seg = t
                        best_idx = idx
                        best_edge = "start"
                if d.end_ms is not None:
                    dist = abs(d.end_ms - playhead)
                    if dist < best_dist:
                        best_dist = dist
                        best_seg = t
                        best_idx = idx
                        best_edge = "end"
                        
        if best_seg is not None:
            before = copy.deepcopy(self.local_drafts)
            drafts = self.local_drafts[best_seg]
            d = drafts[best_idx]
            
            if best_edge == "start":
                d.start_ms = playhead
            else:
                d.end_ms = playhead
                
            drafts[best_idx] = d
            self.local_drafts[best_seg] = self._normalize_and_sort_drafts(drafts)
            
            self.undo_stack.push(DraftChangeCommand(self, before, self.local_drafts, "Move boundary to playhead"))
            self.update_timeline_widget()
            self.show_status_message("Moved nearest segment boundary to playhead.", "green")

    # Timeline zoom helper
    def wheelEvent(self, event):
        # Horizontal zooming inside timeline view
        # Checks if hovering scroll area and Ctrl modifier is pressed
        pos = self.timeline_scroll.mapFromGlobal(event.globalPosition().toPoint())
        in_timeline = self.timeline_scroll.rect().contains(pos)
        
        if in_timeline and (event.modifiers() & Qt.ControlModifier or event.angleDelta().y() != 0):
            # Calculate time point under cursor
            timeline_pos = self.timeline.mapFromGlobal(event.globalPosition().toPoint())
            time_under_cursor = self.position_to_ms(timeline_pos.x())
            viewport_cursor_x = pos.x()
            
            delta_y = event.angleDelta().y()
            sensitivity = 0.002
            factor = math.exp(delta_y * sensitivity)
            
            old_zoom = self.zoom_level
            new_zoom = min(max(old_zoom * factor, self.minimum_zoom_level), 8.0)
            
            if new_zoom != old_zoom:
                self.zoom_level = new_zoom
                self.update_timeline_widget()
                
                # Scroll post-zoom to align time under cursor
                new_x = self.ms_to_position(time_under_cursor) - viewport_cursor_x
                self.timeline_scroll.horizontalScrollBar().setValue(int(new_x))
            event.accept()
        else:
            super().wheelEvent(event)

    def seek_player(self, ms: int):
        self.player.seek(ms)

    def show_status_message(self, message: str, color_type: str = "secondary"):
        color = "#e1e1e6"
        if color_type == "red":
            color = "#ff453a"
        elif color_type == "green":
            color = "#30d158"
        elif color_type == "secondary":
            color = "#8e8e93"
            
        self.status_msg_lbl.setStyleSheet(f"color: {color}; font-size: 11px;")
        self.status_msg_lbl.setText(message)

    # Internal math utilities
    def _adjusted_non_overlapping_range(self, segment_type: SegmentType, start: int, end: int, exclude: Optional[tuple[SegmentType, int]] = None) -> Optional[tuple[int, int]]:
        if end <= start:
            return None
            
        # Compile all ranges across all segment types
        intervals = []
        for t in SegmentType:
            drafts = self.local_drafts.get(t, [])
            for idx, d in enumerate(drafts):
                if exclude and exclude[0] == t and exclude[1] == idx:
                    continue
                if d.start_ms is not None and d.end_ms is not None:
                    intervals.append((d.start_ms, d.end_ms))
                    
        # Sort intervals
        intervals.sort(key=lambda x: x[0])
        
        # Test collision overlap with each interval and push/pull endpoints
        for i_start, i_end in intervals:
            # Check overlap
            if max(start, i_start) < min(end, i_end):
                # We overlap. Try adjusting start/end boundary.
                if start < i_start and end > i_start:
                    end = i_start
                elif end > i_end and start < i_end:
                    start = i_end
                else:
                    # Move to nearest side
                    dist_to_left = abs(end - i_start)
                    dist_to_right = abs(i_end - start)
                    if dist_to_left <= dist_to_right:
                        end = i_start
                    else:
                        start = i_end
                        
            if end <= start:
                return None
                
        return start, end

    def _normalize_and_sort_drafts(self, drafts: List[SegmentDraft]) -> List[SegmentDraft]:
        return sorted(drafts, key=lambda d: d.start_ms if d.start_ms is not None else -1)

    def _get_int(self, text: str) -> Optional[int]:
        t = text.strip()
        try:
            return int(t) if t else None
        except ValueError:
            return None

    def position_to_ms(self, x: float) -> int:
        ratio = x / self.timeline.width()
        return int(ratio * self.timeline.duration_ms)

    def ms_to_position(self, ms: int) -> float:
        ratio = ms / self.timeline.duration_ms
        return ratio * self.timeline.width()

    def _on_scan_season_clicked(self):
        video_dir = ""
        if self.selected_video_url:
            potential_dir = os.path.dirname(self.selected_video_url)
            if potential_dir.startswith("file://"):
                potential_dir = potential_dir[7:]
            
            if os.path.exists(potential_dir):
                reply = QMessageBox.question(
                    self, "Scan Season", 
                    f"Scan all episodes in directory:\n{potential_dir}?",
                    QMessageBox.Yes | QMessageBox.No | QMessageBox.Cancel
                )
                if reply == QMessageBox.Yes:
                    video_dir = potential_dir
                elif reply == QMessageBox.No:
                    video_dir = QFileDialog.getExistingDirectory(self, "Select Season Directory", potential_dir)
                else:
                    return
        
        if not video_dir:
            video_dir = QFileDialog.getExistingDirectory(self, "Select Season Directory")
            
        if video_dir:
            # Check /tmp cache first
            import hashlib
            import json
            try:
                dir_hash = hashlib.md5(os.path.abspath(video_dir).encode('utf-8')).hexdigest()
                cache_path = os.path.join("/tmp", f"segmenter_rcd_{dir_hash}.json")
                if os.path.exists(cache_path):
                    with open(cache_path, "r", encoding="utf-8") as f:
                        cached_results = json.load(f)
                    print(f"[RCD Cache] Loading cached results automatically from {cache_path}")
                    self.current_scan_dir = video_dir
                    self._on_rcd_scan_completed(cached_results)
                    self.show_status_message(f"Loaded season scan automatically from cache: {os.path.basename(video_dir)}", "green")
                    
                    QMessageBox.information(
                        self, "Scan Cached",
                        "Found cached RCD scan for this directory!\n"
                        "Loaded segment drafts automatically without scanning."
                    )
                    return
            except Exception as e:
                print(f"[RCD Cache] Failed to load cached RCD scan: {str(e)}")

            self.current_scan_dir = video_dir
            dialog = RCDProgressDialog(video_dir, self)
            dialog.scan_completed.connect(self._on_rcd_scan_completed)
            dialog.exec()

    def _on_rcd_scan_completed(self, results: dict):
        self.rcd_results = results
        
        # Write to cache in /tmp
        if getattr(self, "current_scan_dir", None):
            import hashlib
            import json
            try:
                dir_hash = hashlib.md5(os.path.abspath(self.current_scan_dir).encode('utf-8')).hexdigest()
                cache_path = os.path.join("/tmp", f"segmenter_rcd_{dir_hash}.json")
                with open(cache_path, "w", encoding="utf-8") as f:
                    json.dump(results, f, ensure_ascii=False, indent=2)
                print(f"[RCD Cache] Successfully cached results to {cache_path}")
            except Exception as e:
                print(f"[RCD Cache] Error saving cache file: {e}")

        # Apply detections to the currently loaded video immediately
        if self.selected_video_url and self.video_duration_ms > 0:
            filename = os.path.basename(self.selected_video_url)
            if filename in results:
                self._pending_rcd_detections = results[filename]
                self._apply_pending_rcd_detections(self.video_duration_ms)
                logger.info("Applied RCD detections directly to loaded video '%s'", filename)
