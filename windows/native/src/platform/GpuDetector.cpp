#include "platform/GpuDetector.h"

#include <QThread>

#include <windows.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <algorithm>
#include <vector>

#include "services/LoggerService.h"

namespace segmenter {
namespace {

struct AdapterInfo {
    QString description;
    quint64 dedicatedVideoMemory = 0;
};

std::vector<AdapterInfo> enumerateAdapters()
{
    std::vector<AdapterInfo> adapters;

    Microsoft::WRL::ComPtr<IDXGIFactory> factory;
    if (FAILED(CreateDXGIFactory(__uuidof(IDXGIFactory),
                                 reinterpret_cast<void **>(factory.GetAddressOf())))) {
        LoggerService::instance().warn(QStringLiteral("[GpuDetector] CreateDXGIFactory failed"));
        return adapters;
    }

    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    for (UINT index = 0;
         factory->EnumAdapters(index, adapter.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND;
         ++index) {
        DXGI_ADAPTER_DESC desc = {};
        if (FAILED(adapter->GetDesc(&desc))) {
            continue;
        }

        const QString description = QString::fromWCharArray(desc.Description);

        // Both are CPU rasterisers rather than hardware; listing them would
        // misreport a machine with no usable GPU as having one.
        if (description.contains(QLatin1String("Microsoft Basic Render"), Qt::CaseInsensitive)
            || description.contains(QLatin1String("WARP"), Qt::CaseInsensitive)) {
            continue;
        }

        adapters.push_back(AdapterInfo{description,
                                       static_cast<quint64>(desc.DedicatedVideoMemory)});
    }

    std::sort(adapters.begin(), adapters.end(),
              [](const AdapterInfo &a, const AdapterInfo &b) {
                  return a.dedicatedVideoMemory > b.dedicatedVideoMemory;
              });

    return adapters;
}

} // namespace

QStringList GpuDetector::adapters()
{
    QStringList names;
    for (const AdapterInfo &info : enumerateAdapters()) {
        names << info.description;
    }
    return names;
}

QString GpuDetector::primaryAdapter()
{
    const QStringList names = adapters();
    return names.isEmpty() ? QStringLiteral("Unknown display adapter") : names.first();
}

QString GpuDetector::accelerationSummary()
{
    // Thread count, not GPU model, is what actually bounds a scan: feature
    // extraction and template search are CPU-bound and fan out one task per
    // core. The adapter is reported because it drives video decode in the
    // player and frame extraction.
    return QStringLiteral("%1 • %2 threads")
        .arg(primaryAdapter())
        .arg(QThread::idealThreadCount());
}

} // namespace segmenter
