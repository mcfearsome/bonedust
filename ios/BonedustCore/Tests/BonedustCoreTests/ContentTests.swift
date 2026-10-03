import XCTest
@testable import BonedustCore

final class ContentTests: XCTestCase {

    func testCatalogLoads() {
        let catalog = ContentCatalog.shared
        XCTAssertGreaterThanOrEqual(catalog.fossils.count, 16, "§4 targets about 16 fossils")
        XCTAssertEqual(catalog.sites.count, 5)
        XCTAssertFalse(catalog.sets.isEmpty)
    }

    func testCatalogIsInternallyConsistent() {
        XCTAssertEqual(ContentCatalog.shared.validate(), [])
    }

    func testBriefedFossilsAndValuesArePresent() {
        // The ten fossils and base values the brief names explicitly.
        let expected: [String: Int] = [
            "ammonite": 90, "belemnite": 55, "ichthyo_vertebrae": 140,
            "trilobite": 75, "brachiopod": 40, "knightia": 110,
            "fossil_leaf": 60, "raptor_claw": 170, "trex_tooth": 200,
            "trike_horn": 260,
        ]
        for (id, value) in expected {
            guard let fossil = ContentCatalog.shared.fossil(id) else {
                return XCTFail("missing fossil \(id)")
            }
            XCTAssertEqual(fossil.baseValue, value, "\(id) base value")
        }
    }

    func testEveryShapeExpandsToSomething() {
        for fossil in ContentCatalog.shared.fossils {
            let primitives = fossil.shape.expand()
            XCTAssertFalse(primitives.isEmpty, "\(fossil.id) expanded to nothing")
        }
    }

    func testEveryShapeKindIsUsedBySomeFossil() {
        let used = Set(ContentCatalog.shared.fossils.map(\.shape.kind))
        for kind in FossilShapeSpec.Kind.allCases {
            XCTAssertTrue(used.contains(kind), "no fossil uses shape kind \(kind.rawValue)")
        }
    }

    func testShapeParamsDefaultWhenAbsentFromJSON() throws {
        // The lenient decoders exist so content JSON can omit params. If this
        // breaks, every fossil silently becomes the default shape.
        let json = #"{"kind":"taper","spanCells":40}"#
        let spec = try JSONDecoder().decode(FossilShapeSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.params, ShapeParams())
        XCTAssertEqual(spec.spanCells, 40)
    }

    func testPaletteDecodesArrayForm() throws {
        let json = #"{"topsoil":[1,2,3]}"#
        let palette = try JSONDecoder().decode(SlabPalette.self, from: Data(json.utf8))
        XCTAssertEqual(palette.topsoil, RGB8(1, 2, 3))
        XCTAssertEqual(palette.bone, SlabPalette.standard.bone, "unspecified keys keep defaults")
    }

    func testUnlockDecoding() throws {
        func unlock(_ json: String) throws -> SiteUnlock {
            try JSONDecoder().decode(SiteUnlock.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try unlock(#""start""#), .start)
        XCTAssertEqual(try unlock(#"{"reputation":200}"#), .reputation(200))
        XCTAssertEqual(try unlock(#"{"crewMilestone":250000}"#), .crewMilestone(250_000))
    }

    func testSiteUnlockGates() {
        // Wheeler and Green River are gated lower than the brief's 200 and 600. At those
        // numbers the map never opened: Reputation accrues at roughly 25 a run, so
        // Wheeler needed eight successful runs and Green River sixty, while careers were
        // ending at tier two or three. See DECISIONS.md.
        func unlock(_ id: String) -> SiteUnlock? { ContentCatalog.shared.site(id)?.unlock }
        XCTAssertEqual(unlock("charmouth"), .start)
        XCTAssertEqual(unlock("wheeler"), .reputation(60))
        XCTAssertEqual(unlock("green_river"), .reputation(180))
        XCTAssertEqual(unlock("hell_creek"), .crewMilestone(250_000))
        XCTAssertEqual(unlock("night_dig"), .crewMilestone(1_000_000))
    }

    func testSiteTwistsAreExpressedAsNumbers() {
        let catalog = ContentCatalog.shared
        XCTAssertEqual(catalog.site("wheeler")?.modifiers.maxDepth, 2, "thin layers")
        XCTAssertEqual(catalog.site("wheeler")?.modifiers.extraInstances, 1, "many small fossils")
        XCTAssertGreaterThan(catalog.site("green_river")?.modifiers.crackMultiplier ?? 0, 1)
        // Green River has to pay for the risk it adds, or unlocking it is a downgrade.
        XCTAssertGreaterThan(catalog.site("green_river")?.modifiers.payoutMultiplier ?? 0, 1)
        XCTAssertGreaterThan(catalog.site("hell_creek")?.modifiers.extraRockNodules ?? 0, 0)
        XCTAssertEqual(catalog.site("night_dig")?.modifiers.payoutMultiplier, 1.5)
        XCTAssertLessThan(catalog.site("night_dig")?.modifiers.daylightDelta ?? 0, 0)
    }

    func testWeightedTableIsStablyOrdered() {
        // Generation draws from this, so dictionary iteration order would make the
        // same seed produce different fossils between runs.
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        let first = site.weightedTable.map(\.fossilID)
        for _ in 0..<20 {
            XCTAssertEqual(site.weightedTable.map(\.fossilID), first)
        }
        XCTAssertEqual(first, first.sorted())
    }
}

extension FossilShapeSpec.Kind: CaseIterable {
    public static var allCases: [FossilShapeSpec.Kind] {
        [.spiral, .taper, .crescent, .discs, .segmentedBody, .fan, .fish, .leaf]
    }
}

final class SiteModifierCompositionTests: XCTestCase {

    func testSiteTwistComposesLikeACharm() {
        guard let night = ContentCatalog.shared.site("night_dig") else { return XCTFail() }
        var nightOwl = ModifierSet()
        nightOwl.daylightDelta = 15
        nightOwl.payoutMultiplier = 0.9

        let combined = ModifierSet.combining([night.modifiers.modifierSet, nightOwl])
        // -12 from the site, +15 from the charm.
        XCTAssertEqual(combined.daylightDelta, 3, accuracy: 0.0001)
        // 1.5 from the site, 0.9 from the charm.
        XCTAssertEqual(combined.payoutMultiplier, 1.35, accuracy: 0.0001)
    }

    func testGenerationOnlyFieldsStayOutOfTheModifierSet() {
        guard let wheeler = ContentCatalog.shared.site("wheeler") else { return XCTFail() }
        // maxDepth and extraInstances are generation inputs, not multipliers; if they
        // leaked into ModifierSet they would be silently applied twice.
        let set = wheeler.modifiers.modifierSet
        XCTAssertEqual(set.payoutMultiplier, 1)
        XCTAssertEqual(set.daylightDelta, 0)
        XCTAssertEqual(set.crackMultiplier, 1)
        XCTAssertEqual(wheeler.modifiers.maxDepth, 2)
    }
}
