import XCTest
@testable import BonedustCore

private func slab(_ fossilID: String = "ammonite", total: Int) -> SlabRecord {
    SlabRecord(
        day: 1, seed: 1, siteID: "charmouth", fossilID: fossilID,
        payout: PayoutBreakdown(
            baseValue: 100, exposure: 1, intact: 1, fossil: total, gems: 0,
            bonuses: 0, multiplier: 1, rushApplied: false, total: total
        ),
        durationMillis: 30_000, bagged: true, wholeGems: 0, daylightLeft: 5, identified: true
    )
}

private func runPaying(_ amount: Int) -> RunState {
    var run = RunState(seed: 1, siteID: "charmouth")
    run.completeSlab(slab(total: amount))
    run.cash = run.installment
    run.phase = .results(day: run.totalDays)
    run.advance()
    return run
}

final class PersonalMilestoneTests: XCTestCase {

    func testContentDefinesALadderAndItValidates() {
        XCTAssertGreaterThanOrEqual(ContentCatalog.shared.personalMilestones.count, 5)
        XCTAssertEqual(ContentCatalog.shared.validate(), [])
    }

    func testTheLadderIsOrderedAndEveryRungPaysSomething() {
        let ladder = ContentCatalog.shared.personalMilestones
        XCTAssertEqual(ladder.map(\.amount), ladder.map(\.amount).sorted())
        XCTAssertEqual(Set(ladder.map(\.amount)).count, ladder.count, "duplicate amounts")
        for rung in ladder {
            XCTAssertFalse(rung.unlocks.isEmpty && rung.cosmetics.isEmpty,
                           "\(rung.id) rewards nothing")
        }
    }

    func testARungIsReportedOnceAndOnlyOnce() {
        guard let first = ContentCatalog.shared.personalMilestones.first else { return XCTFail() }
        var meta = MetaProgress()
        let rewards = meta.absorb(runPaying(first.amount))
        XCTAssertEqual(rewards.personalMilestones.map(\.id), [first.id])

        let again = meta.absorb(runPaying(first.amount))
        XCTAssertTrue(again.personalMilestones.isEmpty, "a rung paid twice")
    }

    func testARunCanPassSeveralRungsAtOnce() {
        let ladder = ContentCatalog.shared.personalMilestones
        guard ladder.count >= 2 else { return XCTFail() }
        var meta = MetaProgress()
        let rewards = meta.absorb(runPaying(ladder[1].amount))
        XCTAssertEqual(rewards.personalMilestones.map(\.id), [ladder[0].id, ladder[1].id])
    }

    func testFailedRunsStillCountTowardTheLadder() {
        // The rungs are about what you have dug out of the ground, not about whether the
        // Collector was paid that week.
        guard let first = ContentCatalog.shared.personalMilestones.first else { return XCTFail() }
        var run = RunState(seed: 2, siteID: "charmouth")
        run.completeSlab(slab(total: first.amount))
        run.cash = 0
        run.phase = .results(day: run.totalDays)
        run.advance()
        var meta = MetaProgress()
        let rewards = meta.absorb(run)
        XCTAssertEqual(meta.runsFailed, 1)
        XCTAssertEqual(rewards.personalMilestones.map(\.id), [first.id])
    }

    func testUnlocksAccumulateWithContribution() {
        var meta = MetaProgress()
        XCTAssertTrue(meta.personalUnlocks().isEmpty)
        meta.lifetimeContribution = 1_000_000
        let unlocks = meta.personalUnlocks()
        XCTAssertFalse(unlocks.isEmpty)
        XCTAssertTrue(unlocks.contains("charmpool:vault"))
    }
}

final class ContributionPerkTests: XCTestCase {

    func testPerksResolveToModifiers() {
        let set = ContributionPerks.modifiers(for: ["perk:personal_daylight_3"])
        XCTAssertEqual(set.daylightDelta, 3)
        XCTAssertEqual(set.payoutMultiplier, 1)
    }

    func testPersonalAndOutfitPerksStack() {
        let set = ContributionPerks.modifiers(
            for: ["perk:personal_daylight_3", "perk:outfit_daylight_5", "perk:outfit_payout_1_02"]
        )
        XCTAssertEqual(set.daylightDelta, 8)
        XCTAssertEqual(set.payoutMultiplier, 1.02, accuracy: 0.0001)
    }

    func testAnUnknownRewardDoesNothing() {
        // The ladder is server-side data: an older client must display a rung it does not
        // understand and apply nothing, rather than guess.
        XCTAssertEqual(ContributionPerks.modifiers(for: ["perk:from_the_future"]), ModifierSet())
        XCTAssertEqual(ContributionPerks.pools(for: ["charmpool:unheard_of"]), [.shop])
    }

    func testPerksAreSmallEnoughNotToRebalanceTheGame() {
        // M3's lesson: a reward that makes money easier compounds, because more income
        // pays the debt faster, which reaches the next rung sooner. Every rung in both
        // ladders together must stay modest.
        let everything = ContentCatalog.shared.personalMilestones.flatMap(\.unlocks)
        let set = ContributionPerks.modifiers(for: everything)
        XCTAssertLessThanOrEqual(set.payoutMultiplier, 1.10,
                                 "personal rungs inflate payouts too far")
        XCTAssertLessThanOrEqual(set.daylightDelta, 10,
                                 "personal rungs add too much daylight")
        XCTAssertEqual(set.crackMultiplier, 1, "a contribution rung must not change cracking")
    }

    func testTheVaultOpensEitherWay() {
        XCTAssertEqual(ContributionPerks.pools(for: ["charmpool:vault"]), [.shop, .vault])
        XCTAssertEqual(ContributionPerks.pools(for: ["charmpool:outfit"]), [.shop, .vault])
        XCTAssertEqual(ContributionPerks.pools(for: []), [.shop])
    }

    func testNewlyReachedSpansTheGap() {
        let ladder = [
            ContributionMilestone(id: "a", amount: 100, name: "A", cosmetics: ["x"]),
            ContributionMilestone(id: "b", amount: 200, name: "B", cosmetics: ["y"]),
            ContributionMilestone(id: "c", amount: 300, name: "C", cosmetics: ["z"]),
        ]
        XCTAssertEqual(
            ContributionPerks.newlyReached(ladder, previous: 50, current: 250).map(\.id),
            ["a", "b"]
        )
        XCTAssertTrue(ContributionPerks.newlyReached(ladder, previous: 250, current: 260).isEmpty)
        XCTAssertEqual(
            ContributionPerks.newlyReached(ladder, previous: 0, current: 300).map(\.id),
            ["a", "b", "c"]
        )
    }
}

final class OutfitMembershipTests: XCTestCase {

    func testOutfitPerksReachTheModifierPath() {
        var meta = MetaProgress()
        meta.outfit = OutfitMembership(
            id: "1", name: "The Blue Lias Irregulars", paidTotal: 300_000, memberCount: 4,
            reachedUnlocks: ["perk:outfit_payout_1_02"]
        )
        XCTAssertEqual(meta.contributionPerks().payoutMultiplier, 1.02, accuracy: 0.0001)
    }

    func testAnOutfitCanOpenTheVaultForItsMembers() {
        var meta = MetaProgress()
        meta.outfit = OutfitMembership(
            id: "1", name: "x", reachedUnlocks: ["charmpool:outfit"]
        )
        XCTAssertTrue(meta.contributionPools().contains(.vault))
    }

    func testNoOutfitMeansNoOutfitPerks() {
        let meta = MetaProgress()
        XCTAssertNil(meta.outfit)
        XCTAssertEqual(meta.contributionPerks(), ModifierSet())
    }

    func testMembershipRoundTripsThroughJSON() throws {
        var meta = MetaProgress()
        meta.outfit = OutfitMembership(
            id: "7", name: "The Flint Seam Company", paidTotal: 12_345, memberCount: 3,
            reachedUnlocks: ["stamp:outfit_badge"], joinCode: "QW4K7M"
        )
        let data = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(MetaProgress.self, from: data), meta)
    }
}
