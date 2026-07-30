# 🎬 Segmenter

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-blue.svg)]()
[![macOS Native](https://img.shields.io/badge/macOS_Native-SwiftUI%20%7C%20LibVLC%20%7C%20Accelerate-silver.svg)]()
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-Universal_arm64%2Bx86__64-orange.svg)]()
[![TheIntroDB v3](https://img.shields.io/badge/API-TheIntroDB_v3-purple.svg)]()

**Segmenter** is a high-performance visual timestamp annotation and automatic AI segment detection application for macOS (Universal Binary `arm64` + `x86_64`), Linux, and Windows. It enables users to detect, create, edit, and submit video segment markers — **Intro**, **Recap**, **Credits**, and **Preview** — to [TheIntroDB](https://theintrodb.org) (v3 API) and [IntroDB](https://introdb.app).

---

## ✨ Key Native Features (macOS Native App)

### 🎬 High-Performance Video Engine (LibVLC + VideoToolbox)
- **100% Codec & Container Support**: Native playback for MKV, MP4, AVI, MOV, HEVC (x265), H.264, AC3, DTS, and 10-bit HDR streams.
- **Apple VideoToolbox HW Decoding**: Low-power, hardware-accelerated video decoding on Apple Silicon M-Series and Intel GPUs.
- **Sub-Millisecond Real-Time Playback**: 200 FPS high-precision timecode clock rendering millisecond-accurate timestamps (`02:15.842`).
- **Instant Paused Seeking**: Frame-accurate seeking via `gotoNextFrame()` rendering instant video keyframes when paused.

### 🔍 Interactive Zoomable Multi-Track Timeline ($1.0\times - 50.0\times$)
- **Pinch-to-Zoom & Trackpad Gestures**: Smooth trackpad magnify and scroll wheel panning across the multi-track timeline.
- **Dynamic Time Ruler Ticks**: Automatically adjusts timecode grid ticks from 5-minute intervals down to 1-second and 250ms sub-frame intervals.
- **Zoom Controls Toolbar**: Includes quick zoom sliders, `+`/`-` buttons, `1x` reset, and `🎯 Scope` center-on-playhead action.

### 🤖 Apple Native AI & RCD Season Fingerprinting
Scan entire season folders or standalone episodes with **6 specialized detection methods**:
1. **`Apple HW Accelerated (vDSP SIMD + Vision AI)`**: Chromaprint 12-bin pitch chromagram cross-correlation + Apple Vision OCR text rectangle density and black-frame visual snapping.
2. **`Apple SoundAnalysis ML Classifier`**: Neural classification of speech-to-music acoustic event transitions running on the Apple Neural Engine (ANE).
3. **`Apple Vision AI OCR`**: Optical Character Recognition (`VNDetectTextRectanglesRequest`) and luminance frame inspection ($\bar{L} < 30 / 255$).
4. **`Chromaprint 12-Bin Pitch Chromagram`**: Pure acoustical pitch class profile cross-correlation.
5. **`Multimodal AI Fusion`**: Dual score fusion ($60\% \text{ Audio Chroma} + 40\% \text{ Vision AI}$).
6. **`Single-Episode AI Structural Analysis`**: Standalone AI structural scan for individual files without requiring full season directories.

### 🖼️ Real-Time Dynamic Frame Strip
- In-memory stdout frame extraction pipe for non-native MKV/x265 files ($<0.02\text{s}$ per frame).
- 13-frame preview strip centered around the playhead for frame-accurate boundary placement.

### 🔑 Secure macOS Keychain Storage & TheIntroDB v3 API
- API keys stored securely in the native macOS Keychain.
- Full submission compatibility with **TheIntroDB v3 API** including `video_duration_ms`, `start_ms`, `end_ms`, `tmdb_id`, and `imdb_id`.
- Support for TMDB v3 API Keys and v4 Read Access Bearer Tokens with automatic metadata resolution.

---

## ⌨️ Controls & Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| <kbd>Space</kbd> | Toggle play / pause |
| <kbd>←</kbd> / <kbd>→</kbd> or <kbd>,</kbd> / <kbd>.</kbd> | Step one frame backward / forward |
| <kbd>I</kbd> / <kbd>Shift+I</kbd> | Set Intro start / end |
| <kbd>R</kbd> / <kbd>Shift+R</kbd> | Set Recap start / end |
| <kbd>C</kbd> / <kbd>Shift+C</kbd> | Set Credits start / end |
| <kbd>P</kbd> / <kbd>Shift+P</kbd> | Set Preview start / end |
| <kbd>Escape</kbd> / <kbd>Return</kbd> | Clear text input focus & return keyboard controls to player |
| **Pinch Gesture** | Zoom timeline in / out ($1.0\times - 50.0\times$) |
| **Trackpad Pan** | Scroll timeline horizontally |

---

## 🚀 Native Build & Launch (macOS)

### 1. Build Universal Binary App (`arm64` + `x86_64`)

```bash
./macos/build_native.sh
```

### 2. Run Application Directly

```bash
./macos/dist_native/Segmenter.app/Contents/MacOS/Segmenter
```

---

## 📄 License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for details.
