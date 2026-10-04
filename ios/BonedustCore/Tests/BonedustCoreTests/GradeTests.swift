import XCTest
@testable import BonedustCore

/// The finished-slab grade, and the thing it nearly broke.
final class GradeTests: XCTestCase {

    private func grade(
        exposure: Float, intact: Float, daylightLeft: Float, total: Float = 60
    ) -> SlabGrade {
        SlabGrade.of(
            exposure: exposure, intact: intact,
            daylightRemaining: daylightLeft, totalDaylight: total
        )
    }

    func testAPerfectFastDigIsAnS() {
        XCTAssertEqual(grade(exposure: 1, intact: 1, daylightLeft: 60).letter, .s)
    }

    func testAnUntouchedSlabIsADHoweverFastItWasAbandoned() {
        // Without the exposure guard, bagging immediately banks the whole speed weight
        // for having done nothing at all.
        let bailed = grade(exposure: 0, intact: 1, daylightLeft: 60)
        XCTAssertEqual(bailed.letter, .d)
        XCTAssertEqual(bailed.score, 0)
        XCTAssertEqual(bailed.bonusMultiplier, 1, "a D should add nothing")
    }

    func testCareOutweighsSpeed() {
        // Same slab dug two ways: carefully and slowly, or fast and broken.
        let careful = grade(exposure: 0.95, intact: 1, daylightLeft: 2)
        let hurried = grade(exposure: 0.95, intact: 0.5, daylightLeft: 40)
        XCTAssertGreaterThan(
            careful.score, hurried.score,
            "a grade that pays for speed over care argues against the whole game"
        )
    }

    /// A night dig starts with less daylight and has not been dug any worse for it.
    func testANightDigIsNotMarkedDownForItsShorterDay() {
        let day = grade(exposure: 0.9, intact: 0.9, daylightLeft: 20, total: 60)
        let night = grade(exposure: 0.9, intact: 0.9, daylightLeft: 10, total: 30)
        XCTAssertEqual(day.score, night.score, accuracy: 0.0001)
        XCTAssertEqual(day.letter, night.letter)
    }

    func testTheGradeIsPaidOnFossilAndGemMoneyOnly() {
        func payout(daylightLeft: Float) -> PayoutBreakdown {
            Payout.evaluate(PayoutContext(
                baseValue: 400, exposure: 1, boneCells: 100, crackedCells: 0,
                wholeGems: 0, daylightRemaining: daylightLeft, totalDaylight: 60
            ))
        }
        let perfect = payout(daylightLeft: 60)
        let slow = payout(daylightLeft: 0)
        XCTAssertEqual(perfect.grade, .s)
        XCTAssertGreaterThan(perfect.gradeBonus, 0)
        XCTAssertGreaterThan(perfect.total, slow.total)
        XCTAssertEqual(
            perfect.total - slow.total, perfect.gradeBonus - slow.gradeBonus,
            "the only difference between these two slabs should be the grade"
        )
    }

    /// The regression this feature nearly shipped.
    ///
    /// `ServerCeiling` is a separate implementation from `Payout.maxPayout` — it is written
    /// in `Double` so Ruby can reach the same integer — so adding a bonus to the payout
    /// formula does not raise it. For one commit a slab cleared, unbroken and bagged early
    /// could out-earn the ceiling by 25% and be rejected as a forgery, at exactly the moment
    /// the dig had gone perfectly.
    func testNoGradeCanOutEarnTheServerCeiling() {
        let catalog = ContentCatalog.shared
        for siteID in ["charmouth", "green_river", "hell_creek", "night_dig"] {
            guard let site = catalog.site(siteID) else { continue }
            for seed in UInt64(0)..<25 {
                let (_, layout) = SlabGenerator.generate(seed: seed, site: site)
                guard let fossil = catalog.fossil(layout.fossilID) else { continue }

                let best = Payout.evaluate(PayoutContext(
                    baseValue: fossil.baseValue,
                    instances: layout.instances,
                    exposure: 1,
                    boneCells: max(1, layout.boneCells),
                    crackedCells: 0,
                    wholeGems: layout.gemCount,
                    daylightRemaining: SimTuning.standard.daylightSeconds,
                    totalDaylight: SimTuning.standard.daylightSeconds,
                    modifiers: site.modifiers.modifierSet
                ))
                XCTAssertEqual(best.grade, SlabGrade.Letter.s, "a flawless dig should grade S")

                let ceiling = ServerCeiling.ceiling(
                    fossil: fossil, instances: layout.instances,
                    site: site, claimedCharms: [], catalog: catalog
                )
                XCTAssertLessThanOrEqual(
                    best.total, ceiling,
                    "\(siteID) seed \(seed): a perfect slab pays $\(best.total) against a "
                        + "$\(ceiling) ceiling, so the server would call it a forgery"
                )
            }
        }
    }
}
