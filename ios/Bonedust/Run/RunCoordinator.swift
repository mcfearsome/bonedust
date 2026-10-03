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
    }

    private(set) var screen: Screen = .title
    private(set) var run: RunState?
    private(set) var meta: MetaProgress
    /// Non-nil exactly while a slab is on screen or its results are.
    private(set) var digEngine: DigEngine?
    private(set) var lastRecord: SlabRecord?
    /// Set when a resume was refused, so the title screen can say why.
    private(set) var resumeProblem: String?

    let settings: GameSettings
    private let store: RunStore
    private let catalog: ContentCatalog

    init(
        settings: GameSettings,
        store: RunStore,
        catalog: ContentCatalog = .shared
    ) {
        self.settings = settings
        self.store = store
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
            case .crewMilestone: return false
            }
        }
    }

    // MARK: Navigation

    func showTitle() {
        screen = .title
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
        openDig(day: 1, restoring: false)
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

    private func openDig(day: Int, restoring: Bool) {
        guard let run else { return }
        // A charm can send this day's slab to another site entirely, so the site is
        // resolved per day rather than taken from the run.
        let siteID = run.siteForSlab(onDay: day, catalog: catalog)
        guard let site = catalog.site(siteID) else { return }
        let extra = settings.gentleModeModifiers
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
            seed: run.slabSeed(forDay: day),
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
            meta.absorb(current)
            store.save(meta: meta)
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
            openDig(day: day, restoring: false)
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
    private var unlockedPools: Set<ItemPool> { [.shop] }

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
        openDig(day: day + 1, restoring: false)
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
        meta.absorb(current)
        run = current
        store.save(meta: meta)
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

    /// Ends the run as a success or a failure, without playing it.
    func debugSettleRun(succeed: Bool) {
        guard var current = run else { return }
        current.cash = succeed ? current.installment + 100 : 0
        current.phase = .results(day: current.totalDays)
        run = current
        continueFromResults()
    }
}
