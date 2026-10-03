import BonedustCore
import XCTest
@testable import Bonedust

/// The M2 flow: five days, autosave, settle up.
@MainActor
final class RunCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> (RunCoordinator, RunStore, GameSettings) {
        let settings = GameSettings(
            defaults: UserDefaults(suiteName: "bonedust.flow.\(UUID().uuidString)")!
        )
        let store = RunStore(inMemory: true)
        return (RunCoordinator(settings: settings, store: store), store, settings)
    }

    /// Finishes whatever slab is on screen by running the daylight out.
    private func burnThroughSlab(_ coordinator: RunCoordinator) {
        guard let engine = coordinator.digEngine else { return XCTFail("no dig on screen") }
        engine.brushBegan(at: Vec2(48, 64))
        // A few real strokes so the slab is not completely untouched.
        for x in stride(from: Float(10), through: 86, by: 2) {
            engine.brushMoved(to: Vec2(x, 64), deltaMillis: 16.67)
        }
        engine.brushEnded()
        engine.tick(delta: Double(engine.totalDaylight) + 1)
        XCTAssertTrue(engine.isFinished)
        coordinator.slabFinished(engine)
    }

    func testFreshCoordinatorOpensOnTheTitle() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.screen, .title)
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertEqual(coordinator.meta.nextTier, 1)
    }

    func testOnlyStartingSitesAreUnlockedAtZeroReputation() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.unlockedSites.map(\.id), ["charmouth"])
    }

    func testStartingARunOpensADig() {
        let (coordinator, store, _) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.screen, .dig)
        XCTAssertNotNil(coordinator.digEngine)
        XCTAssertEqual(coordinator.run?.currentDay, 1)
        XCTAssertNotNil(store.loadRun(), "the run was not written to the save slot")
    }

    func testAWholeRunReachesTheEndScreen() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        for day in 1...5 {
            XCTAssertEqual(coordinator.screen, .dig, "day \(day)")
            XCTAssertEqual(coordinator.run?.currentDay, day)
            burnThroughSlab(coordinator)
            XCTAssertEqual(coordinator.screen, .slabResults, "day \(day)")
            coordinator.continueFromResults()
        }
        XCTAssertEqual(coordinator.screen, .runEnd)
        XCTAssertEqual(coordinator.run?.slabs.count, 5)
        XCTAssertTrue(coordinator.run?.isOver ?? false)
    }

    func testEachDayDrawsADifferentSlab() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        var seeds: [UInt64] = []
        for _ in 1...5 {
            seeds.append(coordinator.digEngine?.layout.seed ?? 0)
            burnThroughSlab(coordinator)
            coordinator.continueFromResults()
        }
        XCTAssertEqual(Set(seeds).count, 5, "two days dug the same slab")
    }

    func testFinishingARunUpdatesMetaAndClearsTheSaveSlot() {
        let (coordinator, store, _) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        for _ in 1...5 {
            burnThroughSlab(coordinator)
            coordinator.continueFromResults()
        }
        XCTAssertGreaterThan(coordinator.meta.lifetimeContribution, 0)
        XCTAssertNil(store.loadRun(), "a settled run must not be resumable")
        coordinator.acknowledgeRunEnd()
        XCTAssertEqual(coordinator.screen, .title)
        XCTAssertFalse(coordinator.canContinue)
    }

    func testAutosaveAndResumeRestoreTheSameSlabMidDig() {
        let (coordinator, store, settings) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        guard let engine = coordinator.digEngine else { return XCTFail() }

        engine.brushBegan(at: Vec2(20, 40))
        for x in stride(from: Float(20), through: 80, by: 1.5) {
            engine.brushMoved(to: Vec2(x, 56), deltaMillis: 16.67)
        }
        engine.brushEnded()
        engine.tick(delta: 12)
        let exposedBefore = engine.exposedBoneCells
        let seedBefore = engine.layout.seed
        let daylightBefore = engine.daylightRemaining
        XCTAssertGreaterThan(exposedBefore, 0, "the test needs to have dug something")

        coordinator.autosave()
        XCTAssertNotNil(store.loadSlab())

        // A fresh coordinator over the same store is what a relaunch looks like.
        let resumed = RunCoordinator(settings: settings, store: store)
        XCTAssertTrue(resumed.canContinue)
        resumed.continueRun()
        XCTAssertEqual(resumed.screen, .dig)
        guard let restored = resumed.digEngine else { return XCTFail("no dig after resume") }
        XCTAssertEqual(restored.layout.seed, seedBefore)
        XCTAssertEqual(restored.exposedBoneCells, exposedBefore)
        XCTAssertEqual(restored.daylightRemaining, daylightBefore, accuracy: 0.01)
        XCTAssertNil(resumed.resumeProblem)
    }

    func testAResumedSlabStartsPausedAndResumesOnTouch() {
        // §5: "restores the slab with daylight paused."
        let (coordinator, store, settings) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        coordinator.digEngine?.brushBegan(at: Vec2(40, 40))
        coordinator.digEngine?.brushEnded()
        coordinator.autosave()

        let resumed = RunCoordinator(settings: settings, store: store)
        resumed.continueRun()
        guard let engine = resumed.digEngine else { return XCTFail() }
        XCTAssertEqual(engine.phase, .waiting)
        let before = engine.daylightRemaining
        engine.tick(delta: 5)
        XCTAssertEqual(engine.daylightRemaining, before, "paused daylight still ran down")
        engine.brushBegan(at: Vec2(40, 40))
        engine.tick(delta: 5)
        XCTAssertLessThan(engine.daylightRemaining, before)
    }

    func testACorruptSnapshotFallsBackToAFreshSlabWithAnExplanation() {
        let (coordinator, store, settings) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        coordinator.digEngine?.brushBegan(at: Vec2(40, 40))
        coordinator.autosave()

        // Simulate a content update changing the fossil's bone mask.
        guard var snapshot = store.loadSlab() else { return XCTFail() }
        var bytes = snapshot.cells
        bytes[SlabGrid.index(12, 12) * SlabSnapshot.bytesPerCell + 1] ^= SlabGrid.Flag.bone
        snapshot.cells = bytes
        store.save(slab: snapshot)

        let resumed = RunCoordinator(settings: settings, store: store)
        resumed.continueRun()
        XCTAssertEqual(resumed.screen, .dig, "a refused snapshot must not strand the player")
        XCTAssertNotNil(resumed.digEngine)
        XCTAssertNotNil(resumed.resumeProblem)
        XCTAssertNil(store.loadSlab(), "the bad snapshot should have been discarded")
    }

    func testAbandoningARunCountsAsAFailure() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.startRun(siteID: "charmouth")
        burnThroughSlab(coordinator)
        coordinator.continueFromResults()
        coordinator.abandonRun()
        XCTAssertEqual(coordinator.screen, .runEnd)
        XCTAssertEqual(coordinator.meta.runsFailed, 1)
        XCTAssertEqual(coordinator.meta.nextTier, 1)
    }

    func testGentleModeReachesTheDig() {
        let (coordinator, _, settings) = makeCoordinator()
        settings.gentleMode = true
        coordinator.startRun(siteID: "charmouth")
        guard let engine = coordinator.digEngine else { return XCTFail() }
        // 0.5 from gentle mode, times the site and fossil multipliers.
        XCTAssertLessThan(engine.modifiers.crackMultiplier, 1)
        XCTAssertEqual(engine.modifiers.payoutMultiplier, 0.8, accuracy: 0.0001)
    }
}

@MainActor
final class RunStoreTests: XCTestCase {

    func testMetaRoundTrips() {
        let store = RunStore(inMemory: true)
        XCTAssertEqual(store.loadMeta(), MetaProgress())
        var meta = MetaProgress()
        meta.reputation = 440
        meta.nextTier = 3
        store.save(meta: meta)
        XCTAssertEqual(store.loadMeta(), meta)
    }

    func testRunRoundTrips() {
        let store = RunStore(inMemory: true)
        XCTAssertNil(store.loadRun())
        let run = RunState(seed: 11, siteID: "charmouth", tier: 2)
        store.save(run: run)
        XCTAssertEqual(store.loadRun(), run)
        store.save(run: nil)
        XCTAssertNil(store.loadRun())
    }

    func testASettledRunIsNotOffered() {
        // Only an in-progress run is resumable.
        let store = RunStore(inMemory: true)
        var run = RunState(seed: 11, siteID: "charmouth")
        run.phase = .failed(shortfall: 100)
        store.save(run: run)
        XCTAssertNil(store.loadRun())
    }

    func testClearingTheRunAlsoDropsTheSlab() {
        let store = RunStore(inMemory: true)
        let site = ContentCatalog.shared.site("charmouth")!
        let sim = SlabSimulation(seed: 5, site: site)
        store.save(run: RunState(seed: 5, siteID: "charmouth"))
        store.save(slab: SlabSnapshot.capture(
            sim, daylightRemaining: 30, toolID: BrushTool.brush.id, day: 1
        ))
        XCTAssertNotNil(store.loadSlab())
        store.save(run: nil)
        XCTAssertNil(store.loadSlab(), "an orphaned slab would resume into no run")
    }

    func testSlabSnapshotRoundTripsThroughTheStore() {
        let store = RunStore(inMemory: true)
        let site = ContentCatalog.shared.site("hell_creek")!
        var sim = SlabSimulation(seed: 77, site: site)
        sim.beginStroke(at: Vec2(30, 30), tool: .brush)
        for x in stride(from: Float(30), through: 70, by: 2) {
            sim.moveStroke(to: Vec2(x, 44), deltaMillis: 16.67, tool: .brush)
        }
        sim.endStroke()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 17.5, toolID: BrushTool.fineBrush.id, day: 4
        )
        store.save(slab: snapshot)
        XCTAssertEqual(store.loadSlab(), snapshot)
        let restored = try? store.loadSlab()?.restore()
        XCTAssertEqual(restored?.simulation.exposedBone, sim.exposedBone)
        XCTAssertEqual(restored?.day, 4)
    }
}
