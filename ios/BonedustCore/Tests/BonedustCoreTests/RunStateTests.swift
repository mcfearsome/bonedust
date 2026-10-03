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
        XCTAssertEqual(run.installment, 350)
        XCTAssertEqual(run.totalDays, 5)
        XCTAssertEqual(run.cash, 0)
        XCTAssertEqual(run.toolIDs, [BrushTool.brush.id], "you start with the plain brush")
        XCTAssertTrue(run.charmIDs.isEmpty)
        XCTAssertFalse(run.isOver)
    }

    func testInstallmentFollowsTheTier() {
        XCTAssertEqual(RunState(seed: 1, siteID: "charmouth", tier: 3).installment, 575)
        XCTAssertEqual(RunState(seed: 1, siteID: "charmouth", tier: 5).installment, 900)
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
        for day in 1...5 {
            run.completeSlab(record(day: day, total: 100))
            run.advance()
            if day < 5 {
                XCTAssertEqual(run.phase, .supplyTent(day: day))
                run.leaveShop()
            }
        }
        XCTAssertEqual(run.phase, .succeeded(reputationEarned: 30, leftover: 150))
    }

    func testARunThatPaysTheInstallmentSucceeds() {
        let run = play(perSlab: 100)   // 500 against 350
        XCTAssertEqual(run.phase, .succeeded(reputationEarned: 30, leftover: 150))
        XCTAssertEqual(run.cash, 0, "all cash is consumed at settling")
        XCTAssertTrue(run.isOver)
    }

    func testARunThatFallsShortFails() {
        let run = play(perSlab: 60)    // 300 against 350
        XCTAssertEqual(run.phase, .failed(shortfall: 50))
        XCTAssertTrue(run.isOver)
    }

    func testExactlyMakingTheInstallmentSucceedsWithNoReputation() {
        let run = play(perSlab: 70)    // 350 against 350
        XCTAssertEqual(run.phase, .succeeded(reputationEarned: 15, leftover: 0),
                       "clearing the week earns Reputation even with nothing left over")
    }

    func testShortfallTracksProgressDuringTheRun() {
        var run = RunState(seed: 1, siteID: "charmouth")
        XCTAssertEqual(run.shortfall, 350)
        run.completeSlab(record(day: 1, total: 200))
        XCTAssertEqual(run.shortfall, 150)
        XCTAssertFalse(run.isInstallmentCovered)
        run.advance()
        run.leaveShop()
        run.completeSlab(record(day: 2, total: 200))
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
        XCTAssertEqual(run.phase, .failed(shortfall: 250))
    }

    func testCrewContributionCountsEveryDollarEarned() {
        // Including the dollars that went straight to the Collector.
        let run = play(perSlab: 100)
        XCTAssertEqual(run.crewContribution, 500)
        XCTAssertEqual(run.totalEarned, 500)
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
        XCTAssertEqual(meta.nextInstallment, 450)
        XCTAssertEqual(meta.currentStreak, 1)
        XCTAssertEqual(meta.longestStreak, 1)
        XCTAssertEqual(meta.reputation, 40, "600 earned, 350 paid, 250 over, plus 15 flat")
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
