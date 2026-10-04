import XCTest
@testable import BonedustCore

/// Permanent progression, and the thing it replaced.
final class UpgradeTests: XCTestCase {

    private func meta(reputation: Int) -> MetaProgress {
        var m = MetaProgress()
        m.reputation = reputation
        return m
    }

    func testKitDoesNotCarryBetweenRuns() {
        var m = MetaProgress()
        var run = RunState(seed: 1, siteID: "charmouth")
        run.toolIDs = ["brush", "air_blower"]
        run.charmIDs = ["steady_hands"]
        for day in 1...run.totalDays {
            run.completeSlab(SlabRecord(
                day: day, seed: UInt64(day), siteID: "charmouth", fossilID: "ammonite",
                payout: PayoutBreakdown(
                    exposure: 1, intact: 1, fossil: 400, gems: 0, bonuses: 0,
                    multiplier: 1, rushApplied: false, total: 400
                ),
                durationMillis: 40_000, bagged: true, wholeGems: 0, daylightLeft: 10
            ))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        m.absorb(run)

        XCTAssertEqual(
            m.carriedToolIDs, [BrushTool.brush.id],
            "a tool bought in week one was still working in week nine, which is why the "
                + "supply tent stopped being worth visiting"
        )
        XCTAssertTrue(m.carriedCharmIDs.isEmpty)
        XCTAssertGreaterThan(m.reputation, 0, "progression has to live somewhere")
    }

    func testBuyingAnUpgradeSpendsReputation() throws {
        var m = meta(reputation: 200)
        let upgrade = try XCTUnwrap(ContentCatalog.shared.upgrade("steady_grip"))
        try m.buy(upgrade: upgrade.id)
        XCTAssertEqual(m.reputation, 200 - upgrade.reputation)
        XCTAssertEqual(m.ownedUpgradeIDs, [upgrade.id])
    }

    /// Spent, not merely required. A threshold would hand over every upgrade at once the
    /// moment the number was high enough, which is a notification rather than a decision.
    func testAnUpgradeCannotBeBoughtTwiceOrWithoutTheReputation() throws {
        var m = meta(reputation: 120)
        try m.buy(upgrade: "steady_grip")
        XCTAssertThrowsError(try m.buy(upgrade: "steady_grip")) { error in
            XCTAssertEqual(error as? MetaProgress.UpgradeFailure, .alreadyOwned)
        }
        XCTAssertThrowsError(try m.buy(upgrade: "good_light")) { error in
            guard case .tooExpensive = error as? MetaProgress.UpgradeFailure else {
                return XCTFail("expected tooExpensive, got \(error)")
            }
        }
    }

    func testOwnedUpgradesComposeIntoTheRunsModifiers() throws {
        var m = meta(reputation: 1_000)
        try m.buy(upgrade: "steady_grip")
        try m.buy(upgrade: "soft_bristles")
        let mods = m.upgradeModifiers()
        XCTAssertGreaterThan(mods.safeSpeedMultiplier, 1)
        XCTAssertLessThan(mods.crackMultiplier, 1)
    }

    func testOrderOfPurchaseDoesNotMatter() throws {
        var a = meta(reputation: 1_000)
        try a.buy(upgrade: "steady_grip")
        try a.buy(upgrade: "practised_eye")
        var b = meta(reputation: 1_000)
        try b.buy(upgrade: "practised_eye")
        try b.buy(upgrade: "steady_grip")
        XCTAssertEqual(a.upgradeModifiers(), b.upgradeModifiers())
    }

    func testAnUpgradeCanLengthenEveryWeek() throws {
        var m = meta(reputation: 1_000)
        XCTAssertEqual(m.upgradeExtraDays(), 0)
        try m.buy(upgrade: "wheelers_patience")
        XCTAssertEqual(m.upgradeExtraDays(), 1)
    }

    /// Reputation survives a failed week, which tools never did. That is the whole reason
    /// progression moved here.
    func testUpgradesSurviveAFailedRun() throws {
        var m = meta(reputation: 1_000)
        try m.buy(upgrade: "steady_grip")
        var run = RunState(seed: 1, siteID: "charmouth")
        run.abandon()
        m.absorb(run)
        XCTAssertEqual(m.ownedUpgradeIDs, ["steady_grip"])
    }

    func testASaveWrittenBeforeUpgradesStillLoads() throws {
        var m = MetaProgress()
        m.reputation = 50
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(m)
        ) as! [String: Any]
        XCTAssertNotNil(json.removeValue(forKey: "ownedUpgradeIDsRaw"))
        let restored = try JSONDecoder().decode(
            MetaProgress.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(restored.ownedUpgradeIDs, [])
        XCTAssertEqual(restored.reputation, 50)
    }

    /// The whole ladder bought at once must not rewrite the difficulty curve, for the same
    /// reason the contribution rungs are capped: a reward that makes money easier compounds.
    func testTheWholeLadderIsSmallEnoughNotToRebalanceTheGame() {
        var m = MetaProgress()
        m.ownedUpgradeIDs = ContentCatalog.shared.upgrades.map(\.id)
        let mods = m.upgradeModifiers()
        XCTAssertLessThanOrEqual(mods.payoutMultiplier, 1.15)
        XCTAssertLessThanOrEqual(mods.daylightDelta, 10)
        XCTAssertLessThanOrEqual(mods.safeSpeedMultiplier, 1.25)
        XCTAssertGreaterThanOrEqual(mods.crackMultiplier, 0.8, "care must still matter")
    }
}
