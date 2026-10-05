import XCTest
@testable import BonedustCore

/// Selling a specimen, and what it costs to sell it well.
final class SaleTests: XCTestCase {

    private func buyer(_ id: String) -> Buyer { ContentCatalog.shared.buyer(id)! }

    func testEveryBuyerIsACompromise() {
        let wheeler = buyer("wheeler"), dealer = buyer("dealer")
        let fence = buyer("fence"), museum = buyer("museum")

        // Money, heat and reputation have to pull against each other, or there is no
        // decision -- one option would simply dominate and the screen is a menu.
        XCTAssertLessThan(wheeler.priceMultiplier, dealer.priceMultiplier)
        XCTAssertLessThan(dealer.priceMultiplier, fence.priceMultiplier)
        XCTAssertLessThan(wheeler.heat, dealer.heat)
        XCTAssertLessThan(dealer.heat, fence.heat)
        XCTAssertEqual(wheeler.heat, 0, "the safe option has to be genuinely safe")
        XCTAssertLessThan(museum.priceMultiplier, wheeler.priceMultiplier)
        XCTAssertGreaterThan(museum.reputation, 0, "only the museum sells your name back")
        XCTAssertFalse(fence.paysDebt, "the crew sees nothing from the docks")
    }

    func testNothingIsSeizedWhileHeatIsLow() {
        for id in ["wheeler", "dealer", "fence", "museum"] {
            XCTAssertEqual(
                Sale.seizureChance(heat: 0, value: 900, buyer: buyer(id)), 0,
                "\(id) risked a specimen on week one, when nobody knows what heat is yet"
            )
        }
    }

    func testWheelerIsNeverRisky() {
        XCTAssertEqual(
            Sale.seizureChance(heat: 10_000, value: 5_000, buyer: buyer("wheeler")), 0,
            "the option that pays least must stay the option that cannot lose anything"
        )
    }

    /// A Tyrannosaurus is on a list before it leaves the county; a crinoid is one of
    /// thousands. What a fossil is worth and how hard it is to move are the same number.
    func testAFamousSpecimenIsHarderToMove() {
        let fence = buyer("fence")
        let quiet = Sale.seizureChance(heat: 70, value: 60, buyer: fence)
        let famous = Sale.seizureChance(heat: 70, value: 1_400, buyer: fence)
        XCTAssertGreaterThan(famous, quiet)
        XCTAssertGreaterThan(
            Sale.heatAdded(value: 1_400, buyer: fence),
            Sale.heatAdded(value: 60, buyer: fence)
        )
    }

    func testSeizureIsPartOfTheSaveAndCannotBeReRolled() {
        let fence = buyer("fence")
        func roll(_ seed: UInt64) -> Bool {
            var rng = SplitMix64(seed: seed)
            return Sale.isSeized(heat: 90, value: 1_200, buyer: fence, rng: &rng)
        }
        for seed in UInt64(1)...20 {
            XCTAssertEqual(roll(seed), roll(seed), "the same seed rolled differently")
        }
    }

    func testHeatCoolsBetweenWeeks() {
        XCTAssertLessThan(Sale.cooled(60), 60)
        XCTAssertEqual(Sale.cooled(0), 0, "heat cannot go negative")
    }

    func testSellingToTheFencePaysTheCrewNothing() {
        var run = RunState(seed: 9, siteID: "charmouth")
        let slab = SlabRecord(
            day: 1, seed: 1, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                exposure: 1, intact: 1, fossil: 400, gems: 0, bonuses: 0,
                multiplier: 1, rushApplied: false, total: 400
            ),
            durationMillis: 30_000, bagged: true, wholeGems: 0, daylightLeft: 8
        )
        let paid = run.completeSlab(slab, buyer: buyer("fence"))
        XCTAssertEqual(paid, 0, "the docks do not report sales")
        XCTAssertGreaterThan(run.cash, 400, "but it pays you better than anyone")
        XCTAssertGreaterThan(run.heat, 0)
    }

    func testSellingToWheelerPaysTheCrewInFull() {
        var run = RunState(seed: 9, siteID: "charmouth")
        let slab = SlabRecord(
            day: 1, seed: 1, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                exposure: 1, intact: 1, fossil: 400, gems: 0, bonuses: 0,
                multiplier: 1, rushApplied: false, total: 400
            ),
            durationMillis: 30_000, bagged: true, wholeGems: 0, daylightLeft: 8
        )
        XCTAssertEqual(run.completeSlab(slab, buyer: buyer("wheeler")), 400)
        XCTAssertEqual(run.heat, 0)
    }

    /// No buyer may be strictly better than the others, or the screen is a menu.
    ///
    /// The economy sweep cannot answer this: it sells to nobody, which is Wheeler by
    /// another name, so it measures the baseline and never the choice. What keeps the fence
    /// honest is that heat compounds -- 2.1x the money is worth having until the seizure
    /// chance it builds eats the difference, and after that it is worse than Wheeler
    /// forever while the crew debt has seen none of it.
    func testSellingAlwaysToTheFenceStopsPayingOff() {
        let fence = buyer("fence"), wheeler = buyer("wheeler")
        let value = 600
        var heat = 0
        var fenceTotal = 0.0
        var wheelerTotal = 0.0

        // Twenty sales, always to the same buyer, with heat accumulating and cooling the
        // way a run does.
        for week in 0..<20 {
            let risk = Sale.seizureChance(heat: heat, value: value, buyer: fence)
            fenceTotal += Double(Sale.price(of: value, from: fence)) * Double(1 - risk)
            wheelerTotal += Double(Sale.price(of: value, from: wheeler))
            heat += Sale.heatAdded(value: value, buyer: fence)
            if week % 5 == 4 { heat = Sale.cooled(heat) }
        }

        let finalRisk = Sale.seizureChance(heat: heat, value: value, buyer: fence)
        print(String(format: "\n  fence over 20 sales: $%.0f, ending at %.0f%% risk",
                     fenceTotal, finalRisk * 100))
        print(String(format: "  wheeler over 20 sales: $%.0f, no risk ever", wheelerTotal))

        XCTAssertGreaterThan(finalRisk, 0.3, "heat never caught up with the fence")
        XCTAssertLessThan(
            Double(Sale.price(of: value, from: fence)) * Double(1 - finalRisk),
            Double(Sale.price(of: value, from: wheeler)),
            "at full heat the fence must pay worse than Wheeler, or there is no reason to "
                + "ever choose the safe option and the screen is a menu"
        )
    }

    /// The third time this shape has come up. A ceiling that does not know what a buyer
    /// pays rejects the sale the moment a player takes the money.
    func testNoSaleCanOutEarnTheServerCeiling() {
        let catalog = ContentCatalog.shared
        let best = catalog.buyers.max { $0.priceMultiplier < $1.priceMultiplier }!
        for siteID in ["charmouth", "hell_creek"] {
            guard let site = catalog.site(siteID) else { continue }
            for seed in UInt64(0)..<20 {
                let layout = SlabGenerator.generate(seed: seed, site: site).layout
                guard let fossil = catalog.fossil(layout.fossilID) else { continue }
                let perfect = Payout.evaluate(PayoutContext(
                    baseValue: fossil.baseValue, instances: layout.instances,
                    exposure: 1, boneCells: max(1, layout.boneCells), crackedCells: 0,
                    wholeGems: layout.gemCount,
                    daylightRemaining: SimTuning.standard.daylightSeconds,
                    totalDaylight: SimTuning.standard.daylightSeconds,
                    modifiers: site.modifiers.modifierSet
                ))
                let sold = Sale.price(of: perfect.total, from: best)
                let ceiling = ServerCeiling.ceiling(
                    fossil: fossil, instances: layout.instances,
                    site: site, claimedCharms: [], catalog: catalog
                )
                XCTAssertLessThanOrEqual(
                    sold, ceiling,
                    "\(siteID) seed \(seed): a perfect slab sold to \(best.name) fetches "
                        + "$\(sold) against a $\(ceiling) ceiling"
                )
            }
        }
    }
}
