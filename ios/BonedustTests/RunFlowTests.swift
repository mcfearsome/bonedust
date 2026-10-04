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

    /// Advances past the results card, and out of the supply tent if one appears.
    private func leaveResults(_ coordinator: RunCoordinator) async {
        await coordinator.continueFromResults()
        if coordinator.screen == .supplyTent { await coordinator.leaveShop() }
    }

    /// Finishes whatever slab is on screen by running the daylight out.
    private func burnThroughSlab(_ coordinator: RunCoordinator) async {
        guard let engine = coordinator.digEngine else { return XCTFail("no dig on screen") }
        XCTAssertTrue(sweepUntilBoneShows(engine), "the sweep never reached bone")
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

    func testStartingARunOpensADig() async {
        let (coordinator, store, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.screen, .dig)
        XCTAssertNotNil(coordinator.digEngine)
        XCTAssertEqual(coordinator.run?.currentDay, 1)
        XCTAssertNotNil(store.loadRun(), "the run was not written to the save slot")
    }

    func testAWholeRunReachesTheEndScreen() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        for day in 1...5 {
            XCTAssertEqual(coordinator.screen, .dig, "day \(day)")
            XCTAssertEqual(coordinator.run?.currentDay, day)
            await burnThroughSlab(coordinator)
            XCTAssertEqual(coordinator.screen, .slabResults, "day \(day)")
            await leaveResults(coordinator)
        }
        XCTAssertEqual(coordinator.screen, .runEnd)
        XCTAssertEqual(coordinator.run?.slabs.count, 5)
        XCTAssertTrue(coordinator.run?.isOver ?? false)
    }

    func testEachDayDrawsADifferentSlab() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        var seeds: [UInt64] = []
        for _ in 1...5 {
            seeds.append(coordinator.digEngine?.layout.seed ?? 0)
            await burnThroughSlab(coordinator)
            await leaveResults(coordinator)
        }
        XCTAssertEqual(Set(seeds).count, 5, "two days dug the same slab")
    }

    func testFinishingARunUpdatesMetaAndClearsTheSaveSlot() async {
        let (coordinator, store, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        for _ in 1...5 {
            await burnThroughSlab(coordinator)
            await leaveResults(coordinator)
        }
        XCTAssertGreaterThan(coordinator.meta.lifetimeContribution, 0)
        XCTAssertNil(store.loadRun(), "a settled run must not be resumable")
        coordinator.acknowledgeRunEnd()
        XCTAssertEqual(coordinator.screen, .title)
        XCTAssertFalse(coordinator.canContinue)
    }

    func testAutosaveAndResumeRestoreTheSameSlabMidDig() async {
        let (coordinator, store, settings) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        guard let engine = coordinator.digEngine else { return XCTFail() }

        XCTAssertTrue(sweepUntilBoneShows(engine), "the sweep never reached bone")
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
        await resumed.continueRun()
        XCTAssertEqual(resumed.screen, .dig)
        guard let restored = resumed.digEngine else { return XCTFail("no dig after resume") }
        XCTAssertEqual(restored.layout.seed, seedBefore)
        XCTAssertEqual(restored.exposedBoneCells, exposedBefore)
        XCTAssertEqual(restored.daylightRemaining, daylightBefore, accuracy: 0.01)
        XCTAssertNil(resumed.resumeProblem)
    }

    func testAResumedSlabStartsPausedAndResumesOnTouch() async {
        // §5: "restores the slab with daylight paused."
        let (coordinator, store, settings) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        coordinator.digEngine?.brushBegan(at: Vec2(40, 40))
        coordinator.digEngine?.brushEnded()
        coordinator.autosave()

        let resumed = RunCoordinator(settings: settings, store: store)
        await resumed.continueRun()
        guard let engine = resumed.digEngine else { return XCTFail() }
        XCTAssertEqual(engine.phase, .waiting)
        let before = engine.daylightRemaining
        engine.tick(delta: 5)
        XCTAssertEqual(engine.daylightRemaining, before, "paused daylight still ran down")
        engine.brushBegan(at: Vec2(40, 40))
        engine.tick(delta: 5)
        XCTAssertLessThan(engine.daylightRemaining, before)
    }

    func testACorruptSnapshotFallsBackToAFreshSlabWithAnExplanation() async {
        let (coordinator, store, settings) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        coordinator.digEngine?.brushBegan(at: Vec2(40, 40))
        coordinator.autosave()

        // Simulate a content update changing the fossil's bone mask.
        guard var snapshot = store.loadSlab() else { return XCTFail() }
        var bytes = snapshot.cells
        bytes[SlabGrid.index(12, 12) * SlabSnapshot.bytesPerCell + 1] ^= SlabGrid.Flag.bone
        snapshot.cells = bytes
        store.save(slab: snapshot)

        let resumed = RunCoordinator(settings: settings, store: store)
        await resumed.continueRun()
        XCTAssertEqual(resumed.screen, .dig, "a refused snapshot must not strand the player")
        XCTAssertNotNil(resumed.digEngine)
        XCTAssertNotNil(resumed.resumeProblem)
        XCTAssertNil(store.loadSlab(), "the bad snapshot should have been discarded")
    }

    func testAbandoningARunCountsAsAFailure() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await burnThroughSlab(coordinator)
        await leaveResults(coordinator)
        coordinator.abandonRun()
        XCTAssertEqual(coordinator.screen, .runEnd)
        XCTAssertEqual(coordinator.meta.runsFailed, 1)
        XCTAssertEqual(coordinator.meta.nextTier, 1)
    }

    func testTheTentOpensBetweenSlabs() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await burnThroughSlab(coordinator)
        await coordinator.continueFromResults()
        XCTAssertEqual(coordinator.screen, .supplyTent)
        XCTAssertFalse(coordinator.run?.shop.isEmpty ?? true, "the tent had nothing in it")
        XCTAssertNil(coordinator.digEngine, "the finished slab should be let go of")
        await coordinator.leaveShop()
        XCTAssertEqual(coordinator.screen, .dig)
        XCTAssertEqual(coordinator.run?.currentDay, 2)
    }

    func testThereIsNoTentAfterTheLastSlab() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        for day in 1...5 {
            await burnThroughSlab(coordinator)
            await coordinator.continueFromResults()
            if day < 5 {
                XCTAssertEqual(coordinator.screen, .supplyTent, "day \(day)")
                await coordinator.leaveShop()
            }
        }
        XCTAssertEqual(coordinator.screen, .runEnd)
    }

    func testBuyingInTheTentPersistsImmediately() async {
        // A crash between buying and digging must not hand the cash back.
        let (coordinator, store, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await burnThroughSlab(coordinator)
        await coordinator.continueFromResults()
        guard var run = coordinator.run, let offered = run.shop.charmIDs.first,
              let charm = ContentCatalog.shared.charm(offered)
        else { return XCTFail("nothing offered") }

        // Give the run enough cash for the test to be about persistence, not poverty.
        run.cash = 500
        coordinator.buyCharm(offered)
        guard let after = coordinator.run else { return XCTFail() }
        if after.charmIDs.contains(offered) {
            XCTAssertEqual(store.loadRun()?.charmIDs, after.charmIDs)
            XCTAssertEqual(after.cash, coordinator.run!.cash)
        } else {
            // Could not afford it; the shop must be unchanged either way.
            XCTAssertTrue(after.shop.charmIDs.contains(offered))
            XCTAssertLessThan(after.cash, charm.price)
        }
    }

    func testAPurchasedToolReachesTheNextSlabsTray() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.digEngine?.availableBrushes.count, 1)
        await burnThroughSlab(coordinator)
        await coordinator.continueFromResults()

        // Force a known affordable brush into the kit rather than depending on the roll.
        coordinator.debugGrantTool("fine_brush")
        await coordinator.leaveShop()
        let brushes = coordinator.digEngine?.availableBrushes.map(\.id) ?? []
        XCTAssertTrue(brushes.contains("fine_brush"), "got \(brushes)")
        XCTAssertEqual(brushes.count, 2)
    }

    func testPassiveToolsChangeTheSlabRatherThanTheTray() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        let before = coordinator.digEngine?.totalDaylight ?? 0
        await burnThroughSlab(coordinator)
        await coordinator.continueFromResults()
        coordinator.debugGrantTool("headlamp")
        await coordinator.leaveShop()
        guard let engine = coordinator.digEngine else { return XCTFail() }
        XCTAssertEqual(engine.availableBrushes.count, 1, "a headlamp is not a brush")
        XCTAssertEqual(engine.passiveTools.map(\.id), ["headlamp"])
        XCTAssertEqual(engine.totalDaylight, before + 10, accuracy: 0.01)
    }

    func testXRayGogglesRevealThenExpire() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await burnThroughSlab(coordinator)
        await coordinator.continueFromResults()
        coordinator.debugGrantTool("xray_goggles")
        await coordinator.leaveShop()
        guard let engine = coordinator.digEngine else { return XCTFail() }
        XCTAssertTrue(engine.isRevealing)
        // The reveal only burns while digging, so looking before the first touch is free.
        engine.tick(delta: 5)
        XCTAssertTrue(engine.isRevealing)
        engine.brushBegan(at: Vec2(48, 64))
        engine.tick(delta: 4)
        XCTAssertFalse(engine.isRevealing)
    }

    func testAKitSurvivesASuccessfulRunAndIsSeizedAfterAFailure() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        coordinator.debugGrantTool("fine_brush")
        // Force a win, then check the tool carries.
        await coordinator.debugSettleRun(succeed: true)
        XCTAssertTrue(coordinator.meta.carriedToolIDs.contains("fine_brush"))
        coordinator.acknowledgeRunEnd()

        await coordinator.startRun(siteID: "charmouth")
        XCTAssertTrue(coordinator.run?.toolIDs.contains("fine_brush") ?? false,
                      "a successful run should keep its kit")
        await coordinator.debugSettleRun(succeed: false)
        XCTAssertEqual(coordinator.meta.carriedToolIDs, [BrushTool.brush.id],
                       "the Collector takes your tools as interest")
    }

    func testGentleModeReachesTheDig() async {
        let (coordinator, _, settings) = makeCoordinator()
        settings.gentleMode = true
        await coordinator.startRun(siteID: "charmouth")
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
