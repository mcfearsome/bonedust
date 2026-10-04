import BonedustCore
import Foundation
import Observation

/// The crew debt as the app knows it, cached so it is never blank.
///
/// §6: the game is fully playable offline, milestone unlocks are cached once reached, and
/// the client polls every 30 seconds *while a ledger screen is visible* — not constantly.
/// Polling a global counter in the background would be a battery cost for information
/// nobody is looking at.
@MainActor
@Observable
final class CrewLedgerStore {

    private(set) var snapshot: LedgerSnapshot?
    private(set) var me: LedgerSelf?
    private(set) var isReachable = true
    private(set) var lastUpdated: Date?

    /// Unlocks the crew has reached, cached. Once a milestone is passed it stays passed,
    /// so a player who goes offline keeps Hell Creek.
    private(set) var reachedUnlocks: Set<String> = []

    /// The outfit, as last described by the server.
    private(set) var outfit: OutfitSnapshot?
    private(set) var outfitBoard: [OutfitBoardEntry] = []
    /// Cached separately and kept on disk, so an outfit's perks survive going offline the
    /// same way the crew's milestone unlocks do.
    private(set) var outfitMembership: OutfitMembership?
    /// Last outfit action that failed, for the screen to explain rather than swallow.
    private(set) var outfitProblem: String?

    let queue: PaymentQueue
    private let client: LedgerClient
    private let defaults: UserDefaults
    private var etag: String?
    private var pollTask: Task<Void, Never>?

    private static let snapshotKey = "ledger.snapshot"
    private static let unlocksKey = "ledger.unlocks"
    private static let etagKey = "ledger.etag"
    private static let outfitKey = "ledger.outfit"

    init(
        client: LedgerClient = LedgerClient(),
        queue: PaymentQueue? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.queue = queue ?? PaymentQueue(client: client)
        self.defaults = defaults
        restore()
    }

    // MARK: Cache

    private func restore() {
        if let data = defaults.data(forKey: Self.snapshotKey),
           let decoded = try? JSONDecoder().decode(LedgerSnapshot.self, from: data) {
            snapshot = decoded
        }
        reachedUnlocks = Set(defaults.stringArray(forKey: Self.unlocksKey) ?? [])
        etag = defaults.string(forKey: Self.etagKey)
        if let data = defaults.data(forKey: Self.outfitKey),
           let decoded = try? JSONDecoder().decode(OutfitMembership.self, from: data) {
            outfitMembership = decoded
        }
    }

    private func persist() {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
        defaults.set(Array(reachedUnlocks), forKey: Self.unlocksKey)
        defaults.set(etag, forKey: Self.etagKey)
        if let outfitMembership, let data = try? JSONEncoder().encode(outfitMembership) {
            defaults.set(data, forKey: Self.outfitKey)
        } else {
            defaults.removeObject(forKey: Self.outfitKey)
        }
    }

    // MARK: Polling

    /// Starts polling. Call when a ledger screen appears.
    func startPolling(every interval: Duration = .seconds(30)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stops polling. Call when the screen goes away.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let result = try await client.ledger(etag: etag)
            isReachable = true
            etag = result.etag
            if let fresh = result.snapshot {
                snapshot = fresh
                // Union, never replace: a milestone that has been reached stays reached,
                // so going offline cannot take Hell Creek away again.
                reachedUnlocks.formUnion(fresh.reachedUnlocks)
            }
            lastUpdated = Date()
            persist()
        } catch {
            isReachable = false
        }
        await flush()
    }

    func refreshMe() async {
        me = try? await client.me()
    }

    // MARK: Payments

    /// Queues a finished slab and tries to send it straight away.
    func record(
        _ record: SlabRecord, charmIDs: [String], serverSlabID: String?, localSeed: UInt64?
    ) {
        queue.enqueue(
            record: record, charmIDs: charmIDs, serverSlabID: serverSlabID, localSeed: localSeed
        )
        Task { await flush() }
    }

    @discardableResult
    func flush() async -> Int {
        let sent = await queue.flush()
        // The debt only moves when something actually got through, so there is no point
        // re-reading it otherwise.
        if sent > 0 {
            etag = nil
            if let result = try? await client.ledger(etag: nil), let fresh = result.snapshot {
                snapshot = fresh
                etag = result.etag
                reachedUnlocks.formUnion(fresh.reachedUnlocks)
                persist()
            }
        }
        return sent
    }

    /// Asks the server for a slab seed. Nil means dig locally and queue at a fraction.
    func issueSlab(site: String) async -> IssuedSlab? {
        await client.issueSlab(site: site)
    }

    // MARK: Outfits

    func refreshOutfit() async {
        guard let snapshot = try? await client.outfit() else { return }
        apply(snapshot)
    }

    func refreshOutfitBoard() async {
        outfitBoard = (try? await client.outfitBoard()) ?? outfitBoard
    }

    @discardableResult
    func foundOutfit() async -> Bool {
        outfitProblem = nil
        do {
            apply(try await client.foundOutfit())
            return true
        } catch {
            outfitProblem = Self.describe(error)
            return false
        }
    }

    @discardableResult
    func joinOutfit(code: String) async -> Bool {
        outfitProblem = nil
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count >= 4 else {
            outfitProblem = "That code is too short."
            return false
        }
        do {
            apply(try await client.joinOutfit(code: trimmed))
            return true
        } catch {
            outfitProblem = Self.describe(error)
            return false
        }
    }

    func leaveOutfit() async {
        outfitProblem = nil
        do {
            try await client.leaveOutfit()
            outfit = nil
            outfitMembership = nil
            persist()
        } catch {
            outfitProblem = Self.describe(error)
        }
    }

    private func apply(_ snapshot: OutfitSnapshot?) {
        outfit = snapshot
        outfitMembership = snapshot?.membership
        persist()
    }

    /// Server refusals in words a player can act on.
    private static func describe(_ error: Error) -> String {
        guard let failure = error as? LedgerClient.Failure else {
            return "That did not work. Try again in a moment."
        }
        switch failure {
        case .offline:
            return "No connection. Outfits need one."
        case .rejected(let code) where code == "already_in_an_outfit":
            return "You are already in an outfit. Leave it first."
        case .rejected(let code) where code == "outfit_full":
            return "That outfit is full."
        case .rejected(let code) where code == "unknown_code":
            return "No outfit has that code."
        case .rejected:
            return "That was refused."
        case .server(let status) where status == 404:
            return "No outfit has that code."
        case .server, .malformed:
            return "That did not work. Try again in a moment."
        }
    }

    /// Everything the outfit has earned, for the dig to fold in.
    var outfitUnlocks: [String] { outfitMembership?.reachedUnlocks ?? [] }

    // MARK: Unlocks

    func hasUnlocked(_ identifier: String) -> Bool { reachedUnlocks.contains(identifier) }
    func hasUnlockedSite(_ siteID: String) -> Bool { hasUnlocked("site:\(siteID)") }
    func hasUnlockedCharmPool(_ pool: String) -> Bool { hasUnlocked("charmpool:\(pool)") }

    var remaining: Int { snapshot?.remaining ?? 0 }
    var fractionPaid: Double { snapshot?.fractionPaid ?? 0 }
    var hasEverLoaded: Bool { snapshot != nil }
}
