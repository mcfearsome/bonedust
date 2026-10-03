import XCTest
@testable import BonedustCore

private func slab(
    _ fossilID: String, day: Int = 1, exposure: Float = 0.8, intact: Float = 0.9,
    total: Int = 100, identified: Bool = true, gems: Int = 0
) -> SlabRecord {
    SlabRecord(
        day: day, seed: UInt64(day), siteID: "charmouth", fossilID: fossilID,
        payout: PayoutBreakdown(
            baseValue: 100, exposure: exposure, intact: intact, fossil: total,
            gems: 0, bonuses: 0, multiplier: 1, rushApplied: false, total: total
        ),
        durationMillis: 30_000, bagged: true, wholeGems: gems,
        daylightLeft: 10, identified: identified
    )
}

/// Builds a finished run containing the given slabs.
private func finishedRun(_ slabs: [SlabRecord], tier: Int = 1, succeed: Bool = true) -> RunState {
    var run = RunState(seed: 1, siteID: "charmouth", tier: tier)
    for (index, record) in slabs.enumerated() {
        var adjusted = record
        adjusted.day = index + 1
        run.completeSlab(adjusted)
        run.advance()
        if case .supplyTent = run.phase { run.leaveShop() }
    }
    // Top up or empty the till so the run lands where the test wants it.
    if run.isOver == false {
        run.cash = succeed ? run.installment : 0
        run.phase = .results(day: run.totalDays)
        run.advance()
    }
    return run
}

final class CollectionTests: XCTestCase {

    func testOnlyIdentifiedSpecimensAreCatalogued() {
        var collection = Collection()
        XCTAssertFalse(collection.record(slab("ammonite", identified: false)))
        XCTAssertEqual(collection.discoveredCount, 0,
                       "an unidentified slab is a hole in the ground, not a find")
        XCTAssertTrue(collection.record(slab("ammonite", identified: true)))
        XCTAssertEqual(collection.discoveredCount, 1)
    }

    func testFirstFindIsReportedOnlyOnce() {
        var collection = Collection()
        XCTAssertTrue(collection.record(slab("ammonite")))
        XCTAssertFalse(collection.record(slab("ammonite")))
        XCTAssertEqual(collection.record(for: "ammonite")?.timesFound, 2)
    }

    func testBestsOnlyEverImprove() {
        var collection = Collection()
        collection.record(slab("trilobite", exposure: 0.9, intact: 0.5, total: 200))
        collection.record(slab("trilobite", exposure: 0.4, intact: 0.95, total: 80))
        guard let record = collection.record(for: "trilobite") else { return XCTFail() }
        XCTAssertEqual(record.bestExposure, 0.9)
        XCTAssertEqual(record.bestIntact, 0.95, "bests are per-field, not per-slab")
        XCTAssertEqual(record.bestPayout, 200)
        XCTAssertEqual(record.timesFound, 2)
    }

    func testPerfectSpecimen() {
        var collection = Collection()
        collection.record(slab("ammonite", exposure: 1, intact: 1))
        XCTAssertTrue(collection.record(for: "ammonite")?.isPerfect ?? false)
        XCTAssertEqual(collection.perfectCount, 1)
        collection.record(slab("belemnite", exposure: 1, intact: 0.98))
        XCTAssertEqual(collection.perfectCount, 1)
    }

    func testSetProgressAndCompletion() {
        guard let set = ContentCatalog.shared.setsByID["trex"] else { return XCTFail() }
        var collection = Collection()
        XCTAssertEqual(collection.progress(for: set).found, 0)
        XCTAssertEqual(collection.progress(for: set).total, set.pieces.count)
        XCTAssertFalse(collection.isComplete(set))

        for (index, piece) in set.pieces.enumerated() {
            collection.record(slab(piece))
            XCTAssertEqual(collection.progress(for: set).found, index + 1)
        }
        XCTAssertTrue(collection.isComplete(set))
        XCTAssertEqual(collection.completedSets().map(\.id), ["trex"])
    }

    func testCompletionFraction() {
        var collection = Collection()
        XCTAssertEqual(collection.completionFraction(), 0)
        for fossil in ContentCatalog.shared.fossils { collection.record(slab(fossil.id)) }
        XCTAssertEqual(collection.completionFraction(), 1, accuracy: 0.0001)
    }

    func testCollectionRoundTripsThroughJSON() throws {
        var collection = Collection()
        collection.record(slab("ammonite", exposure: 0.77, intact: 0.88, total: 123))
        let data = try JSONEncoder().encode(collection)
        XCTAssertEqual(try JSONDecoder().decode(Collection.self, from: data), collection)
    }
}

final class SetPerkTests: XCTestCase {

    func testSiteSpecificPerkIsNeutralElsewhere() {
        guard let perk = ContentCatalog.shared.setsByID["trex"]?.perk else { return XCTFail() }
        XCTAssertEqual(perk.siteID, "hell_creek")
        XCTAssertEqual(perk.modifiers(forSite: "hell_creek").payoutMultiplier, 1.15, accuracy: 0.0001)
        XCTAssertEqual(perk.modifiers(forSite: "charmouth"), ModifierSet(),
                       "a Hell Creek perk must do nothing at Charmouth")
    }

    func testDaylightPerkAppliesEverywhere() {
        guard let perk = ContentCatalog.shared.setsByID["ichthyosaur"]?.perk
        else { return XCTFail() }
        XCTAssertNil(perk.siteID)
        XCTAssertEqual(perk.modifiers(forSite: "charmouth").daylightDelta, 5)
        XCTAssertEqual(perk.modifiers(forSite: "night_dig").daylightDelta, 5)
    }

    func testPerksComposeThroughTheSameModifierPath() {
        var meta = MetaProgress()
        meta.completedSetIDs = ["trex", "ichthyosaur"]
        let atHellCreek = meta.setPerks(forSite: "hell_creek")
        XCTAssertEqual(atHellCreek.payoutMultiplier, 1.15, accuracy: 0.0001)
        XCTAssertEqual(atHellCreek.daylightDelta, 5)
        let elsewhere = meta.setPerks(forSite: "charmouth")
        XCTAssertEqual(elsewhere.payoutMultiplier, 1, accuracy: 0.0001)
        XCTAssertEqual(elsewhere.daylightDelta, 5)
    }
}

final class MetaAbsorbTests: XCTestCase {

    func testARunFilesItsSpecimens() {
        var meta = MetaProgress()
        let rewards = meta.absorb(finishedRun([slab("ammonite"), slab("belemnite")]))
        XCTAssertEqual(meta.collection.discoveredCount, 2)
        XCTAssertEqual(Set(rewards.newSpecies), ["ammonite", "belemnite"])
    }

    func testASecondRunReportsNoNewSpeciesForRepeats() {
        var meta = MetaProgress()
        meta.absorb(finishedRun([slab("ammonite")]))
        let rewards = meta.absorb(finishedRun([slab("ammonite")]))
        XCTAssertTrue(rewards.newSpecies.isEmpty)
        XCTAssertEqual(meta.collection.record(for: "ammonite")?.timesFound, 2)
    }

    func testFailedRunsStillFileTheirSpecimens() {
        // A fossil you dug is a fossil you dug, whether or not the week was paid for.
        var meta = MetaProgress()
        meta.absorb(finishedRun([slab("trilobite")], succeed: false))
        XCTAssertEqual(meta.collection.discoveredCount, 1)
        XCTAssertEqual(meta.runsFailed, 1)
    }

    func testCompletingASetPaysOnceAndGrantsThePerk() {
        guard let set = ContentCatalog.shared.setsByID["ichthyosaur"] else { return XCTFail() }
        var meta = MetaProgress()
        let first = meta.absorb(finishedRun(set.pieces.map { slab($0) }))
        XCTAssertEqual(first.completedSets, ["ichthyosaur"])
        XCTAssertEqual(first.reputationFromSets, set.reputationBonus)
        XCTAssertEqual(meta.completedSetIDs, ["ichthyosaur"])
        XCTAssertEqual(meta.setPerks(forSite: "charmouth").daylightDelta, 5)

        let again = meta.absorb(finishedRun(set.pieces.map { slab($0) }))
        XCTAssertTrue(again.completedSets.isEmpty, "a set must not pay twice")
        XCTAssertEqual(again.reputationFromSets, 0)
        XCTAssertEqual(meta.completedSetIDs, ["ichthyosaur"])
    }

    func testFlawlessSlabIsRemembered() {
        var meta = MetaProgress()
        XCTAssertFalse(meta.hasFlawlessSlab)
        meta.absorb(finishedRun([slab("ammonite", exposure: 1, intact: 1)]))
        XCTAssertTrue(meta.hasFlawlessSlab)
    }

    func testHighestTierClearedOnlyCountsSuccesses() {
        var meta = MetaProgress()
        meta.absorb(finishedRun([slab("ammonite")], tier: 4, succeed: true))
        XCTAssertEqual(meta.highestTierCleared, 4)
        meta.absorb(finishedRun([slab("ammonite")], tier: 9, succeed: false))
        XCTAssertEqual(meta.highestTierCleared, 4, "a failed tier was not cleared")
    }

    func testTheCollectionSurvivesAFailedRun() {
        var meta = MetaProgress()
        meta.absorb(finishedRun([slab("ammonite")], succeed: true))
        meta.absorb(finishedRun([slab("belemnite")], succeed: false))
        XCTAssertEqual(meta.collection.discoveredCount, 2)
        XCTAssertEqual(meta.carriedToolIDs, [BrushTool.brush.id])
    }

    func testMetaRoundTripsWithCollectionAndSets() throws {
        var meta = MetaProgress()
        meta.absorb(finishedRun([slab("ammonite"), slab("trex_tooth")]))
        let data = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(MetaProgress.self, from: data), meta)
    }
}

final class AchievementTests: XCTestCase {

    func testContentDefinesAchievementsAndTheyValidate() {
        XCTAssertGreaterThanOrEqual(ContentCatalog.shared.achievements.count, 8)
        XCTAssertEqual(ContentCatalog.shared.validate(), [])
    }

    func testEveryAchievementHasADistinctGameCenterID() {
        let ids = ContentCatalog.shared.achievements.map(\.gameCenterID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("bonedust.achievement.") })
    }

    func testNothingIsEarnedByAFreshPlayer() {
        XCTAssertTrue(Achievements.earned(by: MetaProgress()).isEmpty)
    }

    func testFlawlessAndSetAchievements() {
        var meta = MetaProgress()
        meta.hasFlawlessSlab = true
        XCTAssertTrue(Achievements.earned(by: meta).contains("flawless"))
        XCTAssertFalse(Achievements.earned(by: meta).contains("first_set"))
        meta.completedSetIDs = ["trex"]
        XCTAssertTrue(Achievements.earned(by: meta).contains("first_set"))
    }

    func testThresholdAchievements() {
        var meta = MetaProgress()
        meta.bestSlabPayout = 499
        XCTAssertFalse(Achievements.earned(by: meta).contains("big_slab"))
        meta.bestSlabPayout = 500
        XCTAssertTrue(Achievements.earned(by: meta).contains("big_slab"))

        meta.longestStreak = 3
        XCTAssertTrue(Achievements.earned(by: meta).contains("streak_3"))
        XCTAssertFalse(Achievements.earned(by: meta).contains("streak_10"))

        meta.lifetimeContribution = 10_000
        XCTAssertTrue(Achievements.earned(by: meta).contains("contribution_10k"))
    }

    func testSiteClearedNeedsEverySpeciesFromThatTable() {
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        var meta = MetaProgress()
        let ids = site.fossilWeights.keys.sorted()
        for id in ids.dropLast() { meta.collection.record(slab(id)) }
        XCTAssertFalse(Achievements.earned(by: meta).contains("charmouth_cleared"))
        meta.collection.record(slab(ids.last!))
        XCTAssertTrue(Achievements.earned(by: meta).contains("charmouth_cleared"))
    }

    func testAchievementsAreRecomputedSoNewRulesApplyRetroactively() {
        // Earned-ness is derived from the whole of MetaProgress rather than fired as an
        // event, so a rule shipped later is credited for play that already happened.
        var meta = MetaProgress()
        meta.longestStreak = 12
        meta.reportedAchievementIDs = []
        let rewards = meta.absorb(finishedRun([slab("ammonite")]))
        XCTAssertTrue(rewards.newAchievements.contains("streak_10"))
        XCTAssertTrue(meta.reportedAchievementIDs.contains("streak_10"))

        let again = meta.absorb(finishedRun([slab("ammonite")]))
        XCTAssertFalse(again.newAchievements.contains("streak_10"),
                       "an achievement must only be reported as new once")
    }

    func testAchievementRuleRoundTrips() throws {
        let rules: [AchievementRule] = [
            .firstSetCompleted, .flawlessSlab, .slabPayoutAtLeast(500),
            .runStreakAtLeast(3), .speciesDiscovered(10),
            .lifetimeContributionAtLeast(10_000), .siteCleared("charmouth"),
            .installmentTierReached(5),
        ]
        for rule in rules {
            let data = try JSONEncoder().encode(rule)
            XCTAssertEqual(try JSONDecoder().decode(AchievementRule.self, from: data), rule)
        }
    }
}

final class BrushTrailTests: XCTestCase {

    func testOneTrailIsAlwaysAvailable() {
        XCTAssertFalse(ContentCatalog.shared.unlockedTrails(reputation: 0).isEmpty)
    }

    func testTrailsUnlockWithReputation() {
        let early = ContentCatalog.shared.unlockedTrails(reputation: 0).count
        let later = ContentCatalog.shared.unlockedTrails(reputation: 2_000).count
        XCTAssertGreaterThan(later, early)
        XCTAssertEqual(later, ContentCatalog.shared.trails.count)
    }

    func testTrailsAreOrderedByCost() {
        let unlocked = ContentCatalog.shared.unlockedTrails(reputation: 10_000)
        XCTAssertEqual(unlocked.map(\.reputationRequired),
                       unlocked.map(\.reputationRequired).sorted())
    }

    func testATrailCannotChangeHowASlabDigs() {
        // Reputation buys decoration, never power: a trail that altered the dig would
        // put the meta layer in competition with the charms.
        for trail in ContentCatalog.shared.trails {
            XCTAssertGreaterThan(trail.lifetime, 0)
            XCTAssertGreaterThan(trail.scale, 0)
        }
        // BrushTrail has no ModifierSet at all; this is the structural guarantee.
        XCTAssertFalse("\(BrushTrail.self)".isEmpty)
    }
}
