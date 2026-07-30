#pragma once

#include <QByteArray>
#include <QString>

namespace segmenter {

/// On-screen text detection for the visual credits pass.
///
/// Only the *density* of detected text matters to the RCD engine, not what it
/// says: a credit roll produces many text lines per frame, ordinary dialogue
/// scenes produce almost none.
///
/// Per-platform backing:
///   - macOS:   Vision `VNDetectTextRectanglesRequest` (the reference port)
///   - Windows: `Windows.Media.Ocr`, ships with the OS
///   - Linux:   Tesseract, when libtesseract is present at build time
///
/// Every implementation may report itself unavailable, in which case the RCD
/// engine falls back to audio-only detection rather than failing.
class OcrService {
public:
    static OcrService &instance();

    /// True when a recognizer could be created.
    bool isAvailable();

    /// Number of recognised text lines in a JPEG frame. Returns 0 when the
    /// frame has no text, cannot be decoded, or OCR is unavailable.
    int textLineCount(const QByteArray &jpegData);

    /// Human-readable backend description for the scan dialog's status line.
    QString backendDescription();

private:
    OcrService() = default;

    void ensureInitialized();

    bool m_initialized = false;
    bool m_available = false;
    QString m_languageTag;
};

} // namespace segmenter
