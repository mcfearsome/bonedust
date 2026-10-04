import BonedustCore
import XCTest
@testable import Bonedust

/// The M4 surfaces: the Collection filling up, set perks reaching the dig, trails, and
/// the Game Center boundary.
@MainActor
final class MetaFlowTests: XCTestCase {

    private func makeCoordinator() -> (RunCoordinator, RunStore, GameSettings) {
        let settings = GameSettings(
            defaults: UserDefaults(suiteName: "bonedust.meta.\(UUID().uuidString)")!
        )
        let store = RunStore(inMemory: true)
        return (RunCoordinator(settings: settings, store: store), store, settings)
    }

    /// Finishes the slab on screen, having exposed enough to identify the specimen.
    private func digAndBag(_ coordinator: RunCoordinator) async {
        guard let engine = coordinator.digEngine else { return XCTFail("no dig") }
        // The specimen has to be identified or the collection record is not real, so this
        // stops on that rather than on a pass count.
        XCTAssertTrue(sweepUntilIdentified(engine), "the sweep never identified the fossil")
        engine.tick(delta: Double(engine.totalDaylight) + 1)
        coordinator.slabFinished(engine)
    }

    private func playWholeRun(_ coordinator: RunCoordinator) async {
        for _ in 1...5 {
            await digAndBag(coordinator)
            await coordinator.continueFromResults()
            if coordinator.screen == .supplyTent { await coordinator.leaveShop() }
        }
    }

    func testAFinishedRunFillsTheCollection() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.meta.collection.discoveredCount, 0)
        await playWholeRun(coordinator)
        XCTAssertEqual(coordinator.screen, .runEnd)
        XCTAssertGreaterThan(coordinator.meta.collection.discoveredCount, 0,
                             "five dug slabs catalogued nothing")
        XCTAssertTrue(coordinator.meta.collection.records.values.allSatisfy { $0.timesFound > 0 })
    }

    func testTheCollectionPersistsAcrossCoordinators() async {
        let (coordinator, store, settings) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await playWholeRun(coordinator)
        let found = coordinator.meta.collection.discoveredCount
        XCTAssertGreaterThan(found, 0)

        let relaunched = RunCoordinator(settings: settings, store: store)
        XCTAssertEqual(relaunched.meta.collection.discoveredCount, found)
    }

    func testResultsPreviewIncludesTheSlabJustBagged() async {
        // The specimen is not catalogued until the run settles, but the pips on the
        // results card have to show what the player just earned.
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        await digAndBag(coordinator)
        guard let record = coordinator.lastRecord else { return XCTFail() }
        XCTAssertEqual(coordinator.meta.collection.discoveredCount, 0, "not yet absorbed")
        if record.identified {
            XCTAssertTrue(coordinator.collectionIncludingCurrentRun.has(record.fossilID))
        }
    }

    func testSetPerksReachTheDig() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        let before = coordinator.digEngine?.totalDaylight ?? 0

        // Complete the ichthyosaur set, whose perk is five more seconds everywhere.
        guard let set = ContentCatalog.shared.setsByID["ichthyosaur"] else { return XCTFail() }
        coordinator.debugCompleteSet(set.id)
        await coordinator.debugSettleRun(succeed: true)
        coordinator.acknowledgeRunEnd()
        await coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.digEngine?.totalDaylight ?? 0, before + 5, accuracy: 0.01)
    }

    func testASiteSpecificSetPerkDoesNothingAtTheWrongSite() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRun(siteID: "charmouth")
        let before = coordinator.digEngine?.modifiers.payoutMultiplier ?? 0
        coordinator.debugCompleteSet("trex")   // Hell Creek only
        await coordinator.debugSettleRun(succeed: true)
        coordinator.acknowledgeRunEnd()
        await coordinator.startRun(siteID: "charmouth")
        XCTAssertEqual(coordinator.digEngine?.modifiers.payoutMultiplier ?? 0, before,
                       accuracy: 0.0001)
    }

    func testOnlyEarnedTrailsCanBeSelected() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.unlockedTrails.count, 1, "nothing earned yet")
        XCTAssertEqual(coordinator.selectedTrail.id, "natural")

        coordinator.selectTrail("verdigris")
        XCTAssertEqual(coordinator.selectedTrail.id, "natural",
                       "a trail beyond the player's Reputation must not apply")

        coordinator.debugSetReputation(5_000)
        XCTAssertGreaterThan(coordinator.unlockedTrails.count, 1)
        coordinator.selectTrail("verdigris")
        XCTAssertEqual(coordinator.selectedTrail.id, "verdigris")
    }

    func testTrailSelectionPersists() {
        let (coordinator, store, settings) = makeCoordinator()
        coordinator.debugSetReputation(5_000)
        coordinator.selectTrail("ochre")
        let relaunched = RunCoordinator(settings: settings, store: store)
        XCTAssertEqual(relaunched.selectedTrail.id, "ochre")
    }

    func testReputationOpensSitesInSiteSelect() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.unlockedSites.map(\.id), ["charmouth"])
        coordinator.debugSetReputation(60)
        XCTAssertTrue(coordinator.unlockedSites.map(\.id).contains("wheeler"))
        coordinator.debugSetReputation(180)
        XCTAssertTrue(coordinator.unlockedSites.map(\.id).contains("green_river"))
        XCTAssertFalse(coordinator.unlockedSites.map(\.id).contains("hell_creek"),
                       "crew milestones are M5, not Reputation")
    }

    func testRewardsAreReportedWhenARunSettles() async {
        let (coordinator, _, _) = makeCoordinator()
        var observed: MetaProgress.Rewards?
        coordinator.onRunAbsorbed = { _, rewards in observed = rewards }
        await coordinator.startRun(siteID: "charmouth")
        await playWholeRun(coordinator)
        XCTAssertNotNil(observed, "the Game Center hook never fired")
        XCTAssertEqual(observed, coordinator.lastRewards)
    }
}

@MainActor
final class GameCenterServiceTests: XCTestCase {

    func testGentleModeIsExcludedFromLeaderboards() {
        // §7: Gentle mode runs do not appear on leaderboards. Enforced at this one
        // boundary rather than at every call site.
        let service = GameCenterService()
        var meta = MetaProgress()
        meta.longestStreak = 5
        service.record(meta, rewards: MetaProgress.Rewards(), gentleMode: true)
        XCTAssertFalse(service.isEligibleForLeaderboards)
        service.record(meta, rewards: MetaProgress.Rewards(), gentleMode: false)
        XCTAssertTrue(service.isEligibleForLeaderboards)
    }

    func testReportingWithoutAuthenticationIsSafe() {
        // Not signed in, offline, or Game Center unavailable: all of it must be a no-op
        // rather than an error the dig loop has to handle.
        let service = GameCenterService()
        XCTAssertFalse(service.isAuthenticated)
        var rewards = MetaProgress.Rewards()
        rewards.newAchievements = ["flawless", "first_set"]
        service.record(MetaProgress(), rewards: rewards, gentleMode: false)
        service.report(achievementIDs: ["does_not_exist"])
        service.submit(MetaProgress())
    }

    func testEveryLeaderboardIDIsDistinct() {
        XCTAssertEqual(Set(Leaderboard.all).count, Leaderboard.all.count)
        XCTAssertTrue(Leaderboard.all.allSatisfy { $0.hasPrefix("bonedust.leaderboard.") })
    }
}
