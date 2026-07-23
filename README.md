# 🎬 Segmenter

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows%20%7C%20macOS-blue.svg)]()
[![macOS](https://img.shields.io/badge/macOS_Arch-arm64%20%7C%20x86__64-silver.svg)]()
[![Python](https://img.shields.io/badge/Linux%2FmacOS_Stack-Python_3.10+-yellow.svg)]()
[![Qt](https://img.shields.io/badge/UI-PySide6%20(Qt6)-41cd52.svg)]()
[![Dotnet](https://img.shields.io/badge/Windows_Stack-.NET_8.0-purple.svg)]()
[![WPF](https://img.shields.io/badge/Windows_UI-WPF-blue.svg)]()

**Segmenter** is a high-performance visual timestamp annotation tool for Linux, Windows, and macOS (supporting Apple Silicon `arm64` and Intel `x86_64`). It lets you create, edit, and upload media segment markers — **Intro**, **Recap**, **Credits**, and **Preview** — to [TheIntroDB](https://theintrodb.org) and [IntroDB](https://introdb.app).

![Segmenter App Layout](docs/screenshot.png)

---

## ✨ Features

### 🎧 Audio Waveform Analysis
Automatically extracts audio and displays a density waveform on the timeline. Uses FFT-based spectral flatness to color-code passages — **mint** for dialogue, **orange** for music-heavy themes like intros and outros.

### 🖼️ Frame Strip Preview
Real-time MJPEG-based frame strip centered on the playhead for frame-accurate seeking and positioning.

### 🤖 GPU-Accelerated Season Fingerprinting
Integrated **Recurring Content Detector (RCD)** scans an entire season directory and automatically finds duplicate segments across episodes using:
- **FAISS-GPU** nearest-neighbor search (NVIDIA) or FAISS-CPU (AMD / Apple / CPU)
- **CNN feature extraction** (MobileNetV3 or SimpleCNN fallback via PyTorch)
- **Apple Silicon MPS** (Metal Performance Shaders) GPU acceleration on M1/M2/M3/M4 Macs
- **Color Histogram** and **Color Texture Moment** modes for CPU-only setups
- **AMD ROCm** support — PyTorch ROCm builds accelerate CNN feature extraction on AMD GPUs
- **NVIDIA CUDA** support — full GPU acceleration including FAISS-GPU

Results are cached in `/tmp` and reused automatically on subsequent loads.

### 🌐 Remote Network Shares
Stream and analyze files directly from Samba/SMB, SFTP, NFS, WebDAV, or HTTP mounts via native file dialogs.

### 🔑 Local Configuration
API keys are stored in `~/.config/Segmenter/keys.json` — no keyring daemon required.

---

## ⌨️ Controls & Shortcuts

### Timeline Mouse Actions

| Action | Description |
|---|---|
| **Click** | Seek to position |
| **Alt + Drag** | Create a new segment |
| **Shift + Drag** | Move a segment between rows |
| **Drag Edges** | Resize segment boundaries |
| **Scroll Wheel** | Zoom in/out around playhead |

### Keyboard Shortcuts

| Shortcut | Description |
|---|---|
| <kbd>Space</kbd> | Toggle play / pause |
| <kbd>←</kbd> / <kbd>→</kbd> | Step one frame backward / forward |
| <kbd>I</kbd> / <kbd>Shift+I</kbd> | Set Intro start / end |
| <kbd>R</kbd> / <kbd>Shift+R</kbd> | Set Recap start / end |
| <kbd>C</kbd> / <kbd>Shift+C</kbd> | Set Credits start / end |
| <kbd>P</kbd> / <kbd>Shift+P</kbd> | Set Preview start / end |
| <kbd>,</kbd> | Snap nearest segment edge to playhead |

---

## 🚀 Quick Start (macOS — arm64 & x86_64)

### Prerequisites

| Dependency | Purpose |
|---|---|
| `python3` (≥ 3.10) | Runtime (`brew install python@3.11`) |
| `ffmpeg` | Audio extraction and frame strip thumbnails (`brew install ffmpeg`) |

### Run

```bash
./macos/run.sh
```

### Build Standalone App (.app / .dmg)

```bash
./macos/build_app.sh
```

---

## 🚀 Quick Start (Linux)

### Prerequisites

| Dependency | Purpose |
|---|---|
| `python3` (≥ 3.10) | Runtime |
| `pip` | Package manager |
| `ffmpeg` | Audio/video processing |
| NVIDIA CUDA drivers | *Optional* — full GPU acceleration (CNN + FAISS) |
| AMD ROCm + PyTorch-ROCm | *Optional* — GPU acceleration for CNN feature extraction |

### Run

```bash
./linux/run.sh
```

This script automatically creates a virtual environment, installs all Python dependencies, and launches the app.

---

## 🚀 Quick Start (Windows)

### Prerequisites

| Dependency | Purpose |
|---|---|
| `.NET 8.0 SDK` | Compilation and runtime |
| `ffmpeg` | Audio extraction and thumbnail generation (must be in system PATH) |

### Build & Run

Run the PowerShell build script:

```powershell
.\windows\build.ps1
```

This will restore dependencies, compile the project, and generate a standalone executable at `windows\dist\Segmenter.exe`.

---

## 📦 Packaging

Build standalone `.deb`, `.rpm`, and Arch Linux packages:

```bash
./linux/build_packages.sh
```

Build standalone macOS `.app` and `.dmg`:

```bash
./macos/build_app.sh
```

---

## 🏗️ Project Structure

```
.
├── macos/                  # macOS Port (arm64 & x86_64)
│   ├── app.py              # macOS Entry point & Native Menu Bar
│   ├── run.sh              # macOS Quick Start launcher
│   ├── build_app.sh        # PyInstaller bundle & DMG builder
│   ├── Info.plist          # Apple Bundle Metadata (Retina, File associations)
│   ├── requirements.txt    # macOS dependencies
│   └── README.md           # macOS documentation
├── windows/
│   ├── build.ps1           # Windows Build Script
│   ├── Segmenter/          # WPF C# Application
│   │   ├── MainWindow.xaml # Main UI
│   │   └── ...
│   └── dist/               # Compiled Segmenter.exe
├── linux/
│   ├── app.py              # Entry point
│   ├── ui.py               # Main window & all UI logic
│   ├── timeline.py         # Interactive timeline widget
│   ├── framestrip.py       # MJPEG frame strip
│   ├── player.py           # Video player (mpv backend)
│   ├── audio.py            # Audio waveform extraction
│   ├── models.py           # Data models (SegmentType, SegmentDraft, etc.)
│   ├── clients.py          # TheIntroDB & IntroDB API clients
│   ├── parser.py           # Filename → TMDB metadata parser
│   ├── validator.py        # Segment validation rules
│   ├── rcd_integration.py  # RCD scan dialog & worker
│   ├── gpu.py              # Unified GPU detection (CUDA / ROCm / MPS / CPU)
│   ├── rcd/                # Recurring Content Detector engine
│   │   ├── detector.py     # Main detection pipeline
│   │   ├── featurevectors.py # Feature vector extraction (CH, CTM, CNN)
│   │   ├── video_functions.py # Video resize & framerate utils
│   │   └── evaluation.py   # Detection evaluation metrics
│   ├── run.sh              # Launcher script
│   ├── build_packages.sh   # Packaging script
│   └── requirements.txt    # Python dependencies
├── docs/
│   └── screenshot.png
├── LICENSE
└── README.md
```


---

## 🙏 Acknowledgements

- **[recurring-content-detector](https://github.com/haser/recurring-content-detector)** — Core fingerprinting, FAISS search, and CNN algorithms used for automated recurring segment detection.
- **[IntroStamp](https://github.com/fetchbot/introstamp)** — The original macOS segment editor that served as UX model and design inspiration.
- **[TheIntroDB](https://theintrodb.org)** & **[IntroDB](https://introdb.app)** — Public segment marker databases and APIs.
- **[TMDB](https://www.themoviedb.org)** — Movie and TV metadata.

---

## 📄 License

MIT License — see [LICENSE](LICENSE).
