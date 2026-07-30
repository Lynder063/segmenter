#pragma once

#include <QString>

namespace segmenter {

/// API key storage in whatever secret store the platform provides.
///
/// The interface is deliberately identical across platforms; each one links a
/// different implementation:
///   - Windows: Credential Manager (`wincred.h`), encrypted at rest by DPAPI
///   - Linux:   Secret Service via libsecret (GNOME Keyring, KWallet), with a
///              file fallback when no keyring daemon is running
class CredentialStore {
public:
    /// Account names, matching the three keys the app takes.
    static const QString kTheIntroDbToken;
    static const QString kIntroDbApiKey;
    static const QString kTmdbApiKey;

    static CredentialStore &instance();

    /// Returns an empty string when nothing is stored under `account`.
    QString read(const QString &account) const;

    /// Storing an empty value erases the credential rather than writing a blank
    /// one, so clearing a field in the UI actually removes it.
    bool write(const QString &account, const QString &secret);

    bool erase(const QString &account);

    /// Human-readable name of the backing store, for the UI to say where keys
    /// went — "Windows Credential Manager", "GNOME Keyring", or the fallback.
    QString backendDescription() const;

private:
    CredentialStore() = default;
};

} // namespace segmenter
