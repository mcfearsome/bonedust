import BonedustCore
import Foundation

/// The crew ledger, as the app sees it.
struct LedgerSnapshot: Sendable, Codable, Equatable {
    var totalDebt: Int
    var paid: Int
    var remaining: Int
    var newGamePlusDebt: Int
    var milestones: [LedgerMilestone]
    var diggersSeason: Int
    var paidToday: Int
    var season: String
    var recent: [LedgerPayment]

    enum CodingKeys: String, CodingKey {
        case totalDebt = "total_debt"
        case paid
        case remaining
        case newGamePlusDebt = "new_game_plus_debt"
        case milestones
        case diggersSeason = "diggers_season"
        case paidToday = "paid_today"
        case season
        case recent
    }

    var fractionPaid: Double {
        totalDebt == 0 ? 0 : min(1, Double(paid) / Double(totalDebt))
    }

    /// Everything the crew has unlocked, flattened for the unlock cache.
    var reachedUnlocks: Set<String> {
        Set(milestones.filter(\.reached).flatMap(\.unlocks))
    }

    var nextMilestone: LedgerMilestone? {
        milestones.first { !$0.reached }
    }
}

struct LedgerMilestone: Sendable, Codable, Equatable, Identifiable {
    var key: String
    var amount: Int
    var name: String
    var beat: String?
    var unlocks: [String]
    var cosmetics: [String]
    var reached: Bool

    var id: String { key }
}

struct LedgerPayment: Sendable, Codable, Equatable, Identifiable {
    var name: String
    var amount: Int
    var fossilID: String?
    var at: Date

    enum CodingKeys: String, CodingKey {
        case name, amount, at
        case fossilID = "fossil_id"
    }

    var id: String { "\(name)-\(amount)-\(at.timeIntervalSince1970)" }
}

struct LedgerSelf: Sendable, Codable, Equatable {
    var paidTotal: Int
    var paidSeason: Int
    var bestSlabAmount: Int
    var rank: Int
    var diggers: Int
    var shareOfPaid: Double

    enum CodingKeys: String, CodingKey {
        case paidTotal = "paid_total"
        case paidSeason = "paid_season"
        case bestSlabAmount = "best_slab_amount"
        case rank, diggers
        case shareOfPaid = "share_of_paid"
    }
}

/// An issued slab: the seed the server will score this dig against.
struct IssuedSlab: Sendable, Equatable {
    var slabID: String
    var seed: UInt64
    var site: String
}

/// Talks to the crew ledger service.
///
/// Every method throws rather than returning an optional, and every caller is expected to
/// carry on regardless: the game is fully playable offline (§6), so a failure here is an
/// ordinary condition and never an error the player sees.
actor LedgerClient {

    enum Failure: Error, Equatable {
        case offline
        case rejected(code: String)
        case server(status: Int)
        case malformed
    }

    /// `api.bonedust.app`. The apex is left for a marketing page.
    ///
    /// Read from Info.plist rather than hard-coded, so a debug build can be pointed at a
    /// local server by editing `ios/project.yml` instead of this file.
    static let productionBase: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "BonedustLedgerBaseURL")
            as? String
        return configured.flatMap(URL.init(string:)) ?? URL(string: "https://api.bonedust.app")!
    }()

    private let baseURL: URL
    private let session: URLSession
    private let installID: String
    private let attestation: LedgerAttestation
    private let clientVersion: String

    init(
        baseURL: URL = LedgerClient.productionBase,
        installID: String = InstallIdentity.current(),
        attestation: LedgerAttestation = LedgerAttestation(),
        session: URLSession? = nil,
        clientVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0"
    ) {
        self.baseURL = baseURL
        self.installID = installID
        self.attestation = attestation
        self.clientVersion = clientVersion
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Short timeouts on purpose. The ledger is never on the critical path of a
            // dig, so a slow network should give up quickly and let the queue retry
            // rather than hold anything up.
            configuration.timeoutIntervalForRequest = 10
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Endpoints

    func ledger(etag: String?) async throws -> (snapshot: LedgerSnapshot?, etag: String?) {
        var request = URLRequest(url: baseURL.appending(path: "v1/ledger"))
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        decorate(&request)
        let (data, response) = try await perform(request)
        // 304: what the client already has is current. §6's whole reason for the ETag.
        if response.statusCode == 304 { return (nil, etag) }
        return (try decode(LedgerSnapshot.self, from: data), response.value(forHTTPHeaderField: "ETag"))
    }

    func me() async throws -> LedgerSelf {
        var request = URLRequest(url: baseURL.appending(path: "v1/me"))
        decorate(&request)
        let (data, _) = try await perform(request)
        return try decode(LedgerSelf.self, from: data)
    }

    func setDisplayName(_ name: String?) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/me"))
        request.httpMethod = "PATCH"
        let body = try JSONEncoder().encode(["display_name": name ?? ""])
        try await sign(&request, body: body)
        _ = try await perform(request)
    }

    /// Asks for a seed. Returns nil when offline, and the caller digs a local slab.
    func issueSlab(site: String) async -> IssuedSlab? {
        do {
            var request = URLRequest(url: baseURL.appending(path: "v1/slabs"))
            request.httpMethod = "POST"
            let body = try JSONEncoder().encode(["site": site])
            try await sign(&request, body: body)
            let (data, _) = try await perform(request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let slabID = object["slab_id"] as? String,
                  // A string, because a seed past 2^53 does not survive a JSON number.
                  let seedText = object["seed"] as? String,
                  let seed = UInt64(seedText),
                  let site = object["site"] as? String
            else { return nil }
            return IssuedSlab(slabID: slabID, seed: seed, site: site)
        } catch {
            return nil
        }
    }

    /// Sends one payment. Throws so the queue knows to keep it.
    func submit(_ payment: QueuedPayment) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/payments"))
        request.httpMethod = "POST"
        let body = try JSONEncoder().encode(payment.wireFormat)
        try await sign(&request, body: body)
        _ = try await perform(request)
    }

    // MARK: Plumbing

    private func decorate(_ request: inout URLRequest) {
        request.setValue(installID, forHTTPHeaderField: "X-Bonedust-Install")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Bonedust-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    /// Attaches the body and, where the device can, an App Attest assertion over it.
    ///
    /// The nonce comes from the server for every request, which is what makes a captured
    /// payment useless: the signature covers both the body and a value that has already
    /// been spent.
    private func sign(_ request: inout URLRequest, body: Data) async throws {
        decorate(&request)
        request.httpBody = body
        guard let nonce = try? await challenge() else { return }
        request.setValue(nonce, forHTTPHeaderField: "X-Bonedust-Challenge")
        if let assertion = await attestation.assertion(for: body, nonce: nonce) {
            request.setValue(assertion, forHTTPHeaderField: "X-Bonedust-Assertion")
        }
    }

    private func challenge() async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/attest/challenge"))
        decorate(&request)
        let (data, _) = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = object["nonce"] as? String
        else { throw Failure.malformed }
        return nonce
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        switch http.statusCode {
        case 200...299, 304:
            return (data, http)
        case 422:
            // The server refused the payment itself. Retrying will never help, so the
            // queue must drop it rather than wedge on it forever.
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["error"] as? String } ?? "rejected"
            throw Failure.rejected(code: code)
        default:
            throw Failure.server(status: http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw Failure.malformed
        }
    }
}
