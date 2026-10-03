import BonedustCore
import Foundation
import Observation

/// Drives the run: which screen is up, what the run state is, and when to autosave.
///
/// The navigation lives here rather than in SwiftUI's `NavigationStack` because the
/// flow is a state machine, not a browsable hierarchy — there is no "back" out of a
/// slab, and the phase in `RunState` already decides what comes next. Mapping that
/// onto a push/pop stack would mean keeping two sources of truth in step.
@MainActor
@Observable
final class RunCoordinator {

    enum Screen: Equatable {
        case title
        case siteSelect
        case dig
        case slabResults
        case supplyTent
        case runEnd
        case collection
        case crewLedger
    }

    private(set) var screen: Screen = .title
    private(set) var run: RunState?
    private(set) var meta: MetaProgress
    /// Non-nil exactly while a slab is on screen or its results are.
    private(set) var digEngine: DigEngine?
    private(set) var lastRecord: SlabRecord?
    /// Set when a resume was refused, so the title screen can say why.
    private(set) var resumeProblem: String?
    /// What the last finished run added, for the end screen.
    private(set) var lastRewards = MetaProgress.Rewards()
    /// Called when a run has been folded into meta progress, so Game Center reporting
    /// can live outside the coordinator rather than being wired through it.
    var onRunAbsorbed: ((MetaProgress, MetaProgress.Rewards) -> Void)?

    let settings: GameSettings
    /// The crew debt (§6). The run loop works without it reaching anything, which is what
    /// "fully playable offline" has to mean in practice.
    let ledger: CrewLedgerStore
    let store: RunStore
    private let catalog: ContentCatalog

    init(
        settings: GameSettings,
        store: RunStore,
        ledger: CrewLedgerStore? = nil,
        catalog: ContentCatalog = .shared
    ) {
        self.settings = settings
        self.store = store
        // Built here rather than as a default argument: default arguments are evaluated
        // in a nonisolated context and this type is main-actor bound.
        self.ledger = ledger ?? CrewLedgerStore()
        self.catalog = catalog
        self.meta = store.loadMeta()
        self.run = store.loadRun()
    }

    // MARK: Derived

    var canContinue: Bool { run != nil }

    var currentSite: Site? {
        guard let run else { return nil }
        return catalog.site(run.siteID)
    }

    var unlockedSites: [Site] {
        // Reputation gates are M4; crew milestones are M5. Until then only the
        // Reputation gate is enforced, and the ledger-gated sites stay locked rather
        // than being quietly handed over.
        catalog.sites.filter { site in
            switch site.unlock {
            case .start: return true
            case .reputation(let needed): return meta.reputation >= needed
            case .crewMilestone:
                // From the cached ledger: once the crew reaches a milestone it stays
                // reached, so going offline cannot take Hell Creek away again.
                return ledger.hasUnlockedSite(site.id)
            }
        }
    }

    // MARK: Navigation

    func showTitle() {
        screen = .title
    }

    /// The Collection with the current run's finds folded in.
    ///
    /// A slab's specimen is not catalogued until the run settles, but the results card
    /// has to show the pips the player just earned — otherwise finding the third T. rex
    /// piece shows two pips and reads as a bug.
    var collectionIncludingCurrentRun: Collection {
        guard let run else { return meta.collection }
        var preview = meta.collection
        for slab in run.slabs { preview.record(slab) }
        return preview
    }

    func showCollection() {
        screen = .collection
    }

    func showCrewLedger() {
        screen = .crewLedger
    }

    // MARK: Cosmetics

    /// Trails the player has earned (§5). Always at least one.
    var unlockedTrails: [BrushTrail] {
        let unlocked = catalog.unlockedTrails(reputation: meta.reputation)
        return unlocked.isEmpty ? [.natural] : unlocked
    }

    var selectedTrail: BrushTrail {
        meta.brushTrailID.flatMap { catalog.trail($0) }
            ?? unlockedTrails.first
            ?? .natural
    }

    func selectTrail(_ id: String) {
        // Guard against a save that names a trail the current Reputation no longer
        // reaches, which a content change could produce.
        guard unlockedTrails.contains(where: { $0.id == id }) else { return }
        meta.brushTrailID = id
        store.save(meta: meta)
    }

    func beginNewRun() {
        resumeProblem = nil
        screen = .siteSelect
    }

    func startRun(siteID: String) {
        var fresh = RunState(
            seed: UInt64.random(in: 1...(UInt64.max >> 2)),
            siteID: siteID,
            tier: meta.nextTier,
            // The kit survives a successful run and is seized after a failed one, so it
            // comes from meta rather than starting from the brush every time. Without
            // this the installment ramp is unwinnable by construction.
            toolIDs: meta.carriedToolIDs,
            charmIDs: meta.carriedCharmIDs
        )
        fresh.phase = .digging(day: 1)
        run = fresh
        store.save(run: fresh)
        store.save(slab: nil)
        Task { await prepareDig(day: 1) }
    }

    /// Resumes from the autosave slot, including a part-dug slab.
    func continueRun() {
        guard let run else { return }
        switch run.phase {
        case .digging(let day):
            openDig(day: day, restoring: true)
        case .results(let day):
            // Saved mid-results: show the card again rather than skipping it.
            if let record = run.record(forDay: day) {
                lastRecord = record
                screen = .slabResults
            } else {
                screen = .title
            }
        case .supplyTent:
            openShop()
        case .succeeded, .failed:
            screen = .runEnd
        }
    }

    /// Asks the ledger for this day's seed before opening the dig, then opens it either way.
    ///
    /// The request is awaited rather than fired alongside, because the seed decides which
    /// slab gets generated and a slab that changed underneath the player a second after
    /// appearing would be worse than an offline one. The client timeout is short for
    /// exactly this reason.
    private func prepareDig(day: Int) async {
        guard var current = run, current.issuedSlabs[day] == nil else {
            openDig(day: day, restoring: false)
            return
        }
        let siteID = current.siteForSlab(onDay: day, catalog: catalog)
        if let issued = await ledger.issueSlab(site: siteID) {
            current.noteIssued(
                IssuedSlabRef(slabID: issued.slabID, seed: issued.seed), forDay: day
            )
            run = current
            store.save(run: current)
        }
        openDig(day: day, restoring: false)
    }

    private func openDig(day: Int, restoring: Bool) {
        guard let run else { return }
        // A charm can send this day's slab to another site entirely, so the site is
        // resolved per day rather than taken from the run.
        let siteID = run.siteForSlab(onDay: day, catalog: catalog)
        guard let site = catalog.site(siteID) else { return }
        // Gentle mode plus any permanent perks from completed skeleton sets. Both fold
        // into the same ModifierSet the charms use, so a set perk is not a special case
        // anywhere downstream.
        let extra = ModifierSet.combining([
            settings.gentleModeModifiers,
            meta.setPerks(forSite: siteID, catalog: catalog),
        ])
        let loadout = run.loadout(catalog: catalog)

        if restoring, let snapshot = store.loadSlab(), snapshot.day == day {
            do {
                let restored = try snapshot.restore(catalog: catalog, tuning: .standard)
                digEngine = DigEngine(
                    restored: restored, site: site, loadout: loadout, extraModifiers: extra
                )
                resumeProblem = nil
                screen = .dig
                return
            } catch {
                // A refused snapshot is the designed outcome of a content update
                // changing a fossil's shape. Start the day's slab fresh and say so.
                resumeProblem = Self.describe(error)
                store.save(slab: nil)
            }
        }

        digEngine = DigEngine(
            seed: run.effectiveSeed(forDay: day),
            site: site,
            day: day,
            loadout: loadout,
            catalog: catalog,
            extraModifiers: extra
        )
        screen = .dig
    }

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? SlabSnapshot.Failure else {
            return "The saved slab could not be opened."
        }
        switch failure {
        case .contentChanged:
            return "An update changed this fossil. Your slab has been re-cut."
        case .schemaMismatch:
            return "The saved slab is from an older version. It has been re-cut."
        case .truncated:
            return "The saved slab was incomplete. It has been re-cut."
        case .unknownSite(let id):
            return "The site \(id) is no longer available."
        }
    }

    // MARK: Slab lifecycle

    /// Called when the dig ends, by bagging or by running out of daylight.
    func slabFinished(_ engine: DigEngine) {
        guard var current = run, case .digging(let day) = current.phase else { return }
        let record = engine.slabRecord(day: day)
        current.completeSlab(record)
        run = current
        lastRecord = record
        store.save(run: current)
        store.save(slab: nil)

        // Every dollar pays the crew debt (§6). Queued, not awaited: a slab must never
        // wait on a network, and the queue is durable so nothing is lost either way.
        ledger.record(
            record,
            charmIDs: current.charmIDs,
            serverSlabID: current.serverSlabID(forDay: day),
            localSeed: current.slabSeed(forDay: day)
        )
        screen = .slabResults
    }

    /// Leaves the results card: into the tent, or settle up.
    func continueFromResults() {
        guard var current = run else { return }
        current.advance()
        run = current

        if case .supplyTent = current.phase {
            store.save(run: current)
            openShop()
            return
        }

        if current.isOver {
            lastRewards = meta.absorb(current, catalog: catalog)
            store.save(meta: meta)
            onRunAbsorbed?(meta, lastRewards)
            // The finished run stays in `run` so the end screen can read it, but it is
            // cleared from disk: §5 allows one *in-progress* slot, and a settled run is
            // not resumable.
            store.save(run: nil)
            digEngine = nil
            screen = .runEnd
            return
        }

        store.save(run: current)
        if case .digging(let day) = current.phase {
            Task { await prepareDig(day: day) }
        }
    }

    // MARK: Supply tent

    private func openShop() {
        guard var current = run, case .supplyTent = current.phase else { return }
        current.openShop(reputation: meta.reputation, pools: unlockedPools, catalog: catalog)
        run = current
        store.save(run: current)
        digEngine = nil
        screen = .supplyTent
    }

    /// Which item pools are open. The vault is a crew milestone, and the ledger client
    /// arrives at M5, so for now only the shop pool is available.
    private var unlockedPools: Set<ItemPool> { meta.unlockedPools() }

    func buyTool(_ id: String) { mutateRun { try? $0.buyTool(id, catalog: catalog) } }
    func buyCharm(_ id: String) { mutateRun { try? $0.buyCharm(id, catalog: catalog) } }
    func sellTool(_ id: String) { mutateRun { $0.sellTool(id, catalog: catalog) } }
    func sellCharm(_ id: String) { mutateRun { $0.sellCharm(id, catalog: catalog) } }

    func restock() {
        mutateRun {
            try? $0.restock(reputation: meta.reputation, pools: unlockedPools, catalog: catalog)
        }
    }

    func leaveShop() {
        guard var current = run, case .supplyTent(let day) = current.phase else { return }
        current.leaveShop()
        run = current
        store.save(run: current)
        Task { await prepareDig(day: day + 1) }
    }

    /// Applies a change to the run and persists it. Purchases are saved immediately
    /// because a crash between buying and digging must not hand back the cash.
    private func mutateRun(_ change: (inout RunState) -> Void) {
        guard var current = run else { return }
        change(&current)
        run = current
        store.save(run: current)
    }

    /// Clears the finished run and returns to the title.
    func acknowledgeRunEnd() {
        run = nil
        digEngine = nil
        lastRecord = nil
        store.clearEverything()
        screen = .title
    }

    func abandonRun() {
        guard var current = run else { return }
        current.abandon()
        lastRewards = meta.absorb(current, catalog: catalog)
        run = current
        store.save(meta: meta)
        onRunAbsorbed?(meta, lastRewards)
        store.save(run: nil)
        digEngine = nil
        screen = .runEnd
    }

    // MARK: Autosave

    /// Writes the in-progress slab. Called when the app leaves the foreground, which
    /// is the only moment §5's guarantee actually has to hold.
    func autosave() {
        guard let run, let engine = digEngine, case .digging(let day) = run.phase else { return }
        guard !engine.isFinished else { return }
        engine.pause()
        store.save(run: run)
        store.save(slab: engine.snapshot(day: day))
    }
}

// MARK: - Test hooks

extension RunCoordinator {
    /// Puts an item in the kit without paying for it.
    ///
    /// Tests about *what a tool does* should not also depend on what the shop happened
    /// to roll or on whether the run could afford it. Kept out of the shopping path so
    /// it cannot be reached by accident.
    func debugGrantTool(_ id: String) {
        guard var current = run, !current.toolIDs.contains(id) else { return }
        current.toolIDs.append(id)
        current.shop.toolIDs.removeAll { $0 == id }
        run = current
    }

    func debugGrantCharm(_ id: String) {
        guard var current = run, !current.charmIDs.contains(id) else { return }
        current.charmIDs.append(id)
        current.shop.charmIDs.removeAll { $0 == id }
        run = current
    }

    /// Marks a skeleton set complete without digging its pieces.
    func debugCompleteSet(_ setID: String) {
        guard let set = catalog.setsByID[setID] else { return }
        for piece in set.pieces {
            meta.collection.records[piece] = SpecimenRecord(
                fossilID: piece, timesFound: 1, bestExposure: 1, bestIntact: 1, bestPayout: 1
            )
        }
        if !meta.completedSetIDs.contains(setID) { meta.completedSetIDs.append(setID) }
        store.save(meta: meta)
    }

    func debugSetReputation(_ value: Int) {
        meta.reputation = value
        store.save(meta: meta)
    }

    /// Ends the run as a success or a failure, without playing it.
    func debugSettleRun(succeed: Bool) {
        guard var current = run else { return }
        current.cash = succeed ? current.installment + 100 : 0
        current.phase = .results(day: current.totalDays)
        run = current
        continueFromResults()
    }
}
