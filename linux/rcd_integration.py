import os
import sys
from PySide6.QtCore import Qt, QThread, Signal, Slot
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, 
    QProgressBar, QTextEdit, QPushButton, QMessageBox, QComboBox
)

# Import unified GPU detection
from gpu import GPU_AVAILABLE, GPU_NAME, GPU_BACKEND


class StreamRedirector:
    def __init__(self, signal):
        self.signal = signal

    def write(self, text):
        cleaned = text.strip()
        if cleaned:
            self.signal.emit(cleaned)

    def flush(self):
        pass


class RCDWorker(QThread):
    log_signal = Signal(str)
    finished_signal = Signal(dict)
    error_signal = Signal(str)

    def __init__(self, video_dir: str, feature_vector_function: str):
        super().__init__()
        self.video_dir = video_dir
        self.feature_vector_function = feature_vector_function

    def run(self):
        old_stdout = sys.stdout
        sys.stdout = StreamRedirector(self.log_signal)
        
        try:
            from rcd import detector
            
            # Run fingerprint detection with selected mode
            results = detector.detect(
                self.video_dir, 
                feature_vector_function=self.feature_vector_function
            )
            self.finished_signal.emit(results)
        except Exception as e:
            self.error_signal.emit(str(e))
        finally:
            sys.stdout = old_stdout


class RCDProgressDialog(QDialog):
    scan_completed = Signal(dict)

    def __init__(self, video_dir: str, parent=None):
        super().__init__(parent)
        self.video_dir = video_dir
        self.results = None
        self.worker = None
        
        self.setWindowTitle("Season Fingerprinting (RCD)")
        self.setMinimumSize(580, 420)
        self.setStyleSheet("""
            QDialog {
                background-color: #1e1e24;
                color: #f0f0f5;
            }
            QLabel {
                color: #e0e0e8;
            }
            QPushButton {
                background-color: #2c2c35;
                color: #ffffff;
                border: 1px solid #3a3a45;
                padding: 6px 12px;
                border-radius: 4px;
                min-width: 90px;
            }
            QPushButton:hover {
                background-color: #3e3e4a;
            }
            QComboBox {
                background-color: #151518;
                border: 1px solid #3a3a45;
                border-radius: 4px;
                padding: 4px 8px;
                color: #e0e0e8;
                min-width: 250px;
            }
        """)

        # Layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(14)

        # 1. Experimental Warning Banner
        warning_lbl = QLabel(
            "⚠️ WARNING: This feature is experimental. It uses advanced video fingerprinting "
            "to automatically detect intros/outros by comparing frame features. Scanning "
            "can take several minutes depending on hardware and season length.", 
            self
        )
        warning_lbl.setWordWrap(True)
        warning_lbl.setStyleSheet("""
            color: #fb923c; 
            background-color: #2c2015; 
            border: 1px solid #7c2d12; 
            border-radius: 6px; 
            padding: 10px;
            font-size: 11px;
        """)
        layout.addWidget(warning_lbl)

        # 2. Hardware Device Status
        hw_layout = QHBoxLayout()
        hw_lbl_title = QLabel("Hardware Status:", self)
        hw_lbl_title.setStyleSheet("font-weight: bold;")
        hw_layout.addWidget(hw_lbl_title)
        
        self.hw_status_lbl = QLabel(self)
        if GPU_AVAILABLE:
            self.hw_status_lbl.setText(f"🟢 GPU Detected: {GPU_NAME} ({GPU_BACKEND} acceleration enabled)")
            self.hw_status_lbl.setStyleSheet("color: #34d399; font-weight: bold;")
        else:
            self.hw_status_lbl.setText("⚪ No compatible GPU detected. Processing will run on CPU only.")
            self.hw_status_lbl.setStyleSheet("color: #a1a1aa; font-style: italic;")
            
        hw_layout.addWidget(self.hw_status_lbl)
        hw_layout.addStretch()
        layout.addLayout(hw_layout)

        # 3. Model Configuration
        config_layout = QHBoxLayout()
        config_lbl = QLabel("Detection Mode:", self)
        config_lbl.setStyleSheet("font-weight: bold;")
        config_layout.addWidget(config_lbl)
        
        self.mode_combo = QComboBox(self)
        self.mode_combo.addItem("CNN (AI Feature Extractor, GPU-accelerated)", "CNN")
        self.mode_combo.addItem("Color Histogram (Fast on CPU)", "CH")
        self.mode_combo.addItem("Color Texture Moments (Texture analysis)", "CTM")
        config_layout.addWidget(self.mode_combo)
        config_layout.addStretch()
        layout.addLayout(config_layout)

        # Separator line
        sep = QLabel(self)
        sep.setStyleSheet("border-bottom: 1px solid #2a2a30; height: 1px;")
        layout.addWidget(sep)

        # 4. Status Title
        self.status_lbl = QLabel(f"Ready to scan season directory:\n{video_dir}", self)
        self.status_lbl.setStyleSheet("font-size: 11px; color: #38bdf8;")
        layout.addWidget(self.status_lbl)

        # 5. Progress Bar
        self.progress_bar = QProgressBar(self)
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setStyleSheet("""
            QProgressBar {
                border: 1px solid #2a2a30;
                border-radius: 4px;
                background-color: #151518;
                height: 12px;
                text-align: center;
            }
            QProgressBar::chunk {
                background-color: #38bdf8;
            }
        """)
        layout.addWidget(self.progress_bar)

        # 6. Logs Area
        self.log_area = QTextEdit(self)
        self.log_area.setReadOnly(True)
        self.log_area.setPlaceholderText("Console outputs will be displayed here...")
        self.log_area.setStyleSheet("""
            background-color: #0c0c0f;
            color: #a0a0b0;
            font-family: monospace;
            font-size: 11px;
            border: 1px solid #2a2a30;
            border-radius: 4px;
        """)
        layout.addWidget(self.log_area)

        # 7. Action Buttons
        btn_layout = QHBoxLayout()
        btn_layout.addStretch()
        
        self.start_btn = QPushButton("Start Scan", self)
        self.start_btn.setStyleSheet("""
            QPushButton {
                background-color: #0284c7;
                color: white;
                font-weight: bold;
                border: 1px solid #0369a1;
            }
            QPushButton:hover {
                background-color: #0369a1;
            }
        """)
        self.start_btn.clicked.connect(self._on_start_clicked)
        btn_layout.addWidget(self.start_btn)
        
        self.close_btn = QPushButton("Cancel", self)
        self.close_btn.clicked.connect(self.reject)
        btn_layout.addWidget(self.close_btn)
        
        layout.addLayout(btn_layout)

    def _on_start_clicked(self):
        # Configure and start fingerprint scan
        selected_mode = self.mode_combo.currentData()
        
        self.mode_combo.setEnabled(False)
        self.start_btn.setEnabled(False)
        self.start_btn.setText("Running...")
        self.progress_bar.setRange(0, 0)  # Indeterminate spinner style
        self.status_lbl.setText(f"Running {selected_mode} fingerprinting on season...")
        
        # Start background worker thread
        self.worker = RCDWorker(self.video_dir, selected_mode)
        self.worker.log_signal.connect(self._on_log)
        self.worker.finished_signal.connect(self._on_finished)
        self.worker.error_signal.connect(self._on_error)
        self.worker.start()

    @Slot(str)
    def _on_log(self, text: str):
        self.log_area.append(text)
        self.log_area.verticalScrollBar().setValue(
            self.log_area.verticalScrollBar().maximum()
        )

    @Slot(dict)
    def _on_finished(self, results: dict):
        self.results = results
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        self.status_lbl.setText("Fingerprinting completed successfully!")
        self.status_lbl.setStyleSheet("font-weight: bold; font-size: 11px; color: #34d399;")
        self.close_btn.setText("Close")
        
        # Rebind clean close action
        try:
            self.close_btn.clicked.disconnect()
        except Exception:
            pass
        self.close_btn.clicked.connect(self.accept)
        
        # Emit scan completed event
        self.scan_completed.emit(results)
        
        # Prompt user
        QMessageBox.information(
            self, "Scan Complete", 
            f"Successfully fingerprinted {len(results)} videos in the season!\n"
            "Detections have been imported as segment drafts."
        )
        self.accept()

    @Slot(str)
    def _on_error(self, err_msg: str):
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.status_lbl.setText(f"Error during fingerprinting: {err_msg}")
        self.status_lbl.setStyleSheet("font-weight: bold; font-size: 11px; color: #f87171;")
        self.log_area.append(f"\n[ERROR] {err_msg}")
        self.close_btn.setText("Close")
        
        self.mode_combo.setEnabled(True)
        self.start_btn.setEnabled(True)
        self.start_btn.setText("Start Scan")

    def reject(self):
        if self.worker and self.worker.isRunning():
            reply = QMessageBox.question(
                self, "Cancel Fingerprint", 
                "Are you sure you want to cancel the fingerprint scan?",
                QMessageBox.Yes | QMessageBox.No
            )
            if reply == QMessageBox.Yes:
                self.worker.terminate()
                self.worker.wait()
                super().reject()
        else:
            super().reject()
