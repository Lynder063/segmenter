# 🍏 Segmenter (macOS)

Native macOS build of **Segmenter**, supporting both **Apple Silicon (`arm64`)** (M1/M2/M3/M4) and **Intel (`x86_64`)** Mac hardware.

---

## ✨ macOS Features & Highlights

- **Dual Architecture**: Native support for Apple Silicon (`arm64`) & Intel Macs (`x86_64`).
- **Apple Silicon Hardware Acceleration**: GPU acceleration via PyTorch **MPS (Metal Performance Shaders)** for RCD CNN feature extraction.
- **Native macOS Look & Feel**: Retina Display High-DPI support, dark theme UI matching project standard (`docs/screenshot.png`), native macOS menu bar with `Cmd` keyboard shortcuts (`Cmd+O`, `Cmd+Q`, `Cmd+U`, etc.).
- **Native Keys Storage**: Stores API keys in `~/.config/Segmenter/keys.json`.

---

## 🚀 Quick Start (macOS)

### Prerequisites

| Dependency | Purpose |
|---|---|
| `python3` (≥ 3.10) | Runtime environment (e.g. `brew install python@3.11`) |
| `ffmpeg` | Audio extraction and frame strip thumbnails (`brew install ffmpeg`) |

### Run

Run the automated launcher:

```bash
./macos/run.sh
```

This script automatically creates a isolated virtual environment (`macos/venv_mac`), installs all Python dependencies, and launches the native macOS app.

---

## 📦 Packaging Standalone App (.app / .dmg)

To build a standalone bundle (`Segmenter.app`) and installer (`Segmenter.dmg`):

```bash
./macos/build_app.sh
```

Output artifacts are generated in `macos/dist/`:
- `macos/dist/Segmenter.app`
- `macos/dist/Segmenter-arm64.dmg` (or `Segmenter-x86_64.dmg`)

---

## ⌨️ macOS Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd> + <kbd>O</kbd> | Open Local Video |
| <kbd>⌘</kbd> + <kbd>Q</kbd> | Quit Segmenter |
| <kbd>Space</kbd> | Toggle play / pause |
| <kbd>←</kbd> / <kbd>→</kbd> | Step one frame backward / forward |
| <kbd>I</kbd> / <kbd>Shift+I</kbd> | Set Intro start / end |
| <kbd>R</kbd> / <kbd>Shift+R</kbd> | Set Recap start / end |
| <kbd>C</kbd> / <kbd>Shift+C</kbd> | Set Credits start / end |
| <kbd>P</kbd> / <kbd>Shift+P</kbd> | Set Preview start / end |
| <kbd>,</kbd> | Snap nearest segment edge to playhead |
