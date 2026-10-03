import XCTest
@testable import BonedustCore

final class ShopTests: XCTestCase {

    private func shopping(cash: Int = 500, day: Int = 1) -> RunState {
        var run = RunState(seed: 0xB0_0B5, siteID: "charmouth")
        run.completeSlab(SlabRecord(
            day: day, seed: 1, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                exposure: 1, intact: 1, fossil: cash, gems: 0, bonuses: 0,
                multiplier: 1, rushApplied: false, total: cash
            ),
            durationMillis: 1_000, bagged: true, wholeGems: 0, daylightLeft: 0
        ))
        run.advance()
        run.openShop(reputation: 0)
        return run
    }

    func testStockIsThreeToolsAndThreeCharms() {
        let run = shopping()
        XCTAssertEqual(run.shop.toolIDs.count, Shop.toolsOffered)
        XCTAssertEqual(run.shop.charmIDs.count, Shop.charmsOffered)
    }

    func testStockNeverRepeatsAnItem() {
        let run = shopping()
        XCTAssertEqual(Set(run.shop.toolIDs).count, run.shop.toolIDs.count)
        XCTAssertEqual(Set(run.shop.charmIDs).count, run.shop.charmIDs.count)
    }

    func testStockIsDeterministicForTheSameVisit() {
        // The stock is saved, so a relaunch must not be a free reroll.
        let a = Shop.stock(
            runSeed: 42, day: 2, restocks: 0,
            ownedToolIDs: ["brush"], ownedCharmIDs: [], reputation: 0
        )
        let b = Shop.stock(
            runSeed: 42, day: 2, restocks: 0,
            ownedToolIDs: ["brush"], ownedCharmIDs: [], reputation: 0
        )
        XCTAssertEqual(a, b)
    }

    func testDifferentDaysAndRestocksOfferDifferentThings() {
        let day2 = Shop.stock(runSeed: 42, day: 2, restocks: 0,
                              ownedToolIDs: [], ownedCharmIDs: [], reputation: 0)
        let day3 = Shop.stock(runSeed: 42, day: 3, restocks: 0,
                              ownedToolIDs: [], ownedCharmIDs: [], reputation: 0)
        let rerolled = Shop.stock(runSeed: 42, day: 2, restocks: 1,
                                  ownedToolIDs: [], ownedCharmIDs: [], reputation: 0)
        XCTAssertNotEqual(day2, day3)
        XCTAssertNotEqual(day2, rerolled)
    }

    func testOwnedItemsAreNeverOffered() {
        let stock = Shop.stock(
            runSeed: 7, day: 1, restocks: 0,
            ownedToolIDs: ["brush", "fine_brush", "sieve"],
            ownedCharmIDs: ["rush_job", "rock_hound"],
            reputation: 0
        )
        XCTAssertFalse(stock.toolIDs.contains("fine_brush"))
        XCTAssertFalse(stock.toolIDs.contains("sieve"))
        XCTAssertFalse(stock.charmIDs.contains("rush_job"))
        XCTAssertFalse(stock.charmIDs.contains("rock_hound"))
    }

    func testVaultCharmsStayShutUntilTheirPoolOpens() {
        let locked = Shop.stock(
            runSeed: 1, day: 1, restocks: 0, ownedToolIDs: [], ownedCharmIDs: [],
            reputation: 0, pools: [.shop]
        )
        let vaultIDs = Set(
            ContentCatalog.shared.charms.filter { $0.pool == .vault }.map(\.id)
        )
        XCTAssertFalse(vaultIDs.isEmpty, "there should be vault charms to gate")
        XCTAssertTrue(Set(locked.charmIDs).isDisjoint(with: vaultIDs))

        // With the pool open they become reachable at all.
        var seenVault = false
        for day in 1...40 {
            let open = Shop.stock(
                runSeed: UInt64(day), day: day, restocks: 0,
                ownedToolIDs: [], ownedCharmIDs: [], reputation: 0,
                pools: [.shop, .vault]
            )
            if !Set(open.charmIDs).isDisjoint(with: vaultIDs) { seenVault = true; break }
        }
        XCTAssertTrue(seenVault, "vault charms never appeared with the pool open")
    }

    func testBuyingSpendsCashAndFillsASlot() throws {
        var run = shopping()
        let id = run.shop.toolIDs[0]
        let price = ContentCatalog.shared.tool(id)!.price
        let before = run.cash
        try run.buyTool(id)
        XCTAssertEqual(run.cash, before - price)
        XCTAssertTrue(run.toolIDs.contains(id))
        XCTAssertFalse(run.shop.toolIDs.contains(id), "it stayed on the shelf")
    }

    func testCannotBuyWhatIsNotOffered() {
        var run = shopping()
        let notOffered = ContentCatalog.shared.tools
            .first { !run.shop.toolIDs.contains($0.id) && $0.price > 0 }!
        XCTAssertThrowsError(try run.buyTool(notOffered.id)) { error in
            XCTAssertEqual(error as? RunState.PurchaseFailure, .notOffered)
        }
    }

    func testCannotBuyWithoutCash() {
        var run = shopping(cash: 1)
        let id = run.shop.charmIDs[0]
        XCTAssertThrowsError(try run.buyCharm(id)) { error in
            guard case .tooExpensive = error as? RunState.PurchaseFailure else {
                return XCTFail("expected .tooExpensive, got \(error)")
            }
        }
    }

    func testToolSlotsAreLimitedToThree() throws {
        var run = shopping(cash: 5_000)
        // Starting brush occupies one of the three.
        XCTAssertEqual(run.toolIDs.count, 1)
        var bought = 0
        for _ in 0..<6 {
            run.openShop(reputation: 0)
            guard let id = run.shop.toolIDs.first else { break }
            if (try? run.buyTool(id)) != nil { bought += 1 } else { break }
            try? run.restock(reputation: 0)
        }
        XCTAssertEqual(run.toolIDs.count, RunState.toolSlots)
        XCTAssertFalse(run.hasToolSlot)
        XCTAssertEqual(bought, RunState.toolSlots - 1)
    }

    func testCharmSlotsAreLimitedToFour() {
        var run = shopping(cash: 5_000)
        for _ in 0..<10 {
            run.openShop(reputation: 0)
            guard let id = run.shop.charmIDs.first else { break }
            if (try? run.buyCharm(id)) == nil { break }
            try? run.restock(reputation: 0)
        }
        XCTAssertEqual(run.charmIDs.count, RunState.charmSlots)
        XCTAssertFalse(run.hasCharmSlot)
    }

    func testRestockCostsTenAndRerolls() throws {
        var run = shopping()
        let before = run.shop
        let cash = run.cash
        try run.restock(reputation: 0)
        XCTAssertEqual(run.cash, cash - Shop.restockPrice)
        XCTAssertEqual(run.shop.restocks, 1)
        XCTAssertNotEqual(run.shop, before)
    }

    func testSellingReturnsHalfPrice() throws {
        var run = shopping()
        let id = run.shop.charmIDs[0]
        let charm = ContentCatalog.shared.charm(id)!
        try run.buyCharm(id)
        let afterBuying = run.cash
        let refund = run.sellCharm(id)
        XCTAssertEqual(refund, charm.price / 2)
        XCTAssertEqual(run.cash, afterBuying + charm.price / 2)
        XCTAssertFalse(run.charmIDs.contains(id))
    }

    func testTheStartingBrushCannotBeSold() {
        var run = shopping()
        let before = run.cash
        XCTAssertEqual(run.sellTool(BrushTool.brush.id), 0)
        XCTAssertEqual(run.cash, before)
        XCTAssertTrue(run.toolIDs.contains(BrushTool.brush.id),
                      "a run with no brush is a run you cannot play")
    }

    func testLeavingTheTentClearsTheStock() {
        var run = shopping()
        XCTAssertFalse(run.shop.isEmpty)
        run.leaveShop()
        XCTAssertTrue(run.shop.isEmpty)
        XCTAssertEqual(run.phase, .digging(day: 2))
    }

    func testCannotShopOutsideTheTent() {
        var run = RunState(seed: 1, siteID: "charmouth")
        XCTAssertThrowsError(try run.buyCharm("rush_job")) { error in
            XCTAssertEqual(error as? RunState.PurchaseFailure, .notShopping)
        }
    }
}
