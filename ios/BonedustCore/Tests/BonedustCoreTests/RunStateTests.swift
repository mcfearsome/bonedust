import Foundation
import XCTest
@testable import BonedustCore

final class RunStateTests: XCTestCase {

    private func record(day: Int, total: Int, seed: UInt64 = 1) -> SlabRecord {
        SlabRecord(
            day: day, seed: seed, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                exposure: 0.8, intact: 1, fossil: total, gems: 0, bonuses: 0,
                multiplier: 1, rushApplied: false, total: total
            ),
            durationMillis: 42_000, bagged: true, wholeGems: 0, daylightLeft: 12
        )
    }

    /// Plays a whole run, paying `perSlab` each day.
    private func play(perSlab: Int, tier: Int = 1) -> RunState {
        var run = RunState(seed: 7, siteID: "charmouth", tier: tier)
        for day in 1...run.totalDays {
            run.completeSlab(record(day: day, total: perSlab))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        return run
    }

    func testFreshRunStartsOnDayOneAtTierOne() {
        let run = RunState(seed: 1, siteID: "charmouth")
        XCTAssertEqual(run.phase, .digging(day: 1))
        XCTAssertEqual(run.installment, Installments.amount(tier: 1))
        XCTAssertEqual(run.totalDays, 5)
        XCTAssertEqual(run.cash, 0)
        XCTAssertEqual(run.toolIDs, [BrushTool.brush.id], "you start with the plain brush")
        XCTAssertTrue(run.charmIDs.isEmpty)
        XCTAssertFalse(run.isOver)
    }

    func testInstallmentFollowsTheTier() {
        XCTAssertEqual(RunState(seed: 1, siteID: "charmouth", tier: 3).installment,
                       Installments.amount(tier: 3))
        XCTAssertEqual(RunState(seed: 1, siteID: "charmouth", tier: 5).installment,
                       Installments.amount(tier: 5))
    }

    func testCompletingASlabBanksCashAndShowsResults() {
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 120))
        XCTAssertEqual(run.cash, 120)
        XCTAssertEqual(run.phase, .results(day: 1))
        XCTAssertEqual(run.slabs.count, 1)
    }

    func testAdvanceGoesToTheTentThenTheNextDay() {
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 50))
        run.advance()
        XCTAssertEqual(run.phase, .supplyTent(day: 1))
        run.leaveShop()
        XCTAssertEqual(run.phase, .digging(day: 2))
    }

    func testThereIsNoTentAfterTheLastSlab() {
        // The installment falls due the moment the last slab is bagged. Shopping first
        // would just be a way to convert cash you owe into tools you are about to lose.
        var run = RunState(seed: 1, siteID: "charmouth")
        let owed = Installments.amount(tier: 1)
        let perSlab = owed / 5 + 30
        for day in 1...5 {
            run.completeSlab(record(day: day, total: perSlab))
            run.advance()
            if day < 5 {
                XCTAssertEqual(run.phase, .supplyTent(day: day))
                run.leaveShop()
            }
        }
        let leftover = perSlab * 5 - owed
        XCTAssertEqual(run.phase, .succeeded(
            reputationEarned: Installments.reputation(fromLeftoverCash: leftover, tier: 1),
            leftover: leftover
        ))
    }

    func testARunThatPaysTheInstallmentSucceeds() {
        // Comfortably over whatever tier one asks for.
        let owed = Installments.amount(tier: 1)
        let perSlab = owed / 5 + 30
        let run = play(perSlab: perSlab)
        let leftover = perSlab * 5 - owed
        XCTAssertEqual(run.phase, .succeeded(
            reputationEarned: Installments.reputation(fromLeftoverCash: leftover, tier: 1),
            leftover: leftover
        ))
        XCTAssertEqual(run.cash, 0, "all cash is consumed at settling")
        XCTAssertTrue(run.isOver)
    }

    func testARunThatFallsShortFails() {
        let owed = Installments.amount(tier: 1)
        let perSlab = (owed - 50) / 5
        let run = play(perSlab: perSlab)
        XCTAssertEqual(run.phase, .failed(shortfall: owed - perSlab * 5))
        XCTAssertTrue(run.isOver)
    }

    func testExactlyMakingTheInstallmentSucceedsWithNoReputation() {
        let owed = Installments.amount(tier: 1)
        XCTAssertEqual(owed % 5, 0, "the ramp should divide evenly over five days")
        let run = play(perSlab: owed / 5)
        XCTAssertEqual(run.phase, .succeeded(
            reputationEarned: Installments.reputation(fromLeftoverCash: 0, tier: 1),
            leftover: 0
        ),
                       "clearing the week earns Reputation even with nothing left over")
    }

    func testShortfallTracksProgressDuringTheRun() {
        var run = RunState(seed: 1, siteID: "charmouth")
        let owed = Installments.amount(tier: 1)
        XCTAssertEqual(run.shortfall, owed)
        let first = owed - 150
        run.completeSlab(record(day: 1, total: first))
        XCTAssertEqual(run.shortfall, 150)
        XCTAssertFalse(run.isInstallmentCovered)
        run.advance()
        run.leaveShop()
        run.completeSlab(record(day: 2, total: 150))
        XCTAssertEqual(run.shortfall, 0)
        XCTAssertTrue(run.isInstallmentCovered)
    }

    func testCoveringTheInstallmentEarlyStillPlaysFiveDays() {
        // The whole tension of the shop is that you keep digging after you are safe.
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 400))
        run.advance()
        XCTAssertEqual(run.phase, .supplyTent(day: 1))
        run.leaveShop()
        XCTAssertEqual(run.phase, .digging(day: 2))
        XCTAssertFalse(run.isOver)
    }

    func testSlabSeedsAreDerivedStablyAndDistinctly() {
        let run = RunState(seed: 0xABCD_EF01, siteID: "charmouth")
        let seeds = (1...run.totalDays).map(run.slabSeed(forDay:))
        XCTAssertEqual(Set(seeds).count, run.totalDays, "two days drew the same slab")
        // Stable across calls, so a restore lands on the same slabs.
        XCTAssertEqual(seeds, (1...run.totalDays).map(run.slabSeed(forDay:)))
        // And different runs get different slabs.
        let other = RunState(seed: 0xABCD_EF02, siteID: "charmouth")
        XCTAssertNotEqual(seeds, (1...other.totalDays).map(other.slabSeed(forDay:)))
    }

    func testOutOfOrderSlabsAreRejected() {
        // Guards against a results screen double-firing or a stale completion
        // arriving after a restore.
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(record(day: 3, total: 999))
        XCTAssertEqual(run.cash, 0)
        XCTAssertEqual(run.phase, .digging(day: 1))

        run.completeSlab(record(day: 1, total: 100))
        run.completeSlab(record(day: 1, total: 100))
        XCTAssertEqual(run.cash, 100, "the same slab paid twice")
        XCTAssertEqual(run.slabs.count, 1)
    }

    func testAdvanceDoesNothingOutsideResults() {
        var run = RunState(seed: 1, siteID: "charmouth")
        run.advance()
        XCTAssertEqual(run.phase, .digging(day: 1))
    }

    func testAbandonEndsTheRunAsAFailure() {
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 100))
        run.abandon()
        XCTAssertEqual(run.phase, .failed(shortfall: Installments.amount(tier: 1) - 100))
    }

    func testCrewContributionIsEverythingEarnedWhenNothingIsBought() {
        let run = play(perSlab: 100)
        XCTAssertEqual(run.crewContribution, 500)
        XCTAssertEqual(run.totalEarned, 500)
        XCTAssertEqual(run.spentOnKit, 0)
    }

    /// The rule: a dollar spent at the supply tent is a dollar the crew debt never sees.
    ///
    /// It used to count both ways -- every dollar earned paid the debt even if it
    /// immediately bought a pick -- which made "earned" and "paid to the debt" the same
    /// number by construction, and hid what the kit was costing.
    func testKitSpendingComesOutOfTheNextSlabPayment() throws {
        var run = RunState(seed: 7, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 400))
        XCTAssertEqual(run.crewContribution, 400, "nothing bought yet, so all of it")

        run.advance()
        guard case .supplyTent = run.phase else { return XCTFail("no tent after day one") }
        run.openShop(reputation: 500)
        let tool = try XCTUnwrap(ContentCatalog.shared.tool(run.shop.toolIDs.first ?? ""))
        try run.buyTool(tool.id)
        run.leaveShop()

        // The payment for day one has already gone. The pick comes out of day two.
        XCTAssertEqual(run.crewContribution, 400, "a purchase cannot claw back a sent payment")
        XCTAssertEqual(run.unsettledKit, tool.price)

        run.completeSlab(record(day: 2, total: 400))
        XCTAssertEqual(run.crewContribution, 800 - tool.price)
        XCTAssertEqual(run.totalEarned, 800)
        XCTAssertEqual(run.spentOnKit, tool.price)
    }

    func testSellingKitBackPutsItTowardTheDebtAgain() throws {
        var run = RunState(seed: 7, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 400))
        run.advance()
        run.openShop(reputation: 500)
        let tool = try XCTUnwrap(ContentCatalog.shared.tool(run.shop.toolIDs.first ?? ""))
        try run.buyTool(tool.id)
        run.sellTool(tool.id)
        // Half price back (§4), so the round trip still costs something.
        XCTAssertEqual(run.spentOnKit, tool.price - tool.resaleValue)
        XCTAssertEqual(run.unsettledKit, tool.price - tool.resaleValue)
    }

    /// Kit can be bought that no later payment is big enough to cover.
    ///
    /// `totalEarned - spentOnKit` would go negative and disagree with what the server was
    /// actually sent, which is why the contribution is summed as it is paid rather than
    /// derived at the end.
    func testKitTooExpensiveForTheRemainingDaysStrandsTheRest() throws {
        var run = RunState(seed: 7, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 400))
        run.advance()
        run.openShop(reputation: 500)
        let tool = try XCTUnwrap(ContentCatalog.shared.tool(run.shop.toolIDs.first ?? ""))
        try run.buyTool(tool.id)
        run.leaveShop()
        run.completeSlab(record(day: 2, total: 1))

        XCTAssertEqual(run.crewContribution, 400, "day two earned less than the pick cost")
        XCTAssertGreaterThan(run.unsettledKit, 0, "the remainder is still owed")
        XCTAssertGreaterThanOrEqual(run.crewContribution, 0)
    }

    /// A save written before any of this existed has to survive, because `RunStore` throws
    /// away anything `JSONDecoder` rejects — a new non-optional field is indistinguishable
    /// from a corrupt save and would silently wipe a run in progress.
    func testASaveWithoutTheNewFieldsStillDecodes() throws {
        var run = play(perSlab: 100)
        run.charmIDs = []
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(run)
        ) as! [String: Any]
        for key in ["spentOnKitRaw", "unsettledKitRaw", "paidToCrewRaw"] {
            XCTAssertNotNil(json.removeValue(forKey: key), "\(key) should have been written")
        }
        let older = try JSONSerialization.data(withJSONObject: json)

        let restored = try JSONDecoder().decode(RunState.self, from: older)
        XCTAssertEqual(restored.spentOnKit, 0)
        XCTAssertEqual(restored.unsettledKit, 0)
        XCTAssertEqual(restored.totalEarned, 500)
    }

    func testAnOlderMetaProgressReadsEarnedAsItsContribution() throws {
        var meta = MetaProgress()
        meta.lifetimeContribution = 12_345
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(meta)
        ) as! [String: Any]
        json.removeValue(forKey: "lifetimeEarnedRaw")
        json.removeValue(forKey: "lifetimeSpentOnKitRaw")

        let restored = try JSONDecoder().decode(
            MetaProgress.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        // Exact, not a guess: before kit spending was taken out, every dollar earned went
        // to the debt, so for those saves the two numbers were the same.
        XCTAssertEqual(restored.lifetimeEarned, 12_345)
        XCTAssertEqual(restored.lifetimeSpentOnKit, 0)
    }

    func testRunRoundTripsThroughJSON() throws {
        var run = play(perSlab: 90)
        run.charmIDs = ["authentic_damage"]
        let data = try JSONEncoder().encode(run)
        XCTAssertEqual(try JSONDecoder().decode(RunState.self, from: data), run)
    }
}

final class MetaProgressTests: XCTestCase {

    private func finishedRun(perSlab: Int, tier: Int) -> RunState {
        var run = RunState(seed: 3, siteID: "charmouth", tier: tier)
        for day in 1...run.totalDays {
            run.completeSlab(SlabRecord(
                day: day, seed: UInt64(day), siteID: "charmouth", fossilID: "ammonite",
                payout: PayoutBreakdown(
                    exposure: 1, intact: 1, fossil: perSlab, gems: 0, bonuses: 0,
                    multiplier: 1, rushApplied: false, total: perSlab
                ),
                durationMillis: 40_000, bagged: true, wholeGems: 0, daylightLeft: 10
            ))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        return run
    }

    func testSuccessRaisesTheTierAndTheStreak() {
        var meta = MetaProgress()
        meta.absorb(finishedRun(perSlab: 120, tier: 1))
        XCTAssertEqual(meta.runsCompleted, 1)
        XCTAssertEqual(meta.nextTier, 2)
        XCTAssertEqual(meta.nextInstallment, Installments.amount(tier: 2))
        XCTAssertEqual(meta.currentStreak, 1)
        XCTAssertEqual(meta.longestStreak, 1)
        let owed = Installments.amount(tier: 1)
        XCTAssertEqual(
            meta.reputation,
            Installments.reputation(fromLeftoverCash: 600 - owed, tier: 1),
            "600 earned, \(owed) paid, \(600 - owed) over, plus the flat tier award"
        )
        XCTAssertEqual(meta.lifetimeContribution, 600)
        XCTAssertEqual(meta.bestSlabPayout, 120)
    }

    func testFailureResetsTheTierButKeepsReputation() {
        var meta = MetaProgress()
        meta.absorb(finishedRun(perSlab: 200, tier: 1))   // succeeds
        meta.absorb(finishedRun(perSlab: 200, tier: 2))   // succeeds
        let earned = meta.reputation
        XCTAssertEqual(meta.nextTier, 3)
        XCTAssertEqual(meta.longestStreak, 2)

        meta.absorb(finishedRun(perSlab: 10, tier: 3))    // fails
        XCTAssertEqual(meta.nextTier, 1, "the Collector took the tools")
        XCTAssertEqual(meta.carriedToolIDs, [BrushTool.brush.id], "and they are gone")
        XCTAssertTrue(meta.carriedCharmIDs.isEmpty)
        XCTAssertEqual(meta.currentStreak, 0)
        XCTAssertEqual(meta.longestStreak, 2, "the record stands")
        XCTAssertEqual(meta.reputation, earned, "Reputation survives a failed run")
        XCTAssertEqual(meta.runsFailed, 1)
    }

    func testFailedRunsStillPayTheCrewDebt() {
        var meta = MetaProgress()
        meta.absorb(finishedRun(perSlab: 10, tier: 1))
        XCTAssertEqual(meta.lifetimeContribution, 50)
        XCTAssertEqual(meta.runsCompleted, 0)
    }

    func testAnUnfinishedRunChangesNoTier() {
        var meta = MetaProgress()
        var run = RunState(seed: 1, siteID: "charmouth")
        run.completeSlab(SlabRecord(
            day: 1, seed: 1, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                exposure: 1, intact: 1, fossil: 100, gems: 0, bonuses: 0,
                multiplier: 1, rushApplied: false, total: 100
            ),
            durationMillis: 1_000, bagged: true, wholeGems: 0, daylightLeft: 0
        ))
        meta.absorb(run)
        XCTAssertEqual(meta.nextTier, 1)
        XCTAssertEqual(meta.runsCompleted, 0)
        XCTAssertEqual(meta.runsFailed, 0)
        XCTAssertEqual(meta.lifetimeContribution, 100, "the dollars still count")
    }

    func testMetaRoundTripsThroughJSON() throws {
        var meta = MetaProgress()
        meta.absorb(finishedRun(perSlab: 300, tier: 4))
        let data = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(MetaProgress.self, from: data), meta)
    }
}
