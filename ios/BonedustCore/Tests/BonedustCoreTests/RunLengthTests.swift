import XCTest
@testable import BonedustCore

/// Week length, and earning another day.
final class RunLengthTests: XCTestCase {

    private func record(day: Int, total: Int, exposure: Float, daylightLeft: Float)
        -> SlabRecord
    {
        let payout = Payout.evaluate(PayoutContext(
            baseValue: total, exposure: exposure, boneCells: 100, crackedCells: 0,
            wholeGems: 0, daylightRemaining: daylightLeft, totalDaylight: 60
        ))
        return SlabRecord(
            day: day, seed: UInt64(day), siteID: "charmouth", fossilID: "ammonite",
            payout: payout, durationMillis: 40_000, bagged: true, wholeGems: 0,
            daylightLeft: daylightLeft
        )
    }

    func testAFirstRunIsStillFiveDays() {
        XCTAssertEqual(RunLength.days(tier: 1), 5)
        XCTAssertEqual(RunState(seed: 1, siteID: "charmouth").totalDays, 5)
    }

    func testWeeksGetLongerWithTheTier() {
        XCTAssertGreaterThan(RunLength.days(tier: 5), RunLength.days(tier: 1))
        var previous = 0
        for tier in 1...60 {
            let days = RunLength.days(tier: tier)
            XCTAssertGreaterThanOrEqual(days, previous, "length should never go backwards")
            XCTAssertLessThanOrEqual(days, RunLength.maximumDays)
            previous = days
        }
        XCTAssertEqual(RunLength.days(tier: 500), RunLength.maximumDays, "capped")
    }

    func testAnSGradeSlabBuysADay() {
        var run = RunState(seed: 7, siteID: "charmouth")
        let before = run.totalDays
        // Cleared, unbroken, finished with daylight to spare.
        let slab = record(day: 1, total: 100, exposure: 1, daylightLeft: 60)
        XCTAssertEqual(slab.payout.grade, SlabGrade.Letter.s)
        let payment = run.completeSlab(slab)
        // The whole payout, grade bonus included -- nothing was bought yet.
        XCTAssertEqual(payment, slab.payout.total)
        XCTAssertGreaterThan(slab.payout.gradeBonus, 0)
        XCTAssertTrue(run.lastSlabEarnedADay)
        XCTAssertEqual(run.totalDays, before + 1)
        XCTAssertEqual(run.earnedDays, 1)
    }

    func testAnOrdinarySlabBuysNothing() {
        var run = RunState(seed: 7, siteID: "charmouth")
        let before = run.totalDays
        // Fully exposed but with the clock run out: a B, which is the ordinary case.
        run.completeSlab(record(day: 1, total: 100, exposure: 1, daylightLeft: 0))
        XCTAssertFalse(run.lastSlabEarnedADay)
        XCTAssertEqual(run.totalDays, before, "a reward most slabs earn is inflation")
    }

    /// Without a cap an extra day is pure profit, so a good enough player extends forever
    /// and the installment stops being a deadline.
    func testEarnedDaysAreCapped() {
        var run = RunState(seed: 7, siteID: "charmouth")
        let before = run.totalDays
        for day in 1...8 {
            run.completeSlab(record(day: day, total: 100, exposure: 1, daylightLeft: 60))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        XCTAssertEqual(run.earnedDays, RunLength.maximumEarnedDays)
        XCTAssertEqual(run.totalDays, before + RunLength.maximumEarnedDays)
    }

    func testEarnedDaysSurviveASave() throws {
        var run = RunState(seed: 7, siteID: "charmouth")
        run.completeSlab(record(day: 1, total: 100, exposure: 1, daylightLeft: 60))
        let restored = try JSONDecoder().decode(
            RunState.self, from: try JSONEncoder().encode(run)
        )
        XCTAssertEqual(restored.earnedDays, 1)
        XCTAssertEqual(restored.totalDays, run.totalDays)
    }

    func testASaveWrittenBeforeEarnedDaysStillLoads() throws {
        let run = RunState(seed: 7, siteID: "charmouth")
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(run)
        ) as! [String: Any]
        XCTAssertNotNil(json.removeValue(forKey: "earnedDaysRaw"))
        let restored = try JSONDecoder().decode(
            RunState.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(restored.earnedDays, 0)
        XCTAssertEqual(restored.totalDays, 5)
    }
}
