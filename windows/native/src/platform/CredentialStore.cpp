#include "platform/CredentialStore.h"

#include <windows.h>
#include <wincred.h>

#include "services/LoggerService.h"

namespace segmenter {

const QString CredentialStore::kTheIntroDbToken = QStringLiteral("TheIntroDB");
const QString CredentialStore::kIntroDbApiKey = QStringLiteral("IntroDB");
const QString CredentialStore::kTmdbApiKey = QStringLiteral("TMDB");

CredentialStore &CredentialStore::instance()
{
    static CredentialStore store;
    return store;
}

namespace {

QString targetName(const QString &account)
{
    return QStringLiteral("Segmenter/%1").arg(account);
}

} // namespace

QString CredentialStore::backendDescription() const
{
    return QStringLiteral("Windows Credential Manager");
}

QString CredentialStore::read(const QString &account) const
{
    const QString target = targetName(account);

    PCREDENTIALW credential = nullptr;
    if (!CredReadW(reinterpret_cast<LPCWSTR>(target.utf16()),
                   CRED_TYPE_GENERIC, 0, &credential)) {
        // ERROR_NOT_FOUND on first run is the normal path, not a fault.
        return QString();
    }

    QString secret;
    if (credential->CredentialBlob != nullptr && credential->CredentialBlobSize > 0) {
        // The blob is UTF-16 without a terminator, so the length has to come
        // from CredentialBlobSize rather than from a scan for NUL.
        secret = QString::fromUtf16(reinterpret_cast<const char16_t *>(credential->CredentialBlob),
                                    static_cast<qsizetype>(credential->CredentialBlobSize / sizeof(char16_t)));
    }

    CredFree(credential);
    return secret;
}

bool CredentialStore::write(const QString &account, const QString &secret)
{
    if (secret.isEmpty()) {
        return erase(account);
    }

    const QString target = targetName(account);

    CREDENTIALW credential = {};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(reinterpret_cast<LPCWSTR>(target.utf16()));
    credential.UserName = const_cast<LPWSTR>(reinterpret_cast<LPCWSTR>(account.utf16()));
    // QString::utf16() hands back const ushort*; CREDENTIALW wants a writable
    // byte pointer, but CredWriteW only reads it.
    credential.CredentialBlob =
        reinterpret_cast<LPBYTE>(const_cast<ushort *>(secret.utf16()));
    credential.CredentialBlobSize =
        static_cast<DWORD>(static_cast<std::size_t>(secret.size()) * sizeof(char16_t));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;

    if (!CredWriteW(&credential, 0)) {
        LoggerService::instance().error(
            QStringLiteral("[CredentialStore] CredWriteW failed for %1 (error %2)")
                .arg(account)
                .arg(GetLastError()));
        return false;
    }

    LoggerService::instance().info(
        QStringLiteral("[CredentialStore] stored credential for %1").arg(account));
    return true;
}

bool CredentialStore::erase(const QString &account)
{
    const QString target = targetName(account);

    if (!CredDeleteW(reinterpret_cast<LPCWSTR>(target.utf16()), CRED_TYPE_GENERIC, 0)) {
        const DWORD error = GetLastError();
        // Deleting something that was never stored is the expected outcome of
        // clearing an empty field; only anything else is worth reporting.
        if (error != ERROR_NOT_FOUND) {
            LoggerService::instance().warn(
                QStringLiteral("[CredentialStore] CredDeleteW failed for %1 (error %2)")
                    .arg(account)
                    .arg(error));
            return false;
        }
    }
    return true;
}

} // namespace segmenter
