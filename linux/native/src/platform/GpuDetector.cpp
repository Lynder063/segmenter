#include "platform/GpuDetector.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QThread>

namespace segmenter {
namespace {

/// PCI vendor IDs, so an adapter can be named without a device database.
QString vendorName(const QString &vendorId)
{
    static const QHash<QString, QString> vendors = {
        {QStringLiteral("0x10de"), QStringLiteral("NVIDIA")},
        {QStringLiteral("0x1002"), QStringLiteral("AMD")},
        {QStringLiteral("0x1022"), QStringLiteral("AMD")},
        {QStringLiteral("0x8086"), QStringLiteral("Intel")},
        {QStringLiteral("0x15ad"), QStringLiteral("VMware")},
        {QStringLiteral("0x1af4"), QStringLiteral("VirtIO")},
        {QStringLiteral("0x1414"), QStringLiteral("Microsoft")},
    };
    return vendors.value(vendorId.toLower());
}

QString readSysfs(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll()).trimmed();
}

} // namespace

QStringList GpuDetector::adapters()
{
    QStringList names;

    // /sys/class/drm holds one entry per DRM device. cardN (without a trailing
    // "-connector" suffix) is the GPU itself; the rest are its outputs.
    const QDir drmDir(QStringLiteral("/sys/class/drm"));
    if (!drmDir.exists()) {
        return names;
    }

    const QStringList entries =
        drmDir.entryList(QStringList{QStringLiteral("card[0-9]*")}, QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QString &entry : entries) {
        // Skip connectors like "card0-HDMI-A-1".
        if (entry.contains(QLatin1Char('-'))) {
            continue;
        }

        const QString devicePath = drmDir.filePath(entry + QStringLiteral("/device"));
        const QString vendorId = readSysfs(devicePath + QStringLiteral("/vendor"));
        const QString deviceId = readSysfs(devicePath + QStringLiteral("/device"));

        const QString vendor = vendorName(vendorId);
        if (vendor.isEmpty() && vendorId.isEmpty()) {
            continue;
        }

        // Without a PCI ID database the exact model is not resolvable from
        // sysfs alone, so the device ID stands in for it.
        names << (vendor.isEmpty()
                      ? QStringLiteral("GPU %1:%2").arg(vendorId, deviceId)
                      : QStringLiteral("%1 GPU (%2)").arg(vendor, deviceId));
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
