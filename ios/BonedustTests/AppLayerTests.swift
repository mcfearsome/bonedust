import BonedustCore
import SwiftUI
import XCTest
@testable import Bonedust

/// App-layer tests. The simulation and economy suites live in the BonedustCore
/// package where they run without a simulator; these cover only the glue that needs
/// UIKit or the engine's main-actor state machine.
@MainActor
final class DigEngineTests: XCTestCase {

    private func engine(
        site siteID: String = "charmouth", seed: UInt64 = 4242
    ) -> DigEngine {
        let site = ContentCatalog.shared.site(siteID) ?? ContentCatalog.shared.sites[0]
        return DigEngine(seed: seed, site: site)
    }

    func testDaylightDoesNotStartUntilFirstTouch() {
        let subject = engine()
        XCTAssertEqual(subject.phase, .waiting)
        subject.tick(delta: 5)
        XCTAssertEqual(subject.daylightRemaining, subject.totalDaylight,
                       "daylight burned before the player touched the slab")

        subject.brushBegan(at: Vec2(48, 64))
        XCTAssertEqual(subject.phase, .digging)
        subject.tick(delta: 5)
        XCTAssertEqual(subject.daylightRemaining, subject.totalDaylight - 5, accuracy: 0.001)
    }

    func testRunningOutOfDaylightEndsTheSlab() {
        let subject = engine()
        subject.brushBegan(at: Vec2(48, 64))
        subject.tick(delta: Double(subject.totalDaylight) + 1)
        XCTAssertEqual(subject.phase, .finished(bagged: false))
        XCTAssertEqual(subject.daylightRemaining, 0)
    }

    func testBaggingEndsTheSlabAsBagged() {
        let subject = engine()
        subject.brushBegan(at: Vec2(48, 64))
        subject.bagIt()
        XCTAssertEqual(subject.phase, .finished(bagged: true))
    }

    func testBrushingAfterTheSlabEndsDoesNothing() {
        let subject = engine()
        subject.brushBegan(at: Vec2(48, 64))
        subject.bagIt()
        let before = subject.grid.contentHash
        subject.brushMoved(to: Vec2(60, 70), deltaMillis: 16)
        XCTAssertEqual(subject.grid.contentHash, before)
    }

    func testNightDigAppliesItsTwistToDaylightAndPayout() {
        let night = engine(site: "night_dig")
        let day = engine(site: "charmouth")
        XCTAssertLessThan(night.totalDaylight, day.totalDaylight)
        XCTAssertEqual(night.modifiers.payoutMultiplier, 1.5, accuracy: 0.0001)
    }

    func testFossilFragilityMultipliesIntoTheSiteTwist() {
        let river = engine(site: "green_river")
        // Green River's 1.35 times the fossil's own multiplier, which is above 1 for
        // every fossil in that table.
        XCTAssertGreaterThan(river.modifiers.crackMultiplier, 1.35)
    }

    func testPublishedReadoutsTrackTheSimulation() {
        let subject = engine()
        subject.brushBegan(at: Vec2(20, 30))
        for x in stride(from: Float(20), through: 76, by: 1.5) {
            subject.brushMoved(to: Vec2(x, 64), deltaMillis: 16.67)
        }
        subject.brushEnded()
        subject.publish()
        XCTAssertGreaterThan(subject.exposurePercent, 0)
        XCTAssertEqual(subject.intactPercent, 100, "a slow sweep should not crack anything")
        XCTAssertGreaterThan(subject.speed, 0)
    }

    func testSpecimenStaysUnidentifiedUntilTheThreshold() {
        let subject = engine()
        XCTAssertEqual(subject.specimenName, "Unidentified")
        XCTAssertTrue(subject.specimenCode.hasPrefix("BD-"))
    }

    func testEstimatedValueExcludesTheRushBonus() {
        // A number that jumps when a timer crosses a threshold reads as a bug.
        let site = ContentCatalog.shared.site("charmouth")!
        var rush = ModifierSet()
        rush.rushMultiplier = 1.4
        rush.rushThreshold = 20
        let subject = DigEngine(seed: 9, site: site, extraModifiers: rush)
        subject.brushBegan(at: Vec2(48, 64))
        for x in stride(from: Float(10), through: 86, by: 1.5) {
            subject.brushMoved(to: Vec2(x, 64), deltaMillis: 16.67)
        }
        subject.publish()
        let estimate = subject.estimatedValue
        let actual = subject.payout().total
        XCTAssertTrue(subject.payout().rushApplied, "the rush window should be open here")
        XCTAssertLessThan(estimate, actual)
    }

    func testGentleModeHalvesCracksAndReducesPayout() {
        let settings = GameSettings(
            defaults: UserDefaults(suiteName: "bonedust.tests.\(UUID().uuidString)")!
        )
        settings.gentleMode = true
        let modifiers = settings.gentleModeModifiers
        XCTAssertEqual(modifiers.crackMultiplier, 0.5)
        XCTAssertEqual(modifiers.payoutMultiplier, 0.8)
    }
}

final class SlabRendererTests: XCTestCase {

    func testRendererFillsEveryPixelOpaque() {
        let site = ContentCatalog.shared.site("charmouth")!
        let (grid, _) = SlabGenerator.generate(seed: 1, site: site)
        var renderer = SlabRenderer(palette: site.palette)
        renderer.redrawEverything(grid)
        XCTAssertEqual(
            renderer.pixels.count,
            SlabGrid.width * SlabGrid.height * 4
        )
        for index in stride(from: 3, to: renderer.pixels.count, by: 4) {
            XCTAssertEqual(renderer.pixels[index], 255, "pixel \(index / 4) is not opaque")
        }
    }

    func testExposedBoneRendersLighterThanBuriedMatrix() {
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount { grid.cells[index].depth = 3 }
        // One exposed bone cell in a field of topsoil.
        let bone = SlabGrid.index(48, 64)
        grid.cells[bone].depth = 0
        grid.cells[bone].flags |= SlabGrid.Flag.bone

        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertGreaterThan(luma(48, 64), luma(10, 10), "bone should read brighter than topsoil")
    }

    func testTheBoneTellBrightensSandstoneOverBone() {
        // §3's tell. If this stops working, careful play stops being possible.
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 1
        }
        let overBone = SlabGrid.index(30, 30)
        grid.cells[overBone].flags |= SlabGrid.Flag.bone
        // Remove cosmetic noise so the comparison is only about the tell.
        for index in 0..<SlabGrid.cellCount { grid.cells[index].noise = 0 }

        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertGreaterThan(luma(30, 30), luma(60, 60), "sandstone over bone is not tinted")
    }

    func testDirtyRedrawMatchesAFullRedraw() {
        // The renderer inflates the dirty rect by one cell for edge shading. If that
        // inflation is wrong, digging leaves stale seams, which this catches.
        let site = ContentCatalog.shared.site("hell_creek")!
        var sim = SlabSimulation(seed: 88, site: site)
        var incremental = SlabRenderer(palette: site.palette)
        incremental.redrawEverything(sim.grid)
        _ = sim.consumeDirty()

        sim.beginStroke(at: Vec2(20, 30), tool: .brush)
        for step in 0..<120 {
            let x = 20 + Float(step) * 0.5
            sim.moveStroke(to: Vec2(x, 30 + Float(step) * 0.3), deltaMillis: 16.67, tool: .brush)
        }
        sim.endStroke()
        incremental.redraw(sim.grid, region: sim.consumeDirty())

        var full = SlabRenderer(palette: site.palette)
        full.redrawEverything(sim.grid)
        XCTAssertEqual(incremental.pixels, full.pixels,
                       "incremental redraw left stale pixels")
    }
}

extension SlabGrid {
    var contentHash: Int {
        var hash = Hasher()
        for cell in cells {
            hash.combine(cell.depth)
            hash.combine(cell.flags)
            hash.combine(cell.wear)
        }
        return hash.finalize()
    }
}

/// Design-token tests. These live in the app target because `Ink` and `Typography`
/// need SwiftUI and UIKit; the ramp's own guarantees are tested in BonedustCore.
final class DesignTokenTests: XCTestCase {

    func testDayAndNightAreDifferentPalettes() {
        XCTAssertNotEqual(Ink.day, Ink.night)
    }

    func testLerpReturnsTheEndpointsExactly() {
        XCTAssertEqual(Ink.lerp(from: .day, to: .night, 0), Ink.day)
        XCTAssertEqual(Ink.lerp(from: .day, to: .night, 1), Ink.night)
    }

    /// The night accents must actually be the night ones. Reusing the day accents
    /// here was the defect Task 1's review caught, and nothing else would notice:
    /// Ink has no contrast assertion of its own, and the page still renders.
    func testNightUsesTheNightAccentsNotTheDayOnes() {
        XCTAssertNotEqual(Ink.night.stamp, Ink.day.stamp)
        XCTAssertNotEqual(Ink.night.gem, Ink.day.gem)
        XCTAssertNotEqual(Ink.night.safe, Ink.day.safe)
        XCTAssertEqual(Ink.night.stamp, Color(Earth.stampNight))
        XCTAssertEqual(Ink.night.gem, Color(Earth.gemNight))
        XCTAssertEqual(Ink.night.safe, Color(Earth.safeNight))
    }

    func testLerpClampsOutOfRangeFractions() {
        XCTAssertEqual(Ink.lerp(from: .day, to: .night, -5), Ink.day)
        XCTAssertEqual(Ink.lerp(from: .day, to: .night, 42), Ink.night)
    }

    /// Review Focus 4. Dynamic Type must reach the custom faces. A font built with
    /// `Font.custom(_:fixedSize:)` would return the same metrics at every size.
    func testDisplayFontScalesWithDynamicType() {
        let small = Typography.resolvedDisplayPointSize(
            40, for: UITraitCollection(preferredContentSizeCategory: .small)
        )
        let huge = Typography.resolvedDisplayPointSize(
            40, for: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThan(huge, small, "display face ignores Dynamic Type")
    }

    func testNumberFontScalesWithDynamicType() {
        let small = Typography.resolvedNumberPointSize(
            17, for: UITraitCollection(preferredContentSizeCategory: .small)
        )
        let huge = Typography.resolvedNumberPointSize(
            17, for: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThan(huge, small, "numeral face ignores Dynamic Type")
    }
}
