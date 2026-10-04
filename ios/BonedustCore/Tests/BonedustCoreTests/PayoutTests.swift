import XCTest
@testable import BonedustCore

final class PayoutTests: XCTestCase {

    private func context(
        base: Int = 100, exposure: Float = 1, bone: Int = 100, cracked: Int = 0,
        gems: Int = 0, nodules: Int = 0, daylight: Float = 0,
        modifiers: ModifierSet = ModifierSet()
    ) -> PayoutContext {
        PayoutContext(
            baseValue: base, exposure: exposure, boneCells: bone, crackedCells: cracked,
            wholeGems: gems, clearedNodules: nodules, daylightRemaining: daylight,
            modifiers: modifiers
        )
    }

    func testPerfectSlabPaysBase() {
        XCTAssertEqual(Payout.evaluate(context()).total, 100)
    }

    func testExposureIsRaisedToThreeHalves() {
        // round(100 * 0.5^1.5 * 1) = round(35.355) = 35
        XCTAssertEqual(Payout.evaluate(context(exposure: 0.5)).fossil, 35)
        // round(100 * 0.25^1.5) = round(12.5) = 13
        XCTAssertEqual(Payout.evaluate(context(exposure: 0.25)).fossil, 13)
        XCTAssertEqual(Payout.evaluate(context(exposure: 0)).fossil, 0)
    }

    func testPartialExposureIsPunishedHarderThanLinear() {
        // The 1.5 exponent is what makes "finish the fossil" worth the daylight.
        let half = Payout.evaluate(context(exposure: 0.5)).fossil
        let full = Payout.evaluate(context(exposure: 1.0)).fossil
        XCTAssertLessThan(Float(half), Float(full) * 0.5)
    }

    func testCracksReduceValue() {
        XCTAssertEqual(Payout.evaluate(context(cracked: 0)).fossil, 100)
        XCTAssertEqual(Payout.evaluate(context(cracked: 10)).fossil, 50)
        XCTAssertEqual(Payout.evaluate(context(cracked: 20)).fossil, 0)
    }

    func testGemsPayTwentyEach() {
        XCTAssertEqual(Payout.evaluate(context(gems: 2)).gems, 40)
        XCTAssertEqual(Payout.evaluate(context(gems: 0)).gems, 0)
    }

    func testSievePaysDoubleForGems() {
        var mods = ModifierSet()
        mods.gemMultiplier = 2
        XCTAssertEqual(Payout.evaluate(context(gems: 2, modifiers: mods)).gems, 80)
    }

    func testAuthenticDamageHalvesTheCostOfCracks() {
        var mods = ModifierSet()
        mods.crackedIntactCredit = 0.5
        let plain = Payout.evaluate(context(cracked: 16)).fossil
        let charmed = Payout.evaluate(context(cracked: 16, modifiers: mods)).fossil
        XCTAssertEqual(plain, 20)
        XCTAssertEqual(charmed, 60)
    }

    func testIntactCreditCannotExceedOne() {
        var mods = ModifierSet()
        var another = ModifierSet()
        mods.crackedIntactCredit = 0.5
        another.crackedIntactCredit = 0.8
        mods.combine(another)
        XCTAssertEqual(mods.crackedIntactCredit, 1)
        // Fully-cracked bone is then merely worthless, never worth more than intact.
        XCTAssertEqual(Payout.evaluate(context(cracked: 100, modifiers: mods)).fossil, 100)
    }

    func testRushJobNeedsEnoughDaylight() {
        var mods = ModifierSet()
        mods.rushMultiplier = 1.4
        mods.rushThreshold = 20
        XCTAssertFalse(Payout.evaluate(context(daylight: 19, modifiers: mods)).rushApplied)
        XCTAssertEqual(Payout.evaluate(context(daylight: 19, modifiers: mods)).total, 100)
        let rushed = Payout.evaluate(context(daylight: 20, modifiers: mods))
        XCTAssertTrue(rushed.rushApplied)
        XCTAssertEqual(rushed.total, 140)
    }

    func testRockHoundIsAFlatBonusAfterMultipliers() {
        var mods = ModifierSet()
        mods.rockNodulePayout = 8
        mods.payoutMultiplier = 1.5
        let result = Payout.evaluate(context(nodules: 3, modifiers: mods))
        XCTAssertEqual(result.bonuses, 24)
        XCTAssertEqual(result.total, 150 + 24, "flat money must not be multiplied")
    }

    func testModifiersAreOrderIndependent() {
        // The §4 requirement that charms stack without caring about order. Build a
        // bag of charm-shaped modifiers, then total the payout for many shuffles.
        func charm(_ configure: (inout ModifierSet) -> Void) -> ModifierSet {
            var set = ModifierSet()
            configure(&set)
            return set
        }
        let charms: [ModifierSet] = [
            charm { $0.payoutMultiplier = 1.5 },            // night dig
            charm { $0.payoutMultiplier = 0.9 },            // night owl
            charm { $0.gemMultiplier = 2 },                 // sieve
            charm { $0.crackedIntactCredit = 0.5 },         // authentic damage
            charm { $0.rockNodulePayout = 8 },              // rock hound
            charm { $0.payoutMultiplier = 1.08 },           // compound interest, 4 charms
            charm { $0.rushMultiplier = 1.4; $0.rushThreshold = 20 },
            charm { $0.identifyExposure = 0.10 },           // collector's eye
        ]
        var rng = SplitMix64(seed: 1234)
        var totals = Set<Int>()
        for _ in 0..<200 {
            var shuffled = charms
            // Fisher-Yates with the seeded PRNG, so a failure reproduces.
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                shuffled.swapAt(i, rng.nextInt(below: i + 1))
            }
            let combined = ModifierSet.combining(shuffled)
            totals.insert(Payout.evaluate(context(
                base: 170, exposure: 0.82, bone: 420, cracked: 37,
                gems: 2, nodules: 3, daylight: 24, modifiers: combined
            )).total)
        }
        XCTAssertEqual(totals.count, 1, "payout depended on charm order: \(totals.sorted())")
    }

    func testMaxPayoutIsAnUpperBound() {
        // The server rejects anything above this, so no legitimate dig may exceed it.
        var mods = ModifierSet()
        mods.payoutMultiplier = 1.5
        mods.gemMultiplier = 2
        mods.rushMultiplier = 1.4
        let ceiling = Payout.maxPayout(baseValue: 260, gemCount: 2, modifiers: mods)
        var rng = SplitMix64(seed: 90)
        for _ in 0..<5_000 {
            let actual = Payout.evaluate(PayoutContext(
                baseValue: 260,
                exposure: rng.nextUnit(),
                boneCells: 500,
                crackedCells: rng.nextInt(below: 500),
                wholeGems: rng.nextInt(below: 3),
                clearedNodules: 0,
                daylightRemaining: rng.nextFloat(0, 60),
                modifiers: mods
            )).total
            XCTAssertLessThanOrEqual(actual, ceiling)
        }
    }

    func testTotalIsNeverNegative() {
        var mods = ModifierSet()
        mods.payoutMultiplier = 0
        XCTAssertEqual(Payout.evaluate(context(modifiers: mods)).total, 0)
    }

    /// The *shape* of the ramp, not the numbers in it.
    ///
    /// Those numbers are fitted against the economy sweep and have moved twice; writing
    /// them here again meant a deliberate rebalance failed eleven tests that had no opinion
    /// about balance, which buries the one failure that might have mattered.
    func testInstallmentCurve() {
        for (index, expected) in Installments.table.enumerated() {
            XCTAssertEqual(Installments.amount(tier: index + 1), expected)
        }
        XCTAssertEqual(
            Installments.amount(tier: 0), Installments.table[0], "tier is clamped at 1"
        )
        // Keeps rising, in $25 steps, forever.
        var previous = 0
        for tier in 1...40 {
            let amount = Installments.amount(tier: tier)
            XCTAssertGreaterThan(amount, previous)
            XCTAssertEqual(amount % 25, 0)
            previous = amount
        }
    }

    func testReputationConversion() {
        // 10:1 on leftover cash, plus a flat 15 per tier for clearing the week at all.
        // Without the flat part the site gates were unreachable; see DECISIONS.md.
        XCTAssertEqual(Installments.reputation(fromLeftoverCash: 1_000, tier: 1), 115)
        XCTAssertEqual(Installments.reputation(fromLeftoverCash: 0, tier: 1), 15)
        XCTAssertEqual(Installments.reputation(fromLeftoverCash: -50, tier: 1), 15)
        XCTAssertEqual(Installments.reputation(fromLeftoverCash: 0, tier: 4), 60,
                       "surviving a harder week is what opens the map")
    }
}
