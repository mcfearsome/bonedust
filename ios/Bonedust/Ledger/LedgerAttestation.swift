import CryptoKit
import DeviceCheck
import Foundation

/// App Attest on the client (§6).
///
/// The device generates a Secure Enclave key once, registers it with the server, and signs
/// a hash of each request body plus a server-issued nonce.
///
/// It fails soft by design. App Attest is unavailable on the simulator, on jailbroken
/// devices, and occasionally when Apple's attestation service is down. Refusing to let
/// those players contribute to the crew debt would punish them for Apple's availability,
/// so a request simply goes out unsigned — and the *server* decides what to do with that.
/// In production it rejects; locally it can run permissive. The policy lives on the server
/// where it cannot be edited by whoever is holding the phone.
actor LedgerAttestation {

    private let service = DCAppAttestService.shared
    private var keyID: String?
    private let defaults: UserDefaults
    private static let keyIDStorageKey = "ledger.attest.keyID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keyID = defaults.string(forKey: Self.keyIDStorageKey)
    }

    var isSupported: Bool { service.isSupported }

    /// Signs a request body against a server nonce. Nil when attestation is unavailable.
    func assertion(for body: Data, nonce: String) async -> String? {
        guard service.isSupported, let keyID = await ensureKey() else { return nil }
        let clientData = body + Data(nonce.utf8)
        let hash = Data(SHA256.hash(data: clientData))
        do {
            let assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
            return assertion.base64EncodedString()
        } catch {
            // A failed assertion is not worth blocking a payment the queue can retry.
            return nil
        }
    }

    /// The attestation blob for registering a freshly generated key.
    func attestation(nonce: String) async -> (keyID: String, blob: String)? {
        guard service.isSupported, let keyID = await ensureKey() else { return nil }
        let hash = Data(SHA256.hash(data: Data(nonce.utf8)))
        do {
            let blob = try await service.attestKey(keyID, clientDataHash: hash)
            return (keyID, blob.base64EncodedString())
        } catch {
            // Most often this means the key was already attested, which is fine.
            return nil
        }
    }

    private func ensureKey() async -> String? {
        if let keyID { return keyID }
        do {
            let generated = try await service.generateKey()
            keyID = generated
            defaults.set(generated, forKey: Self.keyIDStorageKey)
            return generated
        } catch {
            return nil
        }
    }
}
