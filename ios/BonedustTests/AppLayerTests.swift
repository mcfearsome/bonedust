@testable import BonedustCore
import SpriteKit
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
        XCTAssertTrue(sweepUntilBoneShows(subject), "the sweep never reached bone")
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
        XCTAssertTrue(sweepUntilIdentified(subject), "nothing worth valuing was exposed")
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
    ///
    /// The three accents are text too, and they are drawn on `raised` as well as on the page:
    /// the result card's total is `stamp` on it and the cash figure in the pill is `safe`.
    /// `EarthRampTests` measures the accents against the page only, and this table once
    /// stopped at `ink` and `muted`, so nothing held that pair. `stampNight` on night's `raised`
    /// (s7) is 4.72:1, the thinnest margin in the app.
    func testTextColoursClearAAOnTheirOwnSurfaces() {
        for (palette, ink) in [("day", Ink.day), ("night", Ink.night)] {
            let texts = [
                ("ink", ink.ink), ("muted", ink.muted),
                ("stamp", ink.stamp), ("gem", ink.gem), ("safe", ink.safe),
            ]
            for (textName, text) in texts {
                for (surfaceName, surface) in [("page", ink.page), ("raised", ink.raised)] {
                    let ratio = rgb8(of: text).contrastRatio(against: rgb8(of: surface))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5, "\(palette).\(textName) on \(palette).\(surfaceName) is \(ratio):1"
                    )
                }
            }
        }
    }

    /// The mount's whole job is to stop the slab vanishing into the page, and nothing measured
    /// that pair. The night mount was `s8` on `nightPage`: 1.15:1, so a night dig had no band at
    /// all, only a 1pt hairline at 2.4:1, and the page, the mount and uncleared topsoil sat
    /// within 1.15:1 of each other. The matrix-against-mount tests stayed green throughout, and
    /// choosing `s8` had improved that pair (3.12 to 3.56), which is how it shipped.
    ///
    /// 3:1, the bar the matrix pair holds, in both palettes: the mount is dark on cream by day
    /// and cream on the night page by night, so one palette's pass says nothing of the other.
    func testTheMountSeparatesFromThePageInBothPalettes() {
        for (palette, ink) in [("day", Ink.day), ("night", Ink.night)] {
            let ratio = rgb8(of: ink.mount).contrastRatio(against: rgb8(of: ink.page))
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(palette): the mount is \(String(format: "%.2f", ratio)):1 against the page, so the slab's card has no edge"
            )
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
    /// the matrix is (123, 112, 91) against the night mount, s1, which is 3.85:1.
    /// That clears 3:1 by under a point, the kind of margin that regresses
    /// silently when someone nudges `nightFloor` or `switchPoint`. (The night
    /// mount was s8 until its pair with the page was measured: 3.56:1 here, and
    /// 1.15:1 against the page. See `testTheMountSeparatesFromThePageInBothPalettes`.)
    ///
    /// The mount is read from the palette `Theme` actually selects. It is s6 on
    /// the day palette and s1 on the night one, never a blend, so a model that
    /// lerped between them would misreport any dim site on the day side of the
    /// switch (the default matrix at lightLevel 0.70 is 3.28 as shipped).
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

/// The scene's page furniture.
///
/// Most of this is visual, so these tests render the real scene offscreen through
/// `SKView.texture(from:)` and read pixels back, instead of asserting on node
/// properties alone: a node can have exactly the right `zPosition` and still be
/// invisible, which is how the mount first came out.
@MainActor
final class DigSceneBackdropTests: XCTestCase {

    private let sceneSize = CGSize(width: 361, height: 481)

    /// `SKScene.view` is weak, so the view has to outlive the test body.
    private func present(
        size: CGSize? = nil, engine: DigEngine? = nil, theme: Theme? = nil
    ) -> (scene: DigScene, view: SKView) {
        let size = size ?? sceneSize
        let view = SKView(frame: CGRect(origin: .zero, size: size))
        let scene = DigScene(size: size)
        scene.engine = engine
        scene.theme = theme
        view.presentScene(scene)
        return (scene, view)
    }

    /// `DigScene.engine` is weak: the caller keeps the engine alive.
    private func engine(_ siteID: String) -> DigEngine {
        let site = ContentCatalog.shared.site(siteID) ?? ContentCatalog.shared.sites[0]
        return DigEngine(seed: 4242, site: site)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let i = (y * width + x) * 4
            return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
        }
    }

    /// The scene as SpriteKit draws it. Row 0 is the top row of the screen.
    private func render(_ scene: DigScene, in view: SKView) throws -> Pixels {
        let texture = try XCTUnwrap(
            view.texture(from: scene), "SpriteKit would not render the scene"
        )
        let image = texture.cgImage()
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the rendered scene back")
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func rgb(_ colour: UIColor) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }

    private func rgb(_ colour: Color) -> [Int] { rgb(UIColor(colour)) }

    /// Metal and an sRGB readback move a channel by a level or two, so a pixel is
    /// compared with a small tolerance rather than exactly.
    private func assertPixel(
        _ actual: [Int], is expected: [Int], _ what: String, tolerance: Int = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let close = zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
        XCTAssertTrue(
            close, "\(what): drew \(actual), expected \(expected)", file: file, line: line
        )
    }

    private func distance(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +)
    }

    // MARK: Layers

    func testTheMountSitsOneLayerBehindTheSlab() {
        let (scene, _) = present()
        scene.buildBackdrop()
        XCTAssertEqual(scene.mountNode?.zPosition, -1)
        XCTAssertEqual(scene.slabNode?.zPosition, 0)
    }

    /// A rebuild replaces the mount. A leak here would stack a node per resize, and the
    /// count also pins that the scene no longer carries the page's grid and paper: those
    /// moved to `NotebookPage`, because behind an opaque mount nobody could see them.
    func testResizingRebuildsTheBackdropInsteadOfStackingIt() {
        let (scene, _) = present()
        for width in [390, 768, 1024] {
            scene.size = CGSize(width: width, height: width * 4 / 3)
        }
        XCTAssertEqual(scene.children.count, 2, "the mount and the slab, and nothing left from an earlier size")
    }

    // MARK: Mount

    /// The scene is exactly the slab's card, and an `SKView` draws nothing past its
    /// edge. A mount that "extends past" a full-size slab is clipped away, so the
    /// slab is inset and the mount fills what it leaves.
    func testTheMountIsAVisibleBandMountMarginWideOnEveryEdge() throws {
        let (scene, _) = present()
        for size in [sceneSize, CGSize(width: 768, height: 1024)] {
            scene.size = size
            let slab = try XCTUnwrap(scene.slabNode).frame
            let mount = try XCTUnwrap(scene.mountNode).frame
            let margin = Measure.mountMargin

            XCTAssertTrue(
                CGRect(origin: .zero, size: size).contains(mount),
                "mount \(mount) is not inside the \(size) scene, so the view would clip it"
            )
            XCTAssertEqual(slab.minX - mount.minX, margin, accuracy: 0.001)
            XCTAssertEqual(mount.maxX - slab.maxX, margin, accuracy: 0.001)
            XCTAssertEqual(slab.minY - mount.minY, margin, accuracy: 0.001)
            XCTAssertEqual(mount.maxY - slab.maxY, margin, accuracy: 0.001)
        }
    }

    /// Brushes the slab until it is almost entirely cleared, so what is on screen is
    /// the pale `matrix` layer. Every site's topsoil is dark, close to the mount's own
    /// colour, so a fresh slab proves nothing about the band.
    private func clear(_ engine: DigEngine) {
        _ = engine.brushBegan(at: Vec2(1, 1))
        for _ in 0..<80 {
            var y: Float = 1
            var direction: Float = 1
            while y < 127 {
                var x: Float = direction > 0 ? 1 : 95
                while x > 0 && x < 96 {
                    _ = engine.brushMoved(to: Vec2(x, y), deltaMillis: 16)
                    x += direction * 1.5
                }
                y += 3
                direction = -direction
            }
            engine.publish()
            if engine.exposurePercent >= 95 { break }
        }
        engine.brushEnded()
    }

    /// The case the mount exists for, as it reaches a screen: a cleared slab is pale,
    /// and green_river's matrix sits at 1.09:1 against the cream page. The slab is
    /// uploaded, so it is opaque. If the mount were hidden or clipped, the pixel 3pt
    /// in from each edge would be pale slab, not mount. Day and night, because the
    /// mount is a different colour in each.
    func testTheMountShowsAsABandAroundAClearedSlabOnScreen() throws {
        for (siteID, ink) in [("green_river", Ink.day), ("night_dig", Ink.night)] {
            let subject = engine(siteID)
            clear(subject)
            XCTAssertGreaterThanOrEqual(subject.exposurePercent, 95, "\(siteID) did not clear")
            let (scene, view) = present(engine: subject, theme: Theme())
            scene.update(1)
            let pixels = try render(scene, in: view)
            let scale = pixels.width / Int(sceneSize.width)
            let middle = (x: pixels.width / 2, y: pixels.height / 2)
            let band = 3 * scale
            let mount = rgb(ink.mount)

            assertPixel(pixels.rgb(band, middle.y), is: mount, "\(siteID), left band")
            assertPixel(pixels.rgb(pixels.width - 1 - band, middle.y), is: mount, "\(siteID), right band")
            assertPixel(pixels.rgb(middle.x, band), is: mount, "\(siteID), top band")
            assertPixel(pixels.rgb(middle.x, pixels.height - 1 - band), is: mount, "\(siteID), bottom band")

            let inside = pixels.rgb(9 * scale, middle.y)
            XCTAssertGreaterThan(
                distance(inside, mount), 100,
                "\(siteID): 9pt in is \(inside), which is the mount again; the cleared slab is not drawn over it"
            )
        }
    }

    // MARK: Page and theme

    func testThePageBehindTheSlabIsCreamNotDarkUmber() throws {
        let (scene, view) = present()
        scene.buildBackdrop()
        scene.mountNode?.isHidden = true
        scene.slabNode?.isHidden = true
        let pixels = try render(scene, in: view)
        assertPixel(
            pixels.rgb(pixels.width / 2, pixels.height / 2), is: rgb(Ink.day.page),
            "the page", tolerance: 2
        )
        // The raw literal this replaced.
        XCTAssertGreaterThan(distance(pixels.rgb(0, 0), [0x22, 0x18, 0x13]), 100)
    }

    func testApplyThemeRepaintsThePageAndTheMount() throws {
        let (scene, _) = present()
        scene.buildBackdrop()
        for ink in [Ink.night, Ink.day] {
            scene.applyTheme(ink: ink)
            XCTAssertEqual(rgb(scene.backgroundColor), rgb(ink.page))
            XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(ink.mount))
        }
    }

    /// The backdrop is rebuilt on every resize. If the rebuild read the day palette
    /// instead of the one last applied, a night dig would flip its mount back to
    /// day colours the first time the view changed size.
    func testAResizeKeepsThePaletteTheSceneWasPaintedIn() throws {
        let (scene, _) = present()
        scene.buildBackdrop()
        scene.applyTheme(ink: .night)
        scene.size = CGSize(width: 768, height: 1024)
        XCTAssertEqual(rgb(scene.backgroundColor), rgb(Ink.night.page))
        XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(Ink.night.mount))
    }

    /// `lightLevel` is static per site: set once in `configureRenderer()`, with
    /// nothing observing it. Iterates the catalog so a second dim site is covered.
    func testConfigureRendererSetsTheThemeFromTheSitesLightLevelAndRepaints() throws {
        for site in ContentCatalog.shared.sites {
            let subject = DigEngine(seed: 1, site: site)
            let theme = Theme()
            let (scene, _) = present(engine: subject, theme: theme)
            XCTAssertEqual(theme.lightLevel, site.modifiers.lightLevel, "site '\(site.id)'")
            XCTAssertEqual(
                rgb(scene.backgroundColor), rgb(theme.ink.page),
                "site '\(site.id)': the page is not in the palette the theme chose"
            )
            XCTAssertEqual(
                rgb(try XCTUnwrap(scene.mountNode).color), rgb(theme.ink.mount),
                "site '\(site.id)': the mount is not in the palette the theme chose"
            )
        }
    }

    /// The debug overlay calls `configureRenderer()` again, and a different site can
    /// follow a night one, so the page must follow the engine, not only the first call.
    func testTheNightSiteDarkensThePageAndTheNextDaySiteBringsItBack() throws {
        XCTAssertNotNil(ContentCatalog.shared.site("night_dig"), "night_dig left the catalog; update this test")
        let night = engine("night_dig")
        let day = engine("charmouth")
        let theme = Theme()
        let (scene, _) = present(engine: night, theme: theme)
        XCTAssertEqual(theme.ink, Ink.night)
        XCTAssertEqual(rgb(scene.backgroundColor), rgb(Ink.night.page))

        scene.engine = day
        scene.configureRenderer()
        XCTAssertEqual(theme.ink, Ink.day)
        XCTAssertEqual(rgb(scene.backgroundColor), rgb(Ink.day.page))
        XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(Ink.day.mount))
    }

    func testWithoutAThemeTheSceneStaysOnTheDayPalette() throws {
        let night = engine("night_dig")
        let (scene, _) = present(engine: night, theme: nil)
        scene.configureRenderer()
        XCTAssertEqual(rgb(scene.backgroundColor), rgb(Ink.day.page))
        XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(Ink.day.mount))
    }

    // MARK: Fracture bloom

    /// Where a grid point lands in the scene, worked out from the slab's own frame
    /// rather than from `emitDust`'s formula. The bloom is held to the thing it has to
    /// line up with, not to a second copy of the arithmetic that placed it.
    private func scenePoint(forGrid point: Vec2, in scene: DigScene) throws -> CGPoint {
        let frame = try XCTUnwrap(scene.slabNode).frame
        return CGPoint(
            x: frame.minX + CGFloat(point.x) / CGFloat(SlabGrid.width) * frame.width,
            y: frame.maxY - CGFloat(point.y) / CGFloat(SlabGrid.height) * frame.height
        )
    }

    private func blooms(in scene: DigScene) -> [SKShapeNode] {
        (scene.slabNode?.children ?? []).compactMap { $0 as? SKShapeNode }
    }

    /// The bloom is 4pt across at birth and Task 6 inset the slab by `mountMargin`, so a
    /// bloom positioned against the *scene* sits 6pt off at the corners and misses its
    /// cell entirely. This renders the scene and reads the pixel where the cell is.
    ///
    /// What it does not cover is how the bloom looks: its size, softness and timing are
    /// judged by eye. This pins where it lands and that it is drawn at all.
    func testTheBloomIsDrawnOnTheGridPointItWasFiredAt() throws {
        let subject = engine("green_river")
        let (scene, view) = present(engine: subject, theme: Theme())
        scene.update(1)

        for point in [Vec2(0, 0), Vec2(96, 128), Vec2(0, 128), Vec2(96, 0), Vec2(48, 64)] {
            let before = try render(scene, in: view)
            scene.bloomFracture(at: point)
            XCTAssertEqual(blooms(in: scene).count, 1, "bloom at \(point)")
            let after = try render(scene, in: view)
            blooms(in: scene).forEach { $0.removeFromParent() }

            let scale = after.width / Int(sceneSize.width)
            let at = try scenePoint(forGrid: point, in: scene)
            let x = Int((at.x * CGFloat(scale)).rounded())
            let y = Int(((sceneSize.height - at.y) * CGFloat(scale)).rounded())

            // 0.9 alpha of the stamp over whatever was already there.
            let stamp = [Int(Earth.stamp.r), Int(Earth.stamp.g), Int(Earth.stamp.b)]
            let expected = zip(stamp, before.rgb(x, y)).map {
                Int((0.9 * Double($0) + 0.1 * Double($1)).rounded())
            }
            assertPixel(
                after.rgb(x, y), is: expected, "bloom at grid \(point.x), \(point.y)",
                tolerance: 6
            )
            XCTAssertGreaterThan(
                distance(after.rgb(x, y), before.rgb(x, y)), 40,
                "grid \(point.x), \(point.y): nothing was drawn there, so the check above proves nothing"
            )

            // And it is a 4pt dot, not a wash: well away from it the scene is untouched.
            let awayX = x + (x < after.width / 2 ? 12 : -12) * scale
            let awayY = y + (y < after.height / 2 ? 12 : -12) * scale
            XCTAssertLessThanOrEqual(
                distance(after.rgb(awayX, awayY), before.rgb(awayX, awayY)), 3,
                "grid \(point.x), \(point.y): the bloom reached 12pt from its centre"
            )
        }
    }

    /// What a bloom did, read back once it had finished.
    private struct PlayedBloom {
        let node: SKShapeNode
        /// Read while the bloom was still on the slab.
        let scheduledDuration: TimeInterval
        let removedItself: Bool
    }

    /// Fires a bloom with `fire` and lets it run to the end.
    ///
    /// SpriteKit only advances actions while the view is on screen, so this puts the
    /// view in a window and runs the loop until the bloom has gone. It puts no clock on
    /// the fade: the first frame can arrive a few hundred milliseconds late, which would
    /// make any wall-clock bound flaky.
    ///
    /// The node comes back so a test can read what the actions did to it. An `SKAction`
    /// cannot be inspected, but a finished node keeps what its actions left: a scale
    /// action ends on its target and a fade ends at alpha 0, however late any frame was.
    private func playBloom(
        in scene: DigScene, view: SKView, fire: (DigScene) -> Void
    ) throws -> PlayedBloom {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene, so SpriteKit's clock cannot run"
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: sceneSize)
        window.addSubview(view)
        window.isHidden = false
        defer {
            view.presentScene(nil)
            window.isHidden = true
        }

        fire(scene)
        let bloom = try XCTUnwrap(blooms(in: scene).first)
        let fade = try XCTUnwrap(bloom.action(forKey: DigScene.bloomActionKey))

        let deadline = Date().addingTimeInterval(3)
        while !blooms(in: scene).isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return PlayedBloom(
            node: bloom, scheduledDuration: fade.duration, removedItself: blooms(in: scene).isEmpty
        )
    }

    /// A bloom is meant to be gone in 200ms, and one that never left would pile up a
    /// shape node on the slab for every fracture of a long session. The 200ms is pinned
    /// on the action itself rather than on a clock; see `playBloom`.
    func testTheBloomRemovesItselfAndIsScheduledForTwoHundredMilliseconds() throws {
        let (scene, view) = present()
        let played = try playBloom(in: scene, view: view) {
            $0.bloomFracture(at: Vec2(48, 64), systemReduceMotion: false)
        }
        XCTAssertEqual(
            played.scheduledDuration, 0.2, accuracy: 0.001, "the bloom is meant to be gone in 200ms"
        )
        XCTAssertTrue(played.removedItself, "the bloom never left the slab")
    }

    /// The control for the Reduce Motion test below. A finished bloom keeps the scale its
    /// action left it at, so this shows the readback can see a scale action at all. Without
    /// it, `xScale == 1` under Reduce Motion would also pass if the readback were blind.
    func testTheBloomGrowsToFiveTimesItsSizeWhenMotionIsNotReduced() throws {
        let (scene, view) = present()
        scene.reducedMotion = false
        let played = try playBloom(in: scene, view: view) {
            $0.bloomFracture(at: Vec2(48, 64), systemReduceMotion: false)
        }
        XCTAssertTrue(played.removedItself, "the bloom never left the slab")
        XCTAssertEqual(played.node.xScale, 5, accuracy: 0.001)
        XCTAssertEqual(played.node.yScale, 5, accuracy: 0.001)
        XCTAssertEqual(played.node.alpha, 0, accuracy: 0.001)
    }

    /// Spec §5 and Reduce Motion. An expanding shape at the point of attention is what the
    /// setting exists to suppress, so the bloom fades where it stands: still there, still
    /// red, still gone in 200ms, never any bigger than it was born. The permanent hatch
    /// carries the information either way.
    ///
    /// Both sources are driven separately, because either one alone must be enough: the
    /// system flag is read live, and the scene's own flag is the in-app toggle.
    func testUnderReduceMotionTheBloomFadesInPlaceAndNeverGrows() throws {
        for (name, sceneFlag, systemFlag) in [
            ("the system setting", false, true),
            ("the in-app toggle", true, false),
        ] {
            let (scene, view) = present()
            scene.reducedMotion = sceneFlag
            let played = try playBloom(in: scene, view: view) {
                $0.bloomFracture(at: Vec2(48, 64), systemReduceMotion: systemFlag)
            }
            XCTAssertTrue(played.removedItself, "\(name): the bloom never left the slab")
            XCTAssertEqual(
                played.node.alpha, 0, accuracy: 0.001,
                "\(name): the fade did not run, so the scale check below proves nothing"
            )
            XCTAssertEqual(played.node.xScale, 1, "\(name): the bloom grew under Reduce Motion")
            XCTAssertEqual(played.node.yScale, 1, "\(name): the bloom grew under Reduce Motion")
            XCTAssertEqual(
                played.scheduledDuration, 0.2, accuracy: 0.001,
                "\(name): the reduced bloom is still 200ms"
            )
        }
    }

    /// `apply` fires the bloom with no argument, so the live system setting is what it
    /// gets. The suite cannot flip that setting, so this asserts whichever state the run
    /// is in; a default of `false` would only be caught with Reduce Motion switched on in
    /// the simulator's Settings.
    func testTheDefaultBloomFollowsTheSystemSetting() throws {
        let (scene, view) = present()
        scene.reducedMotion = false
        let played = try playBloom(in: scene, view: view) { $0.bloomFracture(at: Vec2(48, 64)) }
        let reduced = UIAccessibility.isReduceMotionEnabled
        XCTAssertEqual(
            played.node.xScale, reduced ? 1 : 5, accuracy: 0.001,
            "Reduce Motion is \(reduced ? "on" : "off")"
        )
    }

    /// `StrokeResult.cracksStarted` is the signal `DigEngine` already uses for
    /// `hasCracked`. If the one line that fires the bloom is deleted, the scene still
    /// builds and every other test still passes, so this drives `apply` directly.
    func testACrackBloomsAndAStrokeWithoutOneDoesNot() throws {
        let subject = engine("green_river")
        let (scene, _) = present(engine: subject, theme: Theme())

        scene.apply(StrokeResult(), at: Vec2(48, 64), engine: subject)
        XCTAssertEqual(blooms(in: scene).count, 0, "an uneventful stroke must not bloom")

        var fractured = StrokeResult()
        fractured.cracksStarted = 1
        scene.apply(fractured, at: Vec2(48, 64), engine: subject)
        XCTAssertEqual(blooms(in: scene).count, 1, "a fracture must bloom exactly once")
    }
}

extension SlabRenderer {
    /// One pixel of the rendered buffer, for tests that want to see what `colour()` decided.
    fileprivate func pixel(_ x: Int, _ y: Int) -> RGB8 {
        let offset = (y * SlabGrid.width + x) * SlabRenderer.bytesPerPixel
        return RGB8(pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }
}

/// Fracture leaves a record on the page: a diagonal hatch over every cracked cell. The
/// transient red bloom is the alarm, this is the annotation that stays. Spec §5.
final class FractureHatchTests: XCTestCase {

    /// The hatch is a 2-on-2-off diagonal, so two cells on the same diagonal band
    /// render identically and two on adjacent bands do not. Testing the *pattern*
    /// rather than an exact colour means a palette change does not break this.
    func testHatchAlternatesAcrossDiagonalBands() {
        XCTAssertTrue(SlabRenderer.isHatched(x: 0, y: 0))
        XCTAssertTrue(SlabRenderer.isHatched(x: 1, y: 0))
        XCTAssertFalse(SlabRenderer.isHatched(x: 2, y: 0))
        XCTAssertFalse(SlabRenderer.isHatched(x: 3, y: 0))
        XCTAssertTrue(SlabRenderer.isHatched(x: 4, y: 0))
    }

    func testHatchRunsDiagonallyNotVertically() {
        // Moving one step down-right stays in the same band.
        XCTAssertEqual(
            SlabRenderer.isHatched(x: 5, y: 5),
            SlabRenderer.isHatched(x: 6, y: 4)
        )
    }

    /// Both cells in the test above are "off", so on its own it would also pass for a
    /// horizontal stripe. This walks every cell of a patch, on both kinds of band, and
    /// also requires that the pattern is not a flat fill.
    func testEveryCellOnADiagonalSharesItsBand() {
        for y in 0..<16 {
            for x in 0..<16 {
                XCTAssertEqual(
                    SlabRenderer.isHatched(x: x, y: y),
                    SlabRenderer.isHatched(x: x + 1, y: y - 1),
                    "(\(x), \(y)) and (\(x + 1), \(y - 1)) are on different bands"
                )
            }
        }
        let bands = (0..<8).map { SlabRenderer.isHatched(x: $0, y: 0) }
        XCTAssertTrue(bands.contains(true) && bands.contains(false), "the hatch is a flat fill")
    }

    func testCrackedBoneIsDarkenedOnHatchedColumnsOnly() {
        let palette = SlabPalette.standard
        let on = SlabRenderer.hatched(palette.crackedBone, x: 0, y: 0)
        let off = SlabRenderer.hatched(palette.crackedBone, x: 2, y: 0)
        XCTAssertEqual(off, palette.crackedBone, "unhatched cells must be untouched")
        XCTAssertLessThan(
            on.relativeLuminance, off.relativeLuminance,
            "hatched cells must be darker, or the hatch is invisible"
        )
    }

    /// The tests above cover the helpers. Nothing in them would notice if `colour()`
    /// stopped calling one, or called it on the wrong cells, so this renders a patch of
    /// bone through the real pipeline: left half cracked, right half intact.
    ///
    /// Noise is zero, so the hatch is the only thing that can move a pixel. Only the
    /// patch's interior is sampled, because its rim belongs to the renderer's edge
    /// treatment, not to this feature.
    func testTheRendererHatchesCrackedBoneAndLeavesIntactBoneAlone() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        for y in 20..<40 {
            for x in 20..<40 {
                var flags = SlabGrid.Flag.bone
                if x < 30 { flags |= SlabGrid.Flag.cracked }
                grid[x, y] = SlabGrid.Cell(depth: 0, flags: flags, wear: 0, noise: 0)
            }
        }
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        var hatchedCells = 0
        var plainCells = 0
        for y in 22..<38 {
            for x in 22..<28 {
                let drawn = renderer.pixel(x, y)
                if SlabRenderer.isHatched(x: x, y: y) {
                    hatchedCells += 1
                    XCTAssertEqual(drawn, SlabRenderer.hatched(palette.crackedBone, x: x, y: y),
                                   "cracked cell (\(x), \(y)) is on a hatch stripe and was not hatched")
                    XCTAssertLessThan(drawn.relativeLuminance, palette.crackedBone.relativeLuminance)
                } else {
                    plainCells += 1
                    XCTAssertEqual(drawn, palette.crackedBone,
                                   "cracked cell (\(x), \(y)) is between stripes and was changed")
                }
            }
            for x in 32..<38 {
                XCTAssertEqual(renderer.pixel(x, y), palette.bone,
                               "intact bone at (\(x), \(y)) took the hatch")
            }
        }
        XCTAssertGreaterThan(hatchedCells, 0, "no sampled cell was on a stripe")
        XCTAssertGreaterThan(plainCells, 0, "every sampled cell was on a stripe")
    }
}

/// Spec §7 and §7a. The slab was already four discrete palette colours per layer, and the
/// renderer smeared them with continuous operations. The cel pass steps those operations
/// and adds a real edge. One rule governs all of it: quantize the lighting, never the
/// albedo. Every palette value comes through exact; only the shade multiplier steps.
final class CelShadingTests: XCTestCase {

    private func packed(_ colour: RGB8) -> UInt32 {
        UInt32(colour.r) << 16 | UInt32(colour.g) << 8 | UInt32(colour.b)
    }

    private func distance(_ a: RGB8, _ b: RGB8) -> Int {
        abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
    }

    private func fill(
        _ grid: inout SlabGrid, x: Range<Int>, y: Range<Int>, with cell: SlabGrid.Cell
    ) {
        for row in y {
            for column in x { grid[column, row] = cell }
        }
    }

    private func exposedBone(extra: UInt8 = 0) -> SlabGrid.Cell {
        SlabGrid.Cell(depth: 0, flags: SlabGrid.Flag.bone | extra, wear: 0, noise: 0)
    }

    // MARK: The helpers

    /// The stipple is a 1-in-4 grid of isolated dots. Isolated matters: a 50%
    /// checkerboard averages back into a flat tint at this cell size.
    func testStippleIsAOneInFourGridOfIsolatedCells() {
        XCTAssertTrue(SlabRenderer.isStippled(x: 0, y: 0))
        XCTAssertFalse(SlabRenderer.isStippled(x: 1, y: 0))
        XCTAssertFalse(SlabRenderer.isStippled(x: 0, y: 1))
        XCTAssertTrue(SlabRenderer.isStippled(x: 2, y: 2))
        // No two stippled cells are orthogonally adjacent.
        var dots = 0
        for y in 0..<8 {
            for x in 0..<8 where SlabRenderer.isStippled(x: x, y: y) {
                dots += 1
                XCTAssertFalse(SlabRenderer.isStippled(x: x + 1, y: y))
                XCTAssertFalse(SlabRenderer.isStippled(x: x, y: y + 1))
            }
        }
        XCTAssertEqual(dots, 16, "one cell in four: 16 dots in an 8x8 patch")
    }

    /// Why the stipple is kept in reserve (§7a): it is a pattern, so a per-channel posterize
    /// would not erase it, while the same posterize at 6 levels erases a 20% tint. The shipped
    /// cel pass quantizes the lighting and leaves every palette value exact, so nothing
    /// posterizes the tint today and the tint is the default; this pins the property that
    /// makes the stipple a safe fallback if that ever changes.
    func testStippledTellSurvivesAPosterizeThatErasesTheTint() {
        let sandstone = SlabPalette.standard.sandstone
        let bone = SlabPalette.standard.bone

        func posterize(_ c: RGB8, _ levels: Int) -> RGB8 {
            let step = 255.0 / Double(levels - 1)
            func q(_ v: UInt8) -> UInt8 {
                UInt8(max(0, min(255, (Double(v) / step).rounded() * step)))
            }
            return RGB8(q(c.r), q(c.g), q(c.b))
        }

        let tinted = sandstone.lerp(to: bone, 0.20)
        XCTAssertEqual(
            posterize(tinted, 6), posterize(sandstone, 6),
            "if these ever differ, the tint survives posterizing and §7a's premise is wrong"
        )

        let stippled = sandstone.lerp(to: bone, 0.60)
        XCTAssertNotEqual(
            posterize(stippled, 6), posterize(sandstone, 6),
            "the stipple must stay visible under the same posterize"
        )
    }

    /// Shade steps; albedo does not. This is the hue-shift guard.
    func testCelShadeQuantizesToThreeStepsAndKeepsHue() {
        let amount = SimTuning.standard.cellNoise
        XCTAssertEqual(SlabRenderer.celShade(0.9, amount: amount), 1 - amount, accuracy: 0.0001)
        XCTAssertEqual(SlabRenderer.celShade(0.0, amount: amount), 1.0, accuracy: 0.0001)
        XCTAssertEqual(SlabRenderer.celShade(-0.9, amount: amount), 1 + amount, accuracy: 0.0001)

        // Three steps, not a ramp: every noise value lands on one of exactly three.
        let steps = Set(
            stride(from: Float(-1), through: 1, by: 0.05).map {
                SlabRenderer.celShade($0, amount: amount)
            }
        )
        XCTAssertEqual(steps.count, 3)

        // The amount is whatever the caller passes, not a value read from the shipped
        // defaults. The debug overlay's slider reaches the renderer through this argument.
        XCTAssertEqual(SlabRenderer.celShade(0.9, amount: 0.2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(SlabRenderer.celShade(0.9, amount: 0), 1, accuracy: 0.0001)

        // A scaled colour keeps its channel ratios; a posterized one does not.
        let topsoil = SlabPalette.standard.topsoil
        let shaded = topsoil.scaled(SlabRenderer.celShade(0.9, amount: amount))
        let ratioBefore = Double(topsoil.r) / Double(topsoil.g)
        let ratioAfter = Double(shaded.r) / Double(shaded.g)
        XCTAssertEqual(ratioBefore, ratioAfter, accuracy: 0.05, "cel shading shifted hue")
    }

    /// Moved here from Task 2, where it failed for the right reason: bone
    /// legibility has never come from fill contrast. green_river's bone sits at
    /// 1.14:1 against its own matrix — invisible — and the engine compensated with
    /// a +/-14% lit/shadowed rim, because at 96x128 "there is no room for an
    /// outline". The ink edge is that outline, and it must beat the rim it replaced
    /// on every site, not just the forgiving ones.
    ///
    /// The edge colour comes from `SlabRenderer.inked`, the function `colour()` calls,
    /// so a change to its strength is measured here rather than copied.
    ///
    /// Measured as the pixel reaches the screen. `colour()` scales every cell by the site's
    /// `lightLevel` after the edge is drawn, so on night_dig the bone, the edge and the matrix
    /// are all at 0.55. Measured unscaled this read 4.76:1 there while the shipped pixels were
    /// 2.78:1, under this bar, and the test stayed green: the same defect Task 2 had, which
    /// `testEverySiteMatrixSeparatesFromTheMountAtItsOwnLightLevel` exists because of. The cel
    /// pass then moves each cell a further 7% either way; this is the pairing it leaves alone.
    func testInkEdgeMakesBoneSeparateFromMatrixOnEverySite() {
        for site in ContentCatalog.shared.sites {
            let level = site.modifiers.lightLevel
            let matrix = site.palette.matrix.scaled(level)
            let bone = site.palette.bone
            let bare = bone.scaled(level).contrastRatio(against: matrix)
            let edged = SlabRenderer.inked(bone).scaled(level).contrastRatio(against: matrix)
            // The old relief: a lit top edge and a shadowed bottom edge, drawn before the
            // light level like the edge is. Whichever of the two was stronger is the one to beat.
            let rim = max(
                bone.scaled(1.12).scaled(level).contrastRatio(against: matrix),
                bone.scaled(0.86).scaled(level).contrastRatio(against: matrix)
            )
            let shown = String(format: "%.2f", edged)

            XCTAssertGreaterThanOrEqual(
                edged, 3.0,
                "site '\(site.id)' at lightLevel \(level): the ink edge does not separate bone from matrix (\(shown):1)"
            )
            XCTAssertGreaterThan(
                edged, bare,
                "site '\(site.id)' at lightLevel \(level): the ink edge is weaker than the bare fill it replaced"
            )
            XCTAssertGreaterThan(
                edged, rim,
                "site '\(site.id)' at lightLevel \(level): the ink edge (\(shown):1) is weaker than the relief it replaced"
            )
        }
    }

    /// Thin specimens keep an interior. green_river's twist is "the fish are
    /// paper", so a fossil two cells across must not be all outline.
    func testInkEdgeSkipsRunsShorterThanThreeCells() {
        XCTAssertFalse(SlabRenderer.inkEdge(runBehind: 1, neighbourDiffers: true))
        XCTAssertFalse(SlabRenderer.inkEdge(runBehind: 2, neighbourDiffers: true))
        XCTAssertTrue(SlabRenderer.inkEdge(runBehind: 3, neighbourDiffers: true))
        XCTAssertFalse(SlabRenderer.inkEdge(runBehind: 9, neighbourDiffers: false))
    }

    // MARK: Through the renderer

    /// A field of topsoil whose noise sweeps the whole -1...1 range. Three colours
    /// come out, and they are the palette's own topsoil at three brightnesses: if a
    /// channel were quantized instead, they would not be.
    func testTheSlabRendersThreeShadesOfALayerAndNoOtherColour() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        for y in 0..<SlabGrid.height {
            for x in 0..<SlabGrid.width {
                let noise = Float(x) / Float(SlabGrid.width - 1) * 2 - 1
                grid[x, y] = SlabGrid.Cell(depth: 3, flags: 0, wear: 0, noise: noise)
            }
        }
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        let amount = SimTuning.standard.cellNoise
        let expected = Set([
            palette.topsoil.scaled(1 - amount), palette.topsoil, palette.topsoil.scaled(1 + amount),
        ].map(packed))
        var seen = Set<UInt32>()
        for y in 0..<SlabGrid.height {
            for x in 0..<SlabGrid.width { seen.insert(packed(renderer.pixel(x, y))) }
        }
        XCTAssertEqual(seen, expected)
        XCTAssertEqual(seen.count, 3)
    }

    /// `colour()` once read `SimTuning.standard.cellNoise`, which would have made the debug
    /// overlay's Cell noise slider do nothing. The renderer's own tuning is what counts.
    func testTheShadeStepFollowsTheRenderersTuningNotTheShippedDefault() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        grid[10, 10] = SlabGrid.Cell(depth: 3, flags: 0, wear: 0, noise: 0.9)

        var renderer = SlabRenderer(palette: palette)
        renderer.tuning.cellNoise = 0.2
        renderer.redrawEverything(grid)
        XCTAssertEqual(renderer.pixel(10, 10), palette.topsoil.scaled(0.8))

        renderer.tuning.cellNoise = 0
        renderer.redrawEverything(grid)
        XCTAssertEqual(renderer.pixel(10, 10), palette.topsoil)
    }

    /// Wear still shows before a cell breaks through, in steps instead of a gradient.
    /// Sweeping wear across a row gives the unworn colour and exactly four steps toward
    /// the layer below, never stepping back.
    func testWearAdvancesInFourSteps() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        for x in 0..<SlabGrid.width {
            grid[x, 10] = SlabGrid.Cell(
                depth: 3, flags: 0, wear: Float(x) / Float(SlabGrid.width), noise: 0
            )
        }
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        let row = (0..<SlabGrid.width).map { renderer.pixel($0, 10) }
        XCTAssertEqual(Set(row.map(packed)).count, 5, "the unworn colour plus four wear steps")
        XCTAssertEqual(row.first, palette.topsoil)
        XCTAssertEqual(
            row.last, palette.topsoil.lerp(to: palette.clay, SimTuning.standard.wearColorBlend)
        )
        for index in 1..<row.count {
            XCTAssertGreaterThanOrEqual(
                distance(row[index], palette.topsoil), distance(row[index - 1], palette.topsoil),
                "wear stepped back toward the surface at column \(index)"
            )
        }
    }

    /// The tell ships as a tint, and the stipple, built and tested, stays one slider away.
    /// Spec §7a: on green_river the tint keeps a fin's rays readable and the stipple loses
    /// them. Both constants stay live and either one at zero gives the pure case, so this
    /// renders both directions: the tint as shipped, then the stipple from the sliders alone.
    func testTheTellShipsAsATintAndTheStippleStaysOneSliderAway() {
        XCTAssertEqual(SimTuning.standard.boneTellTint, 0.20, "ships as the tint")
        XCTAssertEqual(SimTuning.standard.boneTellStipple, 0, "with the stipple off")

        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 0..<SlabGrid.width, y: 0..<SlabGrid.height,
             with: SlabGrid.Cell(depth: 1, flags: 0, wear: 0, noise: 0))
        fill(&grid, x: 20..<40, y: 20..<40,
             with: SlabGrid.Cell(depth: 1, flags: SlabGrid.Flag.bone, wear: 0, noise: 0))

        // As shipped: a flat tint over the bone and nothing outside it.
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)
        let tint = palette.sandstone.lerp(to: palette.bone, SimTuning.standard.boneTellTint)
        for y in 18..<42 {
            for x in 18..<42 {
                let inside = (20..<40).contains(x) && (20..<40).contains(y)
                XCTAssertEqual(
                    renderer.pixel(x, y), inside ? tint : palette.sandstone, "cell (\(x), \(y))"
                )
            }
        }

        // One drag the other way: dots on their grid, and no tint under them.
        renderer.tuning.boneTellTint = 0
        renderer.tuning.boneTellStipple = 0.60
        renderer.redrawEverything(grid)
        let dot = palette.sandstone.lerp(to: palette.bone, 0.60)
        for y in 18..<42 {
            for x in 18..<42 {
                let inside = (20..<40).contains(x) && (20..<40).contains(y)
                let expected = inside && SlabRenderer.isStippled(x: x, y: y) ? dot : palette.sandstone
                XCTAssertEqual(renderer.pixel(x, y), expected, "stipple only, cell (\(x), \(y))")
            }
        }
    }

    /// Right and bottom only, so a thin specimen keeps its interior and the relief that
    /// used to light the top edge is gone: the left column and top row are plain bone.
    func testInkEdgeLandsOnTheRightAndBottomOfExposedBoneOnly() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 20..<30, y: 20..<30, with: exposedBone())
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        let edge = SlabRenderer.inked(palette.bone)
        XCTAssertGreaterThan(distance(edge, palette.bone), 100, "the edge must be visibly different")
        for y in 20..<30 {
            for x in 20..<30 {
                let expected = (x == 29 || y == 29) ? edge : palette.bone
                XCTAssertEqual(renderer.pixel(x, y), expected, "cell (\(x), \(y))")
            }
        }
    }

    /// A strip two cells tall has no bottom edge, because its run is under three, but it
    /// is long enough to cap its right end. The fish are paper; they must not be outline.
    func testAPaperThinSpecimenKeepsItsInterior() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 20..<32, y: 50..<52, with: exposedBone())
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        for y in 50..<52 {
            for x in 20..<31 {
                XCTAssertEqual(renderer.pixel(x, y), palette.bone, "interior cell (\(x), \(y)) was inked")
            }
            XCTAssertEqual(renderer.pixel(31, y), SlabRenderer.inked(palette.bone), "end cap (31, \(y))")
        }
    }

    /// Gems are 2x2 clusters, so every cell is under the three-cell run and none takes an
    /// edge. Pinned so the next person to enlarge a gem sees what the threshold does.
    func testAGemTwoCellsAcrossKeepsEveryCellOfItsColour() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 60..<62, y: 60..<62,
             with: SlabGrid.Cell(depth: 0, flags: SlabGrid.Flag.gem, wear: 0, noise: 0))
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)
        for y in 60..<62 {
            for x in 60..<62 { XCTAssertEqual(renderer.pixel(x, y), palette.gem, "gem cell (\(x), \(y))") }
        }
    }

    /// Fracture hatching and the ink edge are separate marks that can land on one cell.
    /// A cracked cell on the edge and on a stripe carries both, so it is darker than
    /// either alone. Deleting the relief must not take the hatch with it.
    func testACrackedCellOnTheEdgeCarriesTheHatchAndTheInk() {
        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 20..<30, y: 20..<30, with: exposedBone(extra: SlabGrid.Flag.cracked))
        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)

        let inked = SlabRenderer.inked(palette.crackedBone)
        var checked = 0
        for y in 22..<28 {
            let drawn = renderer.pixel(29, y)
            if SlabRenderer.isHatched(x: 29, y: y) {
                checked += 1
                XCTAssertLessThan(drawn.relativeLuminance, inked.relativeLuminance, "no hatch at (29, \(y))")
                XCTAssertLessThan(
                    drawn.relativeLuminance,
                    SlabRenderer.hatched(palette.crackedBone, x: 29, y: y).relativeLuminance,
                    "no ink at (29, \(y))"
                )
            } else {
                XCTAssertEqual(drawn, inked, "an edge cell between stripes at (29, \(y))")
            }
        }
        XCTAssertGreaterThan(checked, 0, "no sampled cell was on a stripe")
    }

    /// The ink edge asks how long the run behind a cell is, which reads two cells back.
    /// So exposing one cell can change the cell two ahead of it, one further than the
    /// dirty rect used to be inflated, and the third cell of a run is exactly what turns
    /// its end cap to ink. A stale pixel here is a seam left behind by digging.
    func testAnIncrementalRedrawCatchesAnEdgeTwoCellsFromTheChange() {
        let palette = SlabPalette.standard
        for vertical in [false, true] {
            let name = vertical ? "vertical" : "horizontal"
            func at(_ along: Int) -> (x: Int, y: Int) {
                vertical ? (60, 20 + along) : (20 + along, 50)
            }
            // Buried bone, then two exposed cells, then plain slab.
            var before = SlabGrid()
            before[at(0).x, at(0).y] = SlabGrid.Cell(depth: 1, flags: SlabGrid.Flag.bone, wear: 0, noise: 0)
            before[at(1).x, at(1).y] = exposedBone()
            before[at(2).x, at(2).y] = exposedBone()
            var after = before
            after[at(0).x, at(0).y].depth = 0

            var incremental = SlabRenderer(palette: palette)
            incremental.redrawEverything(before)
            var full = SlabRenderer(palette: palette)
            full.redrawEverything(after)
            let changed = at(2)
            XCTAssertNotEqual(
                incremental.pixel(changed.x, changed.y), full.pixel(changed.x, changed.y),
                "\(name): the change does not reach two cells away, so this proves nothing"
            )

            let origin = at(0)
            incremental.redraw(
                after, region: DirtyRegion(minX: origin.x, minY: origin.y, maxX: origin.x, maxY: origin.y)
            )
            var stale: [String] = []
            for y in 0..<SlabGrid.height {
                for x in 0..<SlabGrid.width where incremental.pixel(x, y) != full.pixel(x, y) {
                    stale.append("(\(x), \(y))")
                }
            }
            XCTAssertEqual(stale, [], "\(name): cells left stale by an incremental redraw")
        }
    }
}

// MARK: - The migrated views

/// A SwiftUI view as pixels, read back through `ImageRenderer`. Row 0 is the top row.
private struct RenderedPixels {
    let width: Int
    let height: Int
    let scale: Int
    let bytes: [UInt8]

    func rgb(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }
}

@MainActor
private func renderPixels<V: View>(
    _ view: V, width: CGFloat, height: CGFloat? = nil, scale: Int = 3
) throws -> RenderedPixels {
    let renderer = ImageRenderer(
        content: AnyView(view.frame(width: width, height: height))
    )
    renderer.scale = CGFloat(scale)
    let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
    return try readPixels(image, scale: scale)
}

private func readPixels(_ image: CGImage, scale: Int) throws -> RenderedPixels {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    XCTAssertTrue(drawn, "could not read the rendered view back")
    return RenderedPixels(width: image.width, height: image.height, scale: scale, bytes: bytes)
}

private func rgb255(_ colour: Color) -> [Int] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue].map { Int(($0 * 255).rounded()) }
}

private func distance(_ a: [Int], _ b: [Int]) -> Int {
    zip(a, b).map { abs($0 - $1) }.reduce(0, +)
}

/// The page and its dot grid. Task 6 built them in the SpriteKit scene, where they were
/// unreachable: the scene is exactly the slab's card, and the mount fills all of it. They
/// are a SwiftUI view now, so these tests render that view and read pixels back, which is
/// the only way to see that a dot is on the page and not merely in the view tree.
@MainActor
final class NotebookPageTests: XCTestCase {

    private let size = CGSize(width: 361, height: 485)

    /// The grid is an 8pt lattice counting down from the top and across from the left, with
    /// a dot at the origin. A flipped or offset lattice still looks like a grid, so this
    /// reads the positions of the dots rather than counting them.
    func testTheGridIsAnEightPointLatticeAnchoredAtTheTopLeft() throws {
        let pixels = try renderPixels(
            NotebookPageDrawing(ink: .day, showsGrid: true), width: size.width, height: size.height
        )
        let scale = pixels.scale
        let page = rgb255(Ink.day.page)
        func isDot(_ x: Int, _ y: Int) -> Bool { distance(pixels.rgb(x, y), page) > 12 }

        // Down the column through the first dot's centre, and across the row through it.
        let centre = scale / 2
        let rowStarts = (0..<pixels.height).filter { isDot(centre, $0) && ($0 == 0 || !isDot(centre, $0 - 1)) }
        let columnStarts = (0..<pixels.width).filter { isDot($0, centre) && ($0 == 0 || !isDot($0 - 1, centre)) }
        XCTAssertEqual(
            rowStarts, stride(from: 0, to: Int(size.height), by: 8).map { $0 * scale },
            "dot rows are not an 8pt lattice counting down from the top"
        )
        XCTAssertEqual(
            columnStarts, stride(from: 0, to: Int(size.width), by: 8).map { $0 * scale },
            "dot columns are not an 8pt lattice counting across from the left"
        )
    }

    /// The dots are the theme's hairline at 0.35 over its page. A grid drawn in a fixed
    /// colour would still count as lit above and the theme would never reach it, so this
    /// checks the colour, in both palettes.
    func testTheDotsAndThePageTakeTheirColoursFromTheInk() throws {
        for (name, ink) in [("day", Ink.day), ("night", Ink.night)] {
            let pixels = try renderPixels(
                NotebookPageDrawing(ink: ink, showsGrid: true), width: size.width, height: size.height
            )
            let scale = pixels.scale
            let page = rgb255(ink.page)
            XCTAssertLessThanOrEqual(
                distance(pixels.rgb(4 * scale, 4 * scale), page), 3, "\(name): the page between the dots"
            )
            let expectedDot = zip(rgb255(ink.hairline), page).map {
                Int((NotebookPageDrawing.dotOpacity * Double($0) + (1 - NotebookPageDrawing.dotOpacity) * Double($1)).rounded())
            }
            let first = pixels.rgb(scale / 2, scale / 2)
            XCTAssertLessThanOrEqual(
                distance(first, expectedDot), 8, "\(name): the first dot is \(first), expected \(expectedDot)"
            )
            XCTAssertGreaterThan(
                distance(first, page), 12, "\(name): the dot is indistinguishable from the page, so the check above proves nothing"
            )
        }
    }

    /// Increase Contrast removes the grid and keeps the page: a 0.35-alpha dot pattern is
    /// exactly the low-contrast decoration that setting exists to remove. The environment's
    /// contrast value is read-only, so this drives the drawing's own input.
    func testWithoutTheGridThePageIsPlainStock() throws {
        for (name, ink) in [("day", Ink.day), ("night", Ink.night)] {
            let pixels = try renderPixels(
                NotebookPageDrawing(ink: ink, showsGrid: false), width: size.width, height: size.height
            )
            let page = rgb255(ink.page)
            let strays = (0..<pixels.height).flatMap { y in
                (0..<pixels.width).compactMap { x in distance(pixels.rgb(x, y), page) > 3 ? (x, y) : nil }
            }
            XCTAssertTrue(strays.isEmpty, "\(name): \(strays.count) pixels are not the page, first at \(strays.first.map { "\($0)" } ?? "-")")
        }
    }
}

/// Spec §5: red at rest means "press this", red in motion means "you are breaking it".
/// Once the old danger red and the accent became one `stamp`, over-the-limit had to be
/// carried by motion, and these hold the motion to the numbers the brief gave.
@MainActor
final class AlarmPulseTests: XCTestCase {

    func testThePulseRunsBetweenSixtyFivePercentAndFull() {
        XCTAssertEqual(AlarmPulse.opacity(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(AlarmPulse.opacity(at: 0.5), 0.65, accuracy: 1e-9, "half a second in is the dim end")
        XCTAssertEqual(AlarmPulse.opacity(at: 1.0), 1, accuracy: 1e-9, "and a second in is back to full")

        var lowest = 1.0, highest = 0.0
        for step in 0...300 {
            let opacity = AlarmPulse.opacity(at: Double(step) / 100)
            lowest = min(lowest, opacity)
            highest = max(highest, opacity)
            XCTAssertGreaterThanOrEqual(opacity, 0.65 - 1e-9, "t=\(Double(step) / 100)")
            XCTAssertLessThanOrEqual(opacity, 1 + 1e-9, "t=\(Double(step) / 100)")
        }
        XCTAssertEqual(lowest, 0.65, accuracy: 1e-3, "the pulse never reaches its floor")
        XCTAssertEqual(highest, 1, accuracy: 1e-3, "the pulse never reaches full opacity")
    }

    /// Absolute time, not time since the view appeared: two views pulsing at once beat together.
    func testThePulseIsAFunctionOfAbsoluteTimeWithAOneSecondCycle() {
        for time in [0.13, 0.4, 0.77, 3.21, 1_000.5] {
            XCTAssertEqual(
                AlarmPulse.opacity(at: time), AlarmPulse.opacity(at: time + 1), accuracy: 1e-6, "t=\(time)"
            )
        }
    }

    // MARK: Wiring

    /// Renders `view` repeatedly across a bit more than one cycle and reads one pixel each
    /// time. A pulsing view's pixel moves; a view at rest does not move at all.
    private func samples<V: View>(
        of view: V, width: CGFloat, at point: (x: Int, y: (Int) -> Int)
    ) throws -> [[Int]] {
        var seen: [[Int]] = []
        for _ in 0..<14 {
            let pixels = try renderPixels(view, width: width)
            seen.append(pixels.rgb(point.x, point.y(pixels.height)))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.09))
        }
        return seen
    }

    /// How far the red channel moved across `samples`.
    private func spread(_ samples: [[Int]]) -> Int {
        let reds = samples.map { $0[0] }
        return (reds.max() ?? 0) - (reds.min() ?? 0)
    }

    /// 20pt in, which is inside the fill whether the brush is slow (the fill is 50pt) or fast
    /// (all 300), left of the safe-limit notch at 100pt, and in the middle of the 8pt bar at
    /// the bottom of the meter. 50pt was the first choice, and it is the very end of the slow
    /// fill: it read the static trough beside it, so "the bar does not pulse" passed for a
    /// bar that pulsed all the time.
    private func barPoint(scale: Int = 3) -> (x: Int, y: (Int) -> Int) {
        (x: 20 * scale, y: { height in height - 4 * scale })
    }

    /// Speed only breaks anything over bone, so that is the only place the bar is alarmed. Fast over
    /// bone is stamp red and its opacity moves. Fast over bare rock breaks nothing, so the bar stays
    /// the safe green and still. Slow on bone is stamp red but at rest: red at rest is not an alarm.
    /// Over the pale trough the red channel moves by about 25 levels across the pulse for stamp and
    /// about 60 for the green: a number near 0 is not pulsing.
    func testTheSpeedMeterBarPulsesOnlyWhenTooFastOverBone() throws {
        let over = try samples(
            of: SpeedMeter(speed: 6, safeSpeed: 1, overBone: true), width: 300, at: barPoint()
        )
        XCTAssertGreaterThan(spread(over), 10, "the over-limit bar does not pulse")
        // Red in motion, spec §5: at its fullest the pulsing bar is the stamp red itself. The
        // pulse says "you are breaking it", and red at rest would say "press this".
        let fullest = try XCTUnwrap(over.min { $0[0] < $1[0] })
        XCTAssertLessThanOrEqual(
            distance(fullest, rgb255(Ink.day.stamp)), 45,
            "at full opacity the over-limit bar is \(fullest), not the stamp red"
        )

        // Fast, but over rock: nothing there can crack, so the meter stays calm.
        let rock = try samples(
            of: SpeedMeter(speed: 6, safeSpeed: 1, overBone: false), width: 300, at: barPoint()
        )
        XCTAssertLessThanOrEqual(
            distance(rock[0], rgb255(Ink.day.safe)), 6, "fast over bare rock is not the safe green"
        )
        XCTAssertLessThanOrEqual(spread(rock), 1, "the bar pulses over bare rock, where speed breaks nothing")

        // On bone and inside the safe speed: the stamp red, flat.
        let slow = try samples(
            of: SpeedMeter(speed: 0.5, safeSpeed: 1, overBone: true), width: 300, at: barPoint()
        )
        XCTAssertLessThanOrEqual(
            distance(slow[0], rgb255(Ink.day.stamp)), 6, "slow on bone is not the stamp red"
        )
        XCTAssertLessThanOrEqual(spread(slow), 1, "the bar pulses while the brush is inside the safe speed")

        let under = try samples(of: SpeedMeter(speed: 0.5, safeSpeed: 1), width: 300, at: barPoint())
        XCTAssertLessThanOrEqual(
            distance(under[0], rgb255(Ink.day.safe)), 6,
            "the sample is not on the safe-green fill, so the check below proves nothing"
        )
        XCTAssertLessThanOrEqual(spread(under), 1, "the bar pulses while the brush is inside the safe speed")
    }

    /// The total ink on the page in one render of a readout: it rises and falls with the opacity.
    private func inkMass(_ pixels: RenderedPixels) -> Int {
        let page = rgb255(Ink.day.page)
        var total = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { total += distance(pixels.rgb(x, y), page) }
        }
        return total
    }

    /// How far the Intact readout's total ink swings over a bit more than one cycle, as a
    /// fraction of its peak. `settings` is the player's own preferences, if the view is given any.
    private func readoutSwing(alarmed: Bool, settings: GameSettings? = nil) throws -> Double {
        var masses: [Int] = []
        for _ in 0..<14 {
            let view = Readout(label: "Intact", value: "52%", tint: Ink.day.stamp, isAlarmed: alarmed)
                .background(Ink.day.page)
                .environment(settings)
            masses.append(inkMass(try renderPixels(view, width: 120)))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.09))
        }
        let high = Double(masses.max() ?? 0), low = Double(masses.min() ?? 0)
        return high == 0 ? 0 : (high - low) / high
    }

    /// The Intact readout pulses when told it is alarmed and not otherwise. Measured over the
    /// whole number: the total ink on the page rises and falls with the opacity.
    func testAReadoutPulsesOnlyWhenAlarmed() throws {
        XCTAssertGreaterThan(try readoutSwing(alarmed: true), 0.04, "the alarmed readout does not pulse")
        XCTAssertLessThan(try readoutSwing(alarmed: false), 0.005, "a readout that is not alarmed is moving")
    }

    // MARK: Reduce Motion

    private func settings(reducedMotion: Bool) -> GameSettings {
        let settings = GameSettings(
            defaults: UserDefaults(suiteName: "bonedust.tests.\(UUID().uuidString)")!
        )
        settings.reducedMotion = reducedMotion
        return settings
    }

    /// A pulse that starts by itself and runs for the rest of the dig is blinking content, and
    /// WCAG 2.2.2 (Pause, Stop, Hide, Level A) wants a way to stop anything like that which runs
    /// past five seconds. Reduce Motion is that way. It is not the three-flashes limit of 2.3.1,
    /// which a fade at one cycle a second was always under, and which the old comment here
    /// answered instead. Intact below 60 started the pulse and nothing stopped it until the dig
    /// ended, however the player had set their device.
    ///
    /// This is the player's own toggle, which reaches the pulse through `GameSettings`. The
    /// system setting is read-only in a test, so it is covered where the two are combined, in
    /// `testEitherReduceMotionSourceStopsThePulse`. The bar must also hold at full strength, not
    /// at whatever point of the fade it was stopped on: nothing about the state changed, only
    /// its motion.
    func testTheInAppReduceMotionToggleHoldsTheSpeedMeterBarStill() throws {
        let beating = try samples(
            of: SpeedMeter(speed: 6, safeSpeed: 1, overBone: true).environment(settings(reducedMotion: false)),
            width: 300, at: barPoint()
        )
        XCTAssertGreaterThan(
            spread(beating), 10, "with the toggle off the bar does not pulse, so the check below proves nothing"
        )

        let held = try samples(
            of: SpeedMeter(speed: 6, safeSpeed: 1, overBone: true).environment(settings(reducedMotion: true)),
            width: 300, at: barPoint()
        )
        XCTAssertLessThanOrEqual(spread(held), 1, "the over-limit bar pulses with Reduce Motion on")
        XCTAssertLessThanOrEqual(
            distance(held[0], rgb255(Ink.day.stamp)), 6,
            "held still the bar should be the stamp red at full strength, but it is \(held[0])"
        )
    }

    func testTheInAppReduceMotionToggleHoldsAnAlarmedReadoutStill() throws {
        XCTAssertGreaterThan(
            try readoutSwing(alarmed: true, settings: settings(reducedMotion: false)), 0.04,
            "with the toggle off the alarmed readout does not pulse, so the check below proves nothing"
        )
        XCTAssertLessThan(
            try readoutSwing(alarmed: true, settings: settings(reducedMotion: true)), 0.005,
            "an alarmed readout pulses with Reduce Motion on"
        )
    }

    /// The two sources are combined in one place, and this drives it with each. Either one
    /// stops the pulse, as either quiets the bloom, the dust and the hint; neither being on
    /// leaves it running; and a pulse nobody asked for never starts.
    func testEitherReduceMotionSourceStopsThePulse() {
        func pulses(_ active: Bool, system: Bool, app: Bool) -> Bool {
            AlarmPulse.pulses(isActive: active, systemReduceMotion: system, appReducedMotion: app)
        }
        XCTAssertTrue(pulses(true, system: false, app: false), "an active pulse with no setting on must run")
        XCTAssertFalse(pulses(true, system: true, app: false), "the system Reduce Motion setting")
        XCTAssertFalse(pulses(true, system: false, app: true), "the in-app Reduce Motion toggle")
        XCTAssertFalse(pulses(true, system: true, app: true))
        XCTAssertFalse(pulses(false, system: false, app: false), "nothing to signal, so nothing pulses")
    }
}

/// Until `DigView` hands the scene its theme, a real dig never reaches the night palette:
/// every test above it drives the scene with a `Theme` it built itself. These host a real
/// `DigView` in a window and let it appear, so the one line that connects them is covered.
@MainActor
final class DigViewThemeWiringTests: XCTestCase {

    /// Puts a `DigView` on a site in a full-screen window, so the safe areas are the device's
    /// own, and hands the window to `body`.
    private func withDig<T>(
        site siteID: String, theme: Theme, _ body: (UIWindow) throws -> T
    ) throws -> T {
        let site = try XCTUnwrap(ContentCatalog.shared.site(siteID), "\(siteID) left the catalog; update this test")
        let engine = DigEngine(seed: 11, site: site)
        let settings = GameSettings(
            defaults: UserDefaults(suiteName: "bonedust.tests.\(UUID().uuidString)")!
        )
        let host = UIHostingController(
            rootView: DigView(engine: engine).environment(settings).environment(\.theme, theme)
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene, so the view cannot appear"
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.screen.bounds
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
            withExtendedLifetime(engine) {}
        }
        return try body(window)
    }

    private func firstSKView(in view: UIView) -> SKView? {
        if let skView = view as? SKView { return skView }
        for subview in view.subviews {
            if let found = firstSKView(in: subview) { return found }
        }
        return nil
    }

    /// Runs the loop until `done` or three seconds.
    private func spin(until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return done()
    }

    @discardableResult
    private func dig(site siteID: String, theme: Theme, until done: () -> Bool) throws -> Bool {
        try withDig(site: siteID, theme: theme) { _ in spin(until: done) }
    }

    /// The single most valuable check in the migration: a dig on `night_dig` really does
    /// switch the shared theme, through the view and not through a test's own wiring.
    func testADigOnTheNightSiteSwitchesTheSharedThemeToNight() throws {
        let theme = Theme()
        XCTAssertTrue(theme.ink == Ink.day, "the theme must start on day for this to prove anything")
        let switched = try dig(site: "night_dig", theme: theme) { theme.ink == Ink.night }
        XCTAssertTrue(switched, "a night_dig run never reached the night palette")
        let level = try XCTUnwrap(ContentCatalog.shared.site("night_dig")).modifiers.lightLevel
        XCTAssertEqual(theme.lightLevel, level, "the theme was not given the site's own light level")
    }

    /// The other half: it is the dig that sets the light, not something that happened to be
    /// left in the theme. A theme already at night goes back to day for a day site.
    func testADigOnADaySiteBringsANightThemeBackToDay() throws {
        let theme = Theme()
        theme.lightLevel = 0.2
        XCTAssertTrue(theme.ink == Ink.night, "the theme must start on night for this to prove anything")
        let switched = try dig(site: "charmouth", theme: theme) { theme.ink == Ink.day }
        XCTAssertTrue(switched, "a day-site dig left the theme on night")
    }

    /// Why a seemingly trivial assertion exists. On screen the scene was 1x1 and SpriteKit
    /// stretched it to fill the view: `scaleMode = .resizeFill` was set in `didMove`, which is
    /// too late, so the scene never took the view's size. Every length in scene units was then
    /// wrong by the view's width. Task 6's 12pt slab inset became `max(0, 1 - 12)`, a slab with
    /// no area, and the game's central picture vanished while a hundred tests passed. Every
    /// offscreen test builds its scene at the view's real size (`DigScene(size:)`), so none of
    /// them could see a scene that was not. This one hosts the real `DigView` and compares the
    /// scene with the `SKView` it was presented in. The slab check is the symptom a player sees.
    func testTheSceneIsAsBigAsTheViewItIsPresentedInAndTheSlabHasArea() throws {
        try withDig(site: "charmouth", theme: Theme()) { window in
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
            let skView = try XCTUnwrap(firstSKView(in: window), "the dig screen has no SKView")
            let scene = try XCTUnwrap(skView.scene as? DigScene, "the SKView is not showing a DigScene")
            XCTAssertGreaterThan(
                skView.bounds.width, 100, "the SKView has no real size, so nothing below proves anything"
            )
            XCTAssertEqual(
                scene.size.width, skView.bounds.width, accuracy: 0.5,
                "the scene is \(scene.size), not the \(skView.bounds.size) view it is shown in"
            )
            XCTAssertEqual(scene.size.height, skView.bounds.height, accuracy: 0.5)

            let slab = try XCTUnwrap(scene.slabNode).size
            XCTAssertEqual(
                slab.width, skView.bounds.width - 2 * Measure.mountMargin, accuracy: 0.5,
                "the slab is \(slab): the scene less the mount's margin on every side"
            )
            XCTAssertEqual(slab.height, skView.bounds.height - 2 * Measure.mountMargin, accuracy: 0.5)
        }
    }

    /// The slab is width-limited at 3:4, so the dig screen's content is shorter than the
    /// screen and floats a little inside the safe area. `ignoresSafeArea` only extends an
    /// edge that touches the safe area, so the page once stopped short and left a white
    /// band above and below it. A view rendered with `ImageRenderer` has no safe area, so
    /// this needs a real window, and it reads the pixels inside the bands themselves.
    func testThePageReachesTheScreenEdgesAboveAndBelowTheContent() throws {
        try withDig(site: "charmouth", theme: Theme()) { window in
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
            let insets = window.safeAreaInsets
            try XCTSkipIf(
                insets.top == 0 || insets.bottom == 0,
                "this simulator has no top and bottom safe areas, so there is no band to check"
            )
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let pixels = try readPixels(try XCTUnwrap(image.cgImage), scale: Int(image.scale))
            let page = rgb255(Ink.day.page)
            // 4pt in from the left and midway between two rows of grid dots, which sit on an
            // 8pt lattice from the top of the screen.
            let bottomPoint = 8 * ((Int(window.bounds.height) - 5) / 8) + 4
            XCTAssertGreaterThan(CGFloat(bottomPoint), window.bounds.height - insets.bottom, "not inside the bottom band")
            for (name, point) in [("top", 4), ("bottom", bottomPoint)] {
                let pixel = pixels.rgb(4 * pixels.scale, point * pixels.scale)
                XCTAssertLessThanOrEqual(
                    distance(pixel, page), 3,
                    "the page does not reach the \(name) edge of the screen: \(pixel), not \(page)"
                )
            }
        }
    }
}

/// The launch screen and the app icon. Neither is drawn by the app's own code: the launch
/// screen is on screen before any of it runs and the icon is on the home screen, so both can
/// only be checked where they are declared, in the built bundle.
final class LaunchScreenAndIconTests: XCTestCase {

    private let bundle = Bundle(for: DigScene.self)

    /// Left dark, the launch colour flashed umber before the cream page on every cold start.
    /// It has to be the day page, and the same in both appearances: the page is cream whatever
    /// the system is set to, so a dark variant would be the same flash the other way round.
    func testTheLaunchScreenIsTheDayPageInEveryAppearance() throws {
        let launch = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any],
            "the bundle has no UILaunchScreen"
        )
        let name = try XCTUnwrap(launch["UIColorName"] as? String, "UILaunchScreen names no colour")
        XCTAssertEqual(name, "LaunchBackground")
        for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let colour = try XCTUnwrap(
                UIColor(
                    named: name, in: bundle,
                    compatibleWith: UITraitCollection(userInterfaceStyle: style)
                ),
                "\(name) is not in the asset catalog"
            )
            XCTAssertEqual(
                rgb255(Color(colour)), rgb255(Ink.day.page),
                "\(appearance): the launch colour is not the page the first frame is drawn on"
            )
        }
    }

    /// The app had no icon until this: an empty slot compiles to no `CFBundleIcons` at all. This
    /// pins that one is declared and that it is the wordmark, by its colours: the page at the
    /// corner, ink in BONE and stamp red in DUST.
    func testTheBundleDeclaresAnAppIconThatIsTheWordmarkOnThePage() throws {
        let icons = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            "the build declares no CFBundleIcons, so the app has no icon"
        )
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String], "no icon files are declared")
        let icon = try XCTUnwrap(
            files.lazy.compactMap { UIImage(named: $0, in: self.bundle, compatibleWith: nil) }.first,
            "none of \(files) is in the bundle"
        )
        let pixels = try readPixels(try XCTUnwrap(icon.cgImage), scale: 1)

        XCTAssertLessThanOrEqual(
            distance(pixels.rgb(1, 1), rgb255(Ink.day.page)), 6, "the icon's corner is not the page"
        )
        func count(near colour: [Int]) -> Int {
            (0..<pixels.height).reduce(0) { total, y in
                total + (0..<pixels.width).filter { distance(pixels.rgb($0, y), colour) <= 40 }.count
            }
        }
        XCTAssertGreaterThan(count(near: rgb255(Ink.day.ink)), 200, "no BONE in ink")
        XCTAssertGreaterThan(count(near: rgb255(Ink.day.stamp)), 200, "no DUST in stamp red")
    }
}
