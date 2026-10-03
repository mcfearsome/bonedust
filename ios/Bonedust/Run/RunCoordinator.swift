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
            tier: meta.nextTier
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
        guard case .digging(let day) = run.phase else {
            // Saved mid-results: show the card again rather than skipping it.
            if case .results(let day) = run.phase, let record = run.record(forDay: day) {
                lastRecord = record
                screen = .slabResults
            } else {
                screen = .title
            }
            return
        }
        openDig(day: day, restoring: true)
    }

    private func openDig(day: Int, restoring: Bool) {
        guard let run, let site = catalog.site(run.siteID) else { return }
        let extra = settings.gentleModeModifiers

        if restoring, let snapshot = store.loadSlab(), snapshot.day == day {
            do {
                let restored = try snapshot.restore(catalog: catalog, tuning: .standard)
                digEngine = DigEngine(restored: restored, site: site, extraModifiers: extra)
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

    /// Leaves the results card.
    func continueFromResults() {
        guard var current = run else { return }
        current.advance()
        run = current

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
