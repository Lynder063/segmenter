#include "platform/OcrService.h"

#include <QImage>
#include <QMutex>
#include <QMutexLocker>

#include "services/LoggerService.h"

#ifdef SEGMENTER_HAVE_TESSERACT
#  include <tesseract/baseapi.h>
#  include <leptonica/allheaders.h>
#endif

namespace segmenter {
namespace {

QMutex g_mutex;

} // namespace

OcrService &OcrService::instance()
{
    static OcrService service;
    return service;
}

void OcrService::ensureInitialized()
{
    if (m_initialized) {
        return;
    }
    m_initialized = true;

#ifdef SEGMENTER_HAVE_TESSERACT
    // Probe once by actually constructing an engine: the library links fine
    // without any traineddata installed, and that only fails at Init().
    tesseract::TessBaseAPI api;
    if (api.Init(nullptr, "eng", tesseract::OEM_LSTM_ONLY) == 0) {
        m_available = true;
        m_languageTag = QStringLiteral("eng");
        api.End();
        LoggerService::instance().info(
            QStringLiteral("[OcrService] Tesseract ready (language eng)"));
    } else {
        m_available = false;
        LoggerService::instance().warn(
            QStringLiteral("[OcrService] Tesseract is linked but has no language data "
                           "— install tesseract-ocr-eng. Falling back to audio-only."));
    }
#else
    m_available = false;
    LoggerService::instance().info(
        QStringLiteral("[OcrService] built without Tesseract — visual credits "
                       "detection is unavailable, using audio-only detection"));
#endif
}

bool OcrService::isAvailable()
{
    QMutexLocker locker(&g_mutex);
    ensureInitialized();
    return m_available;
}

QString OcrService::backendDescription()
{
    QMutexLocker locker(&g_mutex);
    ensureInitialized();
    return m_available
        ? QStringLiteral("Tesseract (%1)").arg(m_languageTag)
        : QStringLiteral("OCR unavailable — audio-only detection");
}

int OcrService::textLineCount(const QByteArray &jpegData)
{
    if (jpegData.isEmpty()) {
        return 0;
    }

    {
        QMutexLocker locker(&g_mutex);
        ensureInitialized();
        if (!m_available) {
            return 0;
        }
    }

#ifdef SEGMENTER_HAVE_TESSERACT
    QImage image;
    if (!image.loadFromData(jpegData, "JPEG")) {
        return 0;
    }
    image = image.convertToFormat(QImage::Format_Grayscale8);

    // A fresh engine per call: TessBaseAPI is not thread-safe and the visual
    // pass fans frames out across workers. Init is a few milliseconds against
    // the recognition itself.
    tesseract::TessBaseAPI api;
    if (api.Init(nullptr, "eng", tesseract::OEM_LSTM_ONLY) != 0) {
        return 0;
    }

    // Only the count of text regions matters, never the text, so page
    // segmentation is set to find sparse text rather than assume a document.
    api.SetPageSegMode(tesseract::PSM_SPARSE_TEXT);
    api.SetImage(image.constBits(), image.width(), image.height(),
                 1, static_cast<int>(image.bytesPerLine()));

    int lines = 0;
    if (tesseract::ResultIterator *it = api.GetIterator()) {
        do {
            // Discard low-confidence hits: film grain and busy backgrounds
            // otherwise register as text and inflate the density on ordinary
            // footage, which is exactly what this has to tell apart.
            if (it->Confidence(tesseract::RIL_TEXTLINE) >= 60.0f) {
                ++lines;
            }
        } while (it->Next(tesseract::RIL_TEXTLINE));
        delete it;
    }

    api.End();
    return lines;
#else
    return 0;
#endif
}

} // namespace segmenter
