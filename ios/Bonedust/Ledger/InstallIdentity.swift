import Foundation
import Security

/// Who the player is, as far as the ledger is concerned: one random UUID (§2).
///
/// It lives in the Keychain rather than UserDefaults for one reason that matters — the
/// Keychain survives an app reinstall, so a player who deletes and reinstalls keeps their
/// lifetime contribution instead of silently becoming a new digger. It is marked
/// `ThisDeviceOnly` so it is never carried to another device by an iCloud backup, which
/// would make two devices claim the same share.
///
/// There are no accounts and nothing here identifies a person.
enum InstallIdentity {

    private static let service = "dev.mcfearsome.bonedust"
    private static let account = "install-id"

    /// Where the current id actually came from. Exposed for diagnosis, because the
    /// failure this guards against is silent by nature.
    enum Source: String {
        case keychain
        case defaultsFallback
        case fresh
    }

    private(set) static var lastSource: Source = .fresh
    private(set) static var lastKeychainStatus: OSStatus = errSecSuccess

    /// A mirror of the id in UserDefaults.
    ///
    /// The Keychain is still primary, because it survives a reinstall and UserDefaults
    /// does not. But the first simulator run of `InstallIdentityTests` returned a
    /// different UUID on every call: the Keychain is unavailable to an unsigned test host,
    /// every error was discarded, and the fallback was to mint a new identity. On a device
    /// that is rarer but not impossible — and when it happens the player silently loses
    /// their entire lifetime contribution to the crew debt and their place on every board,
    /// with nothing anywhere saying so.
    ///
    /// A new id is now minted only when *both* stores are empty.
    private static let fallbackKey = "bonedust.install-id"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = read() {
            lastSource = .keychain
            // Mirror it, so a later Keychain failure cannot lose an id we already had.
            defaults.set(existing, forKey: fallbackKey)
            return existing
        }

        if let mirrored = defaults.string(forKey: fallbackKey), UUID(uuidString: mirrored) != nil {
            lastSource = .defaultsFallback
            // Try to put it back where it belongs; harmless if this fails again.
            _ = write(mirrored)
            return mirrored
        }

        let fresh = UUID().uuidString
        lastSource = write(fresh) ? .keychain : .defaultsFallback
        defaults.set(fresh, forKey: fallbackKey)
        return fresh
    }

    private static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        lastKeychainStatus = status
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil
        else { return nil }
        return value
    }

    @discardableResult
    private static func write(_ value: String) -> Bool {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = Data(value.utf8)
        // Available before first unlock: a payment may be flushed from the background
        // queue while the phone is still locked, and failing then would mean the dollar
        // never reaches the crew.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(baseQuery() as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        lastKeychainStatus = status
        return status == errSecSuccess
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Only for tests: forgets the id in both stores.
    static func reset(defaults: UserDefaults = .standard) {
        SecItemDelete(baseQuery() as CFDictionary)
        defaults.removeObject(forKey: fallbackKey)
    }
}
