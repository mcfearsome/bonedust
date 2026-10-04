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

    /// `min` and `max` hand NaN straight through, so the clamp alone would give every
    /// colour NaN components. A NaN light level means "not started": the `from` palette.
    func testLerpTreatsNaNAsTheFromPalette() {
        // `XCTAssertTrue` on purpose: a failed `XCTAssertEqual` prints both palettes,
        // and printing a NaN `Color` traps, which would take the whole run down.
        XCTAssertTrue(Ink.lerp(from: .day, to: .night, .nan) == Ink.day)
        XCTAssertTrue(Ink.lerp(from: .night, to: .day, .nan) == Ink.night)
    }

    /// Every assertion above lands on an early return, so none of them reaches
    /// `Color.mixed`. This reads each colour's channels back out at the midpoint and
    /// compares them with the average of the two endpoints. A swapped channel, or a
    /// colour blended with the wrong partner, fails here and nowhere else.
    func testLerpInteriorBlendsEveryChannelOfEveryColour() {
        let mid = Ink.lerp(from: .day, to: .night, 0.5)
        XCTAssertNotEqual(mid, Ink.day)
        XCTAssertNotEqual(mid, Ink.night)

        let colours: [(String, KeyPath<Ink, Color>)] = [
            ("page", \.page), ("raised", \.raised), ("hairline", \.hairline),
            ("ink", \.ink), ("muted", \.muted), ("stamp", \.stamp),
            ("gem", \.gem), ("safe", \.safe), ("mount", \.mount),
        ]
        for (name, colour) in colours {
            let day = channels(of: Ink.day[keyPath: colour])
            let night = channels(of: Ink.night[keyPath: colour])
            let blended = channels(of: mid[keyPath: colour])
            XCTAssertEqual(blended.red, (day.red + night.red) / 2, accuracy: 0.0001, "\(name) red")
            XCTAssertEqual(blended.green, (day.green + night.green) / 2, accuracy: 0.0001, "\(name) green")
            XCTAssertEqual(blended.blue, (day.blue + night.blue) / 2, accuracy: 0.0001, "\(name) blue")
        }
    }

    /// Ink has no contrast assertion of its own, and a page with faint text still
    /// renders. This reads the text colours back out of each palette and holds them to
    /// AA on the surfaces they are drawn on. `Ink.night.muted` was s4, 4.49:1 on the
    /// night page, until review caught it.
    func testTextColoursClearAAOnTheirOwnSurfaces() {
        for (palette, ink) in [("day", Ink.day), ("night", Ink.night)] {
            for (textName, text) in [("ink", ink.ink), ("muted", ink.muted)] {
                for (surfaceName, surface) in [("page", ink.page), ("raised", ink.raised)] {
                    let ratio = rgb8(of: text).contrastRatio(against: rgb8(of: surface))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5, "\(palette).\(textName) on \(palette).\(surfaceName) is \(ratio):1"
                    )
                }
            }
        }
    }

    /// Review Focus 4. Dynamic Type must reach the custom faces. SwiftUI's `Font` is
    /// opaque, so the only way to see how `display` built one is to compare it with a
    /// Font built the right way. `Font.custom(_:fixedSize:)` is the regression this
    /// exists for: it looks identical at the default size and ignores Dynamic Type.
    func testDisplayFontScalesWithDynamicType() {
        let scaled = Font.custom(Typography.displayFace, size: 40, relativeTo: .largeTitle)
        let fixed = Font.custom(Typography.displayFace, fixedSize: 40)
        XCTAssertNotEqual(
            scaled, fixed, "Font equality cannot tell scaled from fixed, so this test proves nothing"
        )
        XCTAssertEqual(
            Typography.displayFont(40, relativeTo: .largeTitle, customFaceAvailable: true), scaled,
            "display must be Font.custom(_:size:relativeTo:); fixedSize ignores Dynamic Type"
        )
    }

    /// The fallback is the system face the app used before the custom one existed, and
    /// it has to keep scaling. The point size is read out of the same UIFont that
    /// `display` hands to SwiftUI.
    func testDisplayFallbackScalesWithDynamicType() {
        let smallTraits = UITraitCollection(preferredContentSizeCategory: .small)
        let hugeTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let small = Typography.scaledFallbackDisplayFont(40, style: .largeTitle, traits: smallTraits)
        let huge = Typography.scaledFallbackDisplayFont(40, style: .largeTitle, traits: hugeTraits)
        XCTAssertGreaterThan(
            huge.pointSize, small.pointSize, "fallback display face ignores Dynamic Type"
        )

        // And `display` hands SwiftUI exactly that font. This is checked at a size where
        // scaled and unscaled differ: at the default size they are the same font.
        XCTAssertNotEqual(
            Font(small), Font(huge), "Font equality cannot tell sizes apart, so the next check proves nothing"
        )
        XCTAssertEqual(
            Typography.displayFont(
                40, relativeTo: .largeTitle, customFaceAvailable: false, traits: hugeTraits
            ),
            Font(huge), "display must hand SwiftUI the scaled fallback font"
        )
    }

    func testNumberFontScalesWithDynamicType() {
        let size = Font.TextStyle.body.baseSize
        let regular = Font.custom(Typography.numberFace, size: size, relativeTo: .body)
        let bold = Font.custom(Typography.numberBoldFace, size: size, relativeTo: .body)
        XCTAssertNotEqual(
            regular, Font.custom(Typography.numberFace, fixedSize: size),
            "Font equality cannot tell scaled from fixed, so this test proves nothing"
        )
        XCTAssertEqual(
            Typography.numberFont(.body, weight: .regular, regularAvailable: true, boldAvailable: true),
            regular, "number must be Font.custom(_:size:relativeTo:); fixedSize ignores Dynamic Type"
        )
        XCTAssertEqual(
            Typography.numberFont(.body, weight: .bold, regularAvailable: true, boldAvailable: true),
            bold, "the Bold face must scale with Dynamic Type too"
        )
    }

    /// `number` once took a weight and dropped it on the custom path. Four callers ask
    /// for bold or semibold, and every one of them would have rendered Regular the
    /// moment the face was registered. The weight picks a face.
    func testNumberWeightSelectsTheFace() {
        func custom(_ weight: Font.Weight) -> Font {
            Typography.numberFont(.body, weight: weight, regularAvailable: true, boldAvailable: true)
        }
        let regular = custom(.regular)
        let bold = custom(.bold)
        XCTAssertNotEqual(regular, bold)
        for weight in [Font.Weight.semibold, .bold, .heavy, .black] {
            XCTAssertEqual(custom(weight), bold, "\(weight) should select the Bold face")
        }
        for weight in [Font.Weight.ultraLight, .thin, .light, .regular, .medium] {
            XCTAssertEqual(custom(weight), regular, "\(weight) should select the Regular face")
        }
        // The same through the public accessor, on whichever path this process is on.
        XCTAssertNotEqual(
            Typography.number(.body, weight: .bold), Typography.number(.body, weight: .regular)
        )
    }

    /// A missing face degrades to the system face at the weight that was asked for. In
    /// particular a missing Bold file must not quietly fall back to the Regular custom
    /// face, which would look exactly like a dropped weight.
    func testNumberFallsBackToSystemWhenTheMatchingFaceIsMissing() {
        XCTAssertEqual(
            Typography.numberFont(.body, weight: .bold, regularAvailable: true, boldAvailable: false),
            Font.system(.body, design: .monospaced).weight(.bold)
        )
        XCTAssertEqual(
            Typography.numberFont(.body, weight: .regular, regularAvailable: false, boldAvailable: true),
            Font.system(.body, design: .monospaced).weight(.regular)
        )
    }

    private func channels(of colour: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    private func rgb8(of colour: Color) -> RGB8 {
        let c = channels(of: colour)
        return RGB8(
            UInt8((c.red * 255).rounded()),
            UInt8((c.green * 255).rounded()),
            UInt8((c.blue * 255).rounded())
        )
    }
}

/// Review Focus 1. Two guarantees, and the second matters more than the first:
/// the faces should be registered, and if they are ever not, nothing breaks.
final class FontRegistrationTests: XCTestCase {

    func testDisplayFaceIsRegistered() {
        XCTAssertTrue(
            Typography.displayAvailable,
            "\(Typography.displayFace) is not registered. Check the .ttf is in "
            + "Resources/Fonts and listed under UIAppFonts in project.yml."
        )
    }

    func testNumberFaceIsRegistered() {
        XCTAssertTrue(
            Typography.numberAvailable,
            "\(Typography.numberFace) is not registered."
        )
    }

    /// `Typography.number` picks this face by name for semibold and heavier. If the
    /// file is missing, every bold numeral drops to the system face without a word.
    func testNumberBoldFaceIsRegistered() {
        XCTAssertTrue(
            Typography.numberBoldAvailable,
            "\(Typography.numberBoldFace) is not registered. Check it is listed under "
            + "UIAppFonts in project.yml; bold numerals fall back to the system face without it."
        )
    }

    /// The fallback path must produce a usable font, not a crash and not a zero
    /// size. This exercises it directly rather than trusting that it compiles.
    func testEveryAccessorReturnsAUsableFontForEveryStyle() {
        let styles: [Font.TextStyle] = [
            .largeTitle, .title, .title2, .title3, .headline,
            .subheadline, .body, .callout, .footnote, .caption, .caption2,
        ]
        for style in styles {
            XCTAssertGreaterThan(style.baseSize, 0, "\(style) has no base size")
            _ = Typography.ui(style)
            _ = Typography.label(style)
            _ = Typography.number(style)
        }
        _ = Typography.display(40)
    }

    /// Both numeral faces: a bold readout that changes while you watch it must not
    /// jitter its layout any more than a regular one.
    func testTabularFiguresAreOnForNumerals() {
        for face in [Typography.numberFace, Typography.numberBoldFace] {
            guard let font = UIFont(name: face, size: 17) else {
                XCTFail("numeral face \(face) missing")
                continue
            }
            let wide = ("1111" as NSString).size(withAttributes: [.font: font])
            let narrow = ("8888" as NSString).size(withAttributes: [.font: font])
            XCTAssertEqual(
                wide.width, narrow.width, accuracy: 0.5,
                "\(face) numerals are not tabular; a changing readout will jitter its layout"
            )
        }
    }
}

final class ThemeTests: XCTestCase {

    func testFullDaylightIsTheDayPalette() {
        XCTAssertEqual(Theme.nightFraction(for: 1), 0, accuracy: 0.0001)
    }

    func testTheNightFloorIsReachedAtThePointThreeFiveMark() {
        XCTAssertEqual(Theme.nightFraction(for: 0.35), 1, accuracy: 0.0001)
    }

    func testMidDuskIsPartway() {
        let t = Theme.nightFraction(for: 0.675)
        XCTAssertGreaterThan(t, 0.4)
        XCTAssertLessThan(t, 0.6)
    }

    /// Review Focus 3. `SiteModifiers.lightLevel` is a Float that charms and set
    /// perks multiply, so it can leave 0...1 in either direction.
    func testOutOfRangeLightLevelsClampInsteadOfOvershooting() {
        for level in [Float(-5), -0.001, 0, 0.1, 0.35, 1, 1.0001, 3, .infinity] {
            let t = Theme.nightFraction(for: level)
            XCTAssertGreaterThanOrEqual(t, 0, "lightLevel \(level) produced \(t)")
            XCTAssertLessThanOrEqual(t, 1, "lightLevel \(level) produced \(t)")
        }
    }

    /// Carried forward from Task 2's review. Task 2 pins each site's matrix
    /// against the mount at full daylight — but night_dig renders at
    /// `lightLevel` 0.55, and `SlabRenderer` scales every cell by it, so the
    /// colour Task 2 measured for that site never reaches a screen. On screen
    /// the matrix is (123, 112, 91) against the night mount, s8, which is 3.56:1.
    /// That clears 3:1 by about half a point, the kind of margin that regresses
    /// silently when someone nudges `nightFloor` or `switchPoint`.
    ///
    /// The mount is read from the palette `Theme` actually selects. It is s6 on
    /// the day palette and s8 on the night one, never a blend, so a model that
    /// lerped between them would overstate the contrast of any dim site on the
    /// day side of the switch (the default matrix at lightLevel 0.70 is 4.23 as
    /// a blend and 3.28 as shipped).
    ///
    /// Iterates the catalog, like Task 2's test: no night_dig literal, so a
    /// second dim site added later is covered.
    func testEverySiteMatrixSeparatesFromTheMountAtItsOwnLightLevel() {
        for site in ContentCatalog.shared.sites {
            let level = site.modifiers.lightLevel
            let theme = Theme()
            theme.lightLevel = level
            let onScreen = site.palette.matrix.scaled(level)
            let ratio = onScreen.contrastRatio(against: rgb8(of: theme.ink.mount))
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "site '\(site.id)' at lightLevel \(level): slab and mount converge (\(ratio))"
            )
        }
    }

    func testNaNLightLevelFallsBackToDaylight() {
        XCTAssertEqual(Theme.nightFraction(for: .nan), 0, accuracy: 0.0001)
    }

    func testSettingLightLevelUpdatesTheInk() {
        let theme = Theme()
        XCTAssertEqual(theme.ink, Ink.day)
        theme.lightLevel = 0.2
        XCTAssertEqual(theme.ink, Ink.night)
        theme.lightLevel = 1
        XCTAssertEqual(theme.ink, Ink.day)
    }

    /// The palette is only ever one of the two presets. A blended palette would
    /// put text and page at 1.09:1 in the middle; this asserts no third value
    /// can reach a screen, at any light level a site could hold.
    func testNoIntermediatePaletteIsEverProduced() {
        let theme = Theme()
        for step in 0...100 {
            theme.lightLevel = Float(step) / 100
            XCTAssertTrue(
                theme.ink == Ink.day || theme.ink == Ink.night,
                "lightLevel \(theme.lightLevel) produced a blended palette"
            )
        }
    }

    /// The game's only dim site must land on the night palette, not near the
    /// crossover. night_dig is lightLevel 0.55 -> nightFraction 0.69.
    func testTheOneNightSiteLandsOnTheNightPalette() {
        let site = ContentCatalog.shared.site("night_dig")
        XCTAssertNotNil(site, "night_dig left the catalog; update this test")
        let theme = Theme()
        theme.lightLevel = site!.modifiers.lightLevel
        XCTAssertEqual(theme.ink, Ink.night)
    }

    /// `@Entry` expands its initial value into a computed `defaultValue`, so an inline
    /// `Theme()` is built again on every read of an environment that was never given
    /// one: whatever was set on one read is gone on the next, and every dependent view
    /// sees a different object each time. The compiler warns about it; this pins the fix.
    func testTheEnvironmentDefaultIsOneInstanceNotOnePerRead() {
        let environment = EnvironmentValues()
        XCTAssertTrue(environment.theme === environment.theme)
        XCTAssertTrue(EnvironmentValues().theme === EnvironmentValues().theme)
    }

    private func rgb8(of colour: Color) -> RGB8 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB8(
            UInt8((red * 255).rounded()),
            UInt8((green * 255).rounded()),
            UInt8((blue * 255).rounded())
        )
    }
}
