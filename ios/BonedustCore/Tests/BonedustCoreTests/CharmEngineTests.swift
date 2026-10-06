import XCTest
@testable import BonedustCore

/// Charms that read the run, and therefore each other.
///
/// The point of the build layer: a charm that reads only its own value is a percentage,
/// while a charm that reads the run can be set up for, played around, and stacked. Two
/// charms feeding the same counter make something neither does alone, which is the whole
/// reason to replay a week.
final class CharmEngineTests: XCTestCase {

    private func charm(_ id: String) -> Charm { ContentCatalog.shared.charm(id)! }

    func testEveryScalingCharmActuallyScales() {
        let catalog = ContentCatalog.shared
        let empty = CharmContext()
        // A run that has gone well, gone badly, and gone sideways all at once, so every
        // counter a charm might read is non-zero.
        let busy = CharmContext(
            day: 4, charmCount: 4, toolCount: 3, siteID: "charmouth", tier: 3,
            bankedGems: 6, flawlessSlabs: 3, crackedCells: 90, speciesThisRun: 4,
            heat: 40, quietSales: 2, daysRemaining: 2, intactStreak: 3
        )
        var inert: [String] = []
        for c in catalog.charms where c.scaling != nil {
            if c.resolve(empty) == c.resolve(busy) { inert.append(c.id) }
        }
        XCTAssertTrue(
            inert.isEmpty,
            "these charms carry a scaling rule and resolve identically on an empty run and "
                + "a busy one, so the rule does nothing: \(inert)"
        )
    }

    /// The bug this layer shipped with. `DigEngine` built `CharmContext(day:siteID:)`, so
    /// every counter was zero and every scaling charm was inert in the actual game while
    /// its price and blurb promised otherwise.
    func testTheRunBuildsAContextThatIsNotEmpty() {
        var run = RunState(seed: 5, siteID: "charmouth")
        run.charmIDs = ["compound_interest", "reputation_precedes"]
        run.toolIDs = ["brush", "fine_brush"]
        let context = run.charmContext(forDay: 1)
        XCTAssertEqual(context.charmCount, 2)
        XCTAssertEqual(context.toolCount, 2)
        XCTAssertNotEqual(context, CharmContext(), "the dig was handed an empty context")
    }

    func testFlawlessSlabsFeedThreeDifferentCharms() {
        var run = RunState(seed: 5, siteID: "charmouth")
        run.charmIDs = ["reputation_precedes", "last_light", "curators_streak"]

        func slab(_ day: Int, intact: Float) -> SlabRecord {
            SlabRecord(
                day: day, seed: UInt64(day), siteID: "charmouth", fossilID: "ammonite",
                payout: PayoutBreakdown(
                    exposure: 1, intact: intact, fossil: 300, gems: 0, bonuses: 0,
                    multiplier: 1, rushApplied: false, total: 300
                ),
                durationMillis: 30_000, bagged: true, wholeGems: 0, daylightLeft: 6
            )
        }
        let before = run.modifiers(forDay: 1)
        for day in 1...3 {
            run.completeSlab(slab(day, intact: 1))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        let after = run.modifiers(forDay: 4)

        // One clean week compounds through all three at once, which is the difference
        // between a build and a list of percentages.
        XCTAssertGreaterThan(after.payoutMultiplier, before.payoutMultiplier * 1.4)
        XCTAssertGreaterThan(after.daylightDelta, before.daylightDelta + 6)
    }

    func testBreakingOneSlabEndsTheStreakButNotTheTotal() {
        var run = RunState(seed: 5, siteID: "charmouth")
        run.charmIDs = ["curators_streak", "reputation_precedes"]
        func slab(_ day: Int, intact: Float) -> SlabRecord {
            SlabRecord(
                day: day, seed: UInt64(day), siteID: "charmouth", fossilID: "ammonite",
                payout: PayoutBreakdown(
                    exposure: 1, intact: intact, fossil: 300, gems: 0, bonuses: 0,
                    multiplier: 1, rushApplied: false, total: 300
                ),
                durationMillis: 30_000, bagged: true, wholeGems: 0, daylightLeft: 6
            )
        }
        for (day, intact) in [(1, Float(1)), (2, 1), (3, 0.4)] {
            run.completeSlab(slab(day, intact: intact))
            run.advance()
            if case .supplyTent = run.phase { run.leaveShop() }
        }
        let context = run.charmContext(forDay: 4)
        XCTAssertEqual(context.intactStreak, 0, "a broken slab ends the streak")
        XCTAssertEqual(context.flawlessSlabs, 2, "but not what was already earned")
        XCTAssertGreaterThan(context.crackedCells, 0)
    }

    /// Two builds that want opposite things, which is what makes a run a choice rather
    /// than a checklist.
    func testTheCarefulAndRecklessBuildsPullApart() {
        let careful = CharmContext(
            charmCount: 3, flawlessSlabs: 5, crackedCells: 0, intactStreak: 5
        )
        let reckless = CharmContext(
            charmCount: 3, flawlessSlabs: 0, crackedCells: 400, heat: 70, quietSales: 4
        )
        let curator = charm("reputation_precedes").resolve(careful).payoutMultiplier
        let curatorReckless = charm("reputation_precedes").resolve(reckless).payoutMultiplier
        let salvage = charm("salvage_rights").resolve(reckless).payoutMultiplier
        let salvageCareful = charm("salvage_rights").resolve(careful).payoutMultiplier

        XCTAssertGreaterThan(curator, curatorReckless)
        XCTAssertGreaterThan(salvage, salvageCareful)
        XCTAssertGreaterThan(
            charm("no_questions").resolve(reckless).payoutMultiplier,
            charm("no_questions").resolve(careful).payoutMultiplier
        )
    }

    /// A charm strong enough to want a cost must actually carry one.
    func testHeavyHandGetsWorseAsTheBeltFills() {
        let light = charm("heavy_hand").resolve(CharmContext(charmCount: 1))
        let full = charm("heavy_hand").resolve(CharmContext(charmCount: 4))
        XCTAssertGreaterThan(full.crackMultiplier, light.crackMultiplier)
        XCTAssertLessThan(light.rockHardnessMultiplier, 1, "it should still dig faster")
    }

    /// Both directions of the content/code seam.
    ///
    /// The gap this catches is invisible from either side alone: the enum case, the
    /// resolve arm, the Swift ceiling bound and the Ruby ceiling bound can all be present
    /// and correct while no charm in the game names the rule, so it never fires. That is
    /// what `payoutPerTool` and `daylightPerFlawless` were — four pieces of working
    /// machinery wired to nothing.
    func testEveryScalingRuleIsNamedBySomeCharm() {
        let used = Set(ContentCatalog.shared.charms.compactMap { $0.scaling?.kindName })
        let orphans = CharmScaling.allKinds.filter { !used.contains($0) }
        XCTAssertTrue(
            orphans.isEmpty,
            "these scaling rules are implemented but no charm names them, so they cannot "
                + "happen in the game: \(orphans)"
        )
        let unknown = used.subtracting(CharmScaling.allKinds)
        XCTAssertTrue(unknown.isEmpty, "allKinds has drifted from the content: \(unknown)")
    }

    func testEveryNamedRuleDecodes() throws {
        for kind in CharmScaling.allKinds {
            let json = Data(#"{"kind":"\#(kind)","value":0.5}"#.utf8)
            let decoded = try JSONDecoder().decode(CharmScaling.self, from: json)
            XCTAssertEqual(
                decoded.kindName, kind,
                "allKinds names \(kind) but it does not round-trip through the decoder"
            )
        }
    }
}
