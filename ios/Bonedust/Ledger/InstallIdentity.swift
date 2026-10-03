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

    /// The install id, created on first call.
    static func current() -> String {
        if let existing = read() { return existing }
        let fresh = UUID().uuidString
        write(fresh)
        return fresh
    }

    private static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
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
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Only for tests: forgets the id so a fresh one is generated.
    static func reset() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
