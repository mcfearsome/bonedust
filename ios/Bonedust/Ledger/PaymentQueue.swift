import BonedustCore
import Foundation

/// One payment waiting to reach the ledger.
struct QueuedPayment: Sendable, Codable, Equatable, Identifiable {
    var slabID: String
    var amount: Int
    var fossilID: String
    var siteID: String
    var durationMillis: Int
    var exposure: Float
    var intact: Float
    var gems: Int
    var charmIDs: [String]
    /// Nil when the slab's seed came from the server. Set for a slab dug offline, which
    /// the server credits at a fraction (docs/CREW_LEDGER.md).
    var localSeed: UInt64?
    var queuedAt: Date
    var attempts: Int

    var id: String { slabID }

    var wireFormat: [String: AnyCodableValue] {
        var fields: [String: AnyCodableValue] = [
            "slab_id": .string(slabID),
            "amount": .int(amount),
            "fossil_id": .string(fossilID),
            "site": .string(siteID),
            "duration_ms": .int(durationMillis),
            "exposure": .double(Double(exposure)),
            "intact": .double(Double(intact)),
            "gems": .int(gems),
            "charms": .strings(charmIDs),
        ]
        if let localSeed {
            // A string: a seed past 2^53 does not survive a JSON number intact, and a
            // server scoring a different seed would reject an honest payment.
            fields["seed"] = .string(String(localSeed))
        }
        return fields
    }
}

/// A JSON value, so the wire format can be built without a bespoke Encodable per request.
enum AnyCodableValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case strings([String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode([String].self) { self = .strings(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}

/// Payments that have not reached the server yet (§6: "Payments queue locally and sync
/// when back online").
///
/// Three properties make it safe:
///
/// - **It is durable.** Written to disk on every change, so a payment survives the app
///   being killed between bagging a slab and reaching a network.
/// - **Retries cannot double-count.** Each entry is keyed by its slab id, which the server
///   has a unique index on; a retry of a payment that actually succeeded comes back as the
///   existing one rather than as a second credit.
/// - **A refusal is final.** A 422 means the server will never accept that payment, so it
///   is dropped. Keeping it would wedge the queue forever behind an item that can never
///   clear, and every later payment with it.
@MainActor
@Observable
final class PaymentQueue {

    private(set) var pending: [QueuedPayment] = []
    private(set) var isFlushing = false
    /// Payments the server refused outright. Kept for the debug overlay, not retried.
    private(set) var refused: [QueuedPayment] = []

    private let storeURL: URL
    private let client: LedgerClient
    /// Stop retrying an entry that keeps failing for reasons other than a refusal, so a
    /// permanent server fault cannot spin the queue forever.
    private let maximumAttempts = 25

    init(client: LedgerClient, storeURL: URL? = nil) {
        self.client = client
        self.storeURL = storeURL ?? PaymentQueue.defaultStoreURL()
        load()
    }

    private static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "bonedust-payment-queue.json")
    }

    // MARK: Enqueue

    func enqueue(_ payment: QueuedPayment) {
        guard !pending.contains(where: { $0.slabID == payment.slabID }) else { return }
        pending.append(payment)
        save()
    }

    /// Builds the queue entry for a finished slab.
    /// `amount` is what the crew is actually owed for this slab, which is the payout less
    /// any kit bought earlier in the week. It defaults to the full payout so a caller that
    /// has no run context -- the tests, and the retry path -- still behaves as before.
    func enqueue(
        record: SlabRecord, amount: Int? = nil, charmIDs: [String],
        serverSlabID: String?, localSeed: UInt64?
    ) {
        enqueue(QueuedPayment(
            // A server-issued id when there is one, so the server can match the slab it
            // scored. Otherwise the local seed identifies it.
            slabID: serverSlabID ?? "local-\(record.seed)",
            amount: amount ?? record.payout.total,
            fossilID: record.fossilID,
            siteID: record.siteID,
            durationMillis: record.durationMillis,
            exposure: record.payout.exposure,
            intact: record.payout.intact,
            gems: record.wholeGems,
            charmIDs: charmIDs,
            localSeed: serverSlabID == nil ? localSeed ?? record.seed : nil,
            queuedAt: Date(),
            attempts: 0
        ))
    }

    // MARK: Flush

    @discardableResult
    func flush() async -> Int {
        guard !isFlushing, !pending.isEmpty else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var sent = 0
        // Oldest first, and one at a time: the ledger is not latency-critical and a burst
        // would only trip the rate limiter.
        for payment in pending {
            do {
                try await client.submit(payment)
                remove(payment.slabID)
                sent += 1
            } catch LedgerClient.Failure.rejected(let code) {
                // Final. Dropping it is the only way the rest of the queue ever moves.
                drop(payment.slabID, reason: code)
            } catch {
                // Offline or a server fault: keep it and stop, rather than hammering.
                bumpAttempts(payment.slabID)
                break
            }
        }
        return sent
    }

    // MARK: Storage

    private func remove(_ slabID: String) {
        pending.removeAll { $0.slabID == slabID }
        save()
    }

    private func drop(_ slabID: String, reason: String) {
        if let payment = pending.first(where: { $0.slabID == slabID }) {
            refused.append(payment)
        }
        remove(slabID)
    }

    private func bumpAttempts(_ slabID: String) {
        guard let index = pending.firstIndex(where: { $0.slabID == slabID }) else { return }
        pending[index].attempts += 1
        if pending[index].attempts >= maximumAttempts {
            drop(slabID, reason: "too_many_attempts")
        } else {
            save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pending)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // A queue that cannot be written is still usable in memory for this session.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([QueuedPayment].self, from: data)
        else { return }
        pending = decoded
    }

    /// Total still owed to the crew from this device, for the ledger screen.
    var pendingTotal: Int { pending.reduce(0) { $0 + $1.amount } }
}
