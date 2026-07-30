#include "platform/OcrService.h"

#include <QMutex>
#include <QMutexLocker>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

using namespace winrt;
using namespace winrt::Windows::Graphics::Imaging;
using namespace winrt::Windows::Media::Ocr;
using namespace winrt::Windows::Storage::Streams;

QMutex g_mutex;

/// COM has to be initialised per thread. The RCD engine runs its visual pass on
/// pooled worker threads, so every entry point checks rather than relying on a
/// one-time init.
void ensureApartment()
{
    static thread_local bool initialized = false;
    if (initialized) {
        return;
    }
    try {
        init_apartment(apartment_type::multi_threaded);
    } catch (const hresult_error &error) {
        // RPC_E_CHANGED_MODE means the thread already joined an apartment —
        // Qt's own threads sometimes have, and that is perfectly usable.
        constexpr int32_t kRpcEChangedMode = static_cast<int32_t>(0x80010106);
        if (error.code() != winrt::hresult{kRpcEChangedMode}) {
            throw;
        }
    }
    initialized = true;
}

OcrEngine createEngine()
{
    OcrEngine engine = OcrEngine::TryCreateFromUserProfileLanguages();
    if (engine) {
        return engine;
    }

    // No profile language has a recognizer; take whatever the system does have.
    const auto languages = OcrEngine::AvailableRecognizerLanguages();
    if (languages.Size() > 0) {
        return OcrEngine::TryCreateFromLanguage(languages.GetAt(0));
    }
    return nullptr;
}

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

    try {
        ensureApartment();
        const OcrEngine engine = createEngine();
        m_available = static_cast<bool>(engine);
        if (m_available) {
            m_languageTag = QString::fromStdWString(
                std::wstring(engine.RecognizerLanguage().LanguageTag()));
            LoggerService::instance().info(
                QStringLiteral("[OcrService] Windows.Media.Ocr ready (language %1)")
                    .arg(m_languageTag));
        } else {
            LoggerService::instance().warn(
                QStringLiteral("[OcrService] no OCR recognizer installed; "
                               "visual credits detection will be skipped"));
        }
    } catch (const hresult_error &error) {
        m_available = false;
        LoggerService::instance().error(
            QStringLiteral("[OcrService] initialisation failed: %1")
                .arg(QString::fromStdWString(std::wstring(error.message()))));
    }
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
        ? QStringLiteral("Windows.Media.Ocr (%1)").arg(m_languageTag)
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

    try {
        ensureApartment();

        // A fresh engine per call rather than a shared member: OcrEngine is not
        // documented as thread-safe, and the visual pass fans frames out across
        // workers. Creation is cheap next to the recognition itself.
        const OcrEngine engine = createEngine();
        if (!engine) {
            return 0;
        }

        InMemoryRandomAccessStream stream;
        DataWriter writer(stream);
        writer.WriteBytes(array_view<const uint8_t>(
            reinterpret_cast<const uint8_t *>(jpegData.constData()),
            reinterpret_cast<const uint8_t *>(jpegData.constData()) + jpegData.size()));
        writer.StoreAsync().get();
        writer.FlushAsync().get();
        writer.DetachStream();
        stream.Seek(0);

        const BitmapDecoder decoder = BitmapDecoder::CreateAsync(stream).get();
        const SoftwareBitmap bitmap = decoder.GetSoftwareBitmapAsync().get();
        if (!bitmap) {
            return 0;
        }

        const OcrResult result = engine.RecognizeAsync(bitmap).get();
        if (!result) {
            return 0;
        }

        return static_cast<int>(result.Lines().Size());
    } catch (const hresult_error &error) {
        LoggerService::instance().debug(
            QStringLiteral("[OcrService] recognition failed: %1")
                .arg(QString::fromStdWString(std::wstring(error.message()))));
        return 0;
    }
}

} // namespace segmenter
