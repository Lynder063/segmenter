#include "platform/CredentialStore.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

#include "services/LoggerService.h"

#ifdef SEGMENTER_HAVE_LIBSECRET
// Qt defines `signals` as `public:`, and gio's GDBusInterfaceInfo has a struct
// member of that name, so including libsecret after any Qt header fails to
// compile. Drop the macro across the include and put it back afterwards, so the
// rest of this file still reads as ordinary Qt code.
#  pragma push_macro("signals")
#  undef signals
#  include <libsecret/secret.h>
#  pragma pop_macro("signals")
#endif

namespace segmenter {

const QString CredentialStore::kTheIntroDbToken = QStringLiteral("TheIntroDB");
const QString CredentialStore::kIntroDbApiKey = QStringLiteral("IntroDB");
const QString CredentialStore::kTmdbApiKey = QStringLiteral("TMDB");

namespace {

#ifdef SEGMENTER_HAVE_LIBSECRET

/// Schema for the Secret Service. The name is what shows up in Seahorse or
/// KWalletManager, so it says which application owns the entry.
const SecretSchema *segmenterSchema()
{
    static const SecretSchema schema = {
        "org.theintrodb.Segmenter", SECRET_SCHEMA_NONE,
        {
            {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {nullptr, SecretSchemaAttributeType(0)},
        },
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    return &schema;
}

/// True when a Secret Service provider is actually reachable.
///
/// This has to attempt a real operation. `secret_service_get_sync` hands back a
/// proxy object on any session with a D-Bus daemon, whether or not anything
/// implements org.freedesktop.secrets behind it — probing with that alone
/// reported the keyring as available on a headless box, and every subsequent
/// read then failed with "was not provided by any .service files" instead of
/// falling back to the file store.
///
/// Probed once and cached: the answer cannot change within a session, and
/// re-probing would log the same warning on every key read.
bool keyringAvailable()
{
    static const bool available = [] {
        GError *error = nullptr;
        gchar *probe = secret_password_lookup_sync(
            segmenterSchema(), nullptr, &error,
            "account", "__probe__", nullptr);

        if (error != nullptr) {
            LoggerService::instance().info(
                QStringLiteral("[CredentialStore] no Secret Service keyring (%1) "
                               "— falling back to a permission-restricted file")
                    .arg(QString::fromUtf8(error->message)));
            g_error_free(error);
            return false;
        }

        // A miss is the expected result; what matters is that the call worked.
        if (probe != nullptr) {
            secret_password_free(probe);
        }
        return true;
    }();
    return available;
}

#endif // SEGMENTER_HAVE_LIBSECRET

/// Fallback store, used when no Secret Service is reachable.
///
/// This is plain JSON with owner-only permissions — obscured by filesystem
/// permissions, not encrypted. That is a real downgrade from the keyring, so
/// backendDescription() says so plainly rather than letting the user assume
/// their keys are protected.
QString fallbackPath()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    QDir().mkpath(dir);
    return QDir(dir).filePath(QStringLiteral("keys.json"));
}

QJsonObject readFallback()
{
    QFile file(fallbackPath());
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QJsonDocument::fromJson(file.readAll()).object();
}

bool writeFallback(const QJsonObject &object)
{
    QFile file(fallbackPath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return false;
    }
    file.write(QJsonDocument(object).toJson(QJsonDocument::Indented));
    file.close();
    return file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

} // namespace

CredentialStore &CredentialStore::instance()
{
    static CredentialStore store;
    return store;
}

QString CredentialStore::backendDescription() const
{
#ifdef SEGMENTER_HAVE_LIBSECRET
    if (keyringAvailable()) {
        return QStringLiteral("Secret Service keyring");
    }
#endif
    return QStringLiteral("%1 (file permissions only, not encrypted)").arg(fallbackPath());
}

QString CredentialStore::read(const QString &account) const
{
#ifdef SEGMENTER_HAVE_LIBSECRET
    if (keyringAvailable()) {
        GError *error = nullptr;
        gchar *secret = secret_password_lookup_sync(
            segmenterSchema(), nullptr, &error,
            "account", account.toUtf8().constData(), nullptr);

        if (error != nullptr) {
            LoggerService::instance().warn(
                QStringLiteral("[CredentialStore] keyring lookup failed for %1: %2")
                    .arg(account, QString::fromUtf8(error->message)));
            g_error_free(error);
            return QString();
        }
        if (secret == nullptr) {
            // Nothing stored yet — the normal first-run path, not a fault.
            return QString();
        }

        const QString value = QString::fromUtf8(secret);
        secret_password_free(secret);
        return value;
    }
#endif
    return readFallback().value(account).toString();
}

bool CredentialStore::write(const QString &account, const QString &secret)
{
    if (secret.isEmpty()) {
        return erase(account);
    }

#ifdef SEGMENTER_HAVE_LIBSECRET
    if (keyringAvailable()) {
        GError *error = nullptr;
        const gboolean ok = secret_password_store_sync(
            segmenterSchema(), SECRET_COLLECTION_DEFAULT,
            QStringLiteral("Segmenter — %1").arg(account).toUtf8().constData(),
            secret.toUtf8().constData(),
            nullptr, &error,
            "account", account.toUtf8().constData(), nullptr);

        if (error != nullptr) {
            LoggerService::instance().error(
                QStringLiteral("[CredentialStore] keyring store failed for %1: %2")
                    .arg(account, QString::fromUtf8(error->message)));
            g_error_free(error);
            return false;
        }
        return ok == TRUE;
    }
#endif

    QJsonObject keys = readFallback();
    keys.insert(account, secret);
    return writeFallback(keys);
}

bool CredentialStore::erase(const QString &account)
{
#ifdef SEGMENTER_HAVE_LIBSECRET
    if (keyringAvailable()) {
        GError *error = nullptr;
        secret_password_clear_sync(segmenterSchema(), nullptr, &error,
                                   "account", account.toUtf8().constData(), nullptr);
        if (error != nullptr) {
            g_error_free(error);
            return false;
        }
        return true;
    }
#endif

    QJsonObject keys = readFallback();
    keys.remove(account);
    return writeFallback(keys);
}

} // namespace segmenter
