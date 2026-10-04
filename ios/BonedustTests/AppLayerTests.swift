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

    func testTheBackdropSitsBehindTheSlabInTheBriefsDepthOrder() {
        let (scene, _) = present()
        scene.buildBackdrop(contrastRaised: false)
        XCTAssertEqual(scene.gridNode?.zPosition, -3)
        XCTAssertEqual(scene.paperNode?.zPosition, -2)
        XCTAssertEqual(scene.mountNode?.zPosition, -1)
        XCTAssertEqual(scene.slabNode?.zPosition, 0)
    }

    /// The brief drops the two low-contrast layers under Increase Contrast and keeps
    /// the mount: Increase Contrast makes it more necessary, not less.
    func testIncreaseContrastDropsTheGridAndPaperButNeverTheMount() {
        let (scene, _) = present()

        scene.buildBackdrop(contrastRaised: true)
        XCTAssertNil(scene.gridNode)
        XCTAssertNil(scene.paperNode)
        XCTAssertNotNil(scene.mountNode, "the mount is what separates a cleared slab from the page")
        XCTAssertEqual(scene.children.count, 2, "mount and slab only; the old grid and paper must leave the scene")

        scene.buildBackdrop(contrastRaised: false)
        XCTAssertNotNil(scene.gridNode)
        XCTAssertNotNil(scene.paperNode)
        XCTAssertNotNil(scene.mountNode)
        XCTAssertEqual(scene.children.count, 4, "grid, paper, mount and slab")
    }

    /// The default for `contrastRaised` is the live system setting. The suite cannot
    /// flip that setting, so this asserts whichever state the run is in. To see the
    /// other branch, run it with `xcrun simctl ui booted increase_contrast enabled`.
    func testTheDefaultBackdropFollowsTheSystemSetting() {
        let (scene, _) = present()
        scene.buildBackdrop()
        let raised = UIAccessibility.isDarkerSystemColorsEnabled
        XCTAssertEqual(scene.gridNode == nil, raised, "Increase Contrast is \(raised ? "on" : "off")")
        XCTAssertEqual(scene.paperNode == nil, raised, "Increase Contrast is \(raised ? "on" : "off")")
        XCTAssertNotNil(scene.mountNode)
    }

    /// A rebuild replaces the layers. A leak here would stack a screen-sized
    /// texture per resize.
    func testResizingRebuildsTheBackdropInsteadOfStackingIt() {
        let (scene, _) = present()
        for width in [390, 768, 1024] {
            scene.size = CGSize(width: width, height: width * 4 / 3)
        }
        let expected = UIAccessibility.isDarkerSystemColorsEnabled ? 2 : 4
        XCTAssertEqual(scene.children.count, expected)
        if let grid = scene.gridNode {
            XCTAssertEqual(grid.size, scene.size, "the grid is rebuilt at the new size, never stretched")
        }
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
        scene.buildBackdrop(contrastRaised: true)
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

    func testApplyThemeRepaintsThePageTheMountAndTheGrid() throws {
        let (scene, _) = present()
        scene.buildBackdrop(contrastRaised: false)
        for ink in [Ink.night, Ink.day] {
            scene.applyTheme(ink: ink)
            XCTAssertEqual(rgb(scene.backgroundColor), rgb(ink.page))
            XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(ink.mount))
            XCTAssertEqual(rgb(try XCTUnwrap(scene.gridNode).color), rgb(ink.hairline))
        }
    }

    /// The backdrop is rebuilt on every resize. If the rebuild read the day palette
    /// instead of the one last applied, a night dig would flip its mount back to
    /// day colours the first time the view changed size.
    func testAResizeKeepsThePaletteTheSceneWasPaintedIn() throws {
        let (scene, _) = present()
        scene.buildBackdrop(contrastRaised: false)
        scene.applyTheme(ink: .night)
        scene.size = CGSize(width: 768, height: 1024)
        XCTAssertEqual(rgb(scene.backgroundColor), rgb(Ink.night.page))
        XCTAssertEqual(rgb(try XCTUnwrap(scene.mountNode).color), rgb(Ink.night.mount))
        if let grid = scene.gridNode {
            XCTAssertEqual(rgb(grid.color), rgb(Ink.night.hairline))
        }
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

    // MARK: Grid

    /// The grid is an image drawn top-down, which is `SlabGrid`'s convention, while
    /// SpriteKit's own y runs up. This pins which way round it lands: a dot in the
    /// top-left corner of the screen, then an 8pt lattice counting down and across.
    ///
    /// A marker placed high in SpriteKit's y-up space calibrates the readback first,
    /// so the test cannot pass by two flips cancelling. The height is chosen so a
    /// bottom-anchored lattice would land on different rows.
    func testTheGridIsAnEightPointLatticeAnchoredAtTheTopLeft() throws {
        let size = CGSize(width: 361, height: 485)
        let (scene, view) = present(size: size)
        scene.buildBackdrop(contrastRaised: false)
        scene.mountNode?.isHidden = true
        scene.slabNode?.isHidden = true
        scene.paperNode?.isHidden = true

        let marker = SKSpriteNode(color: .red, size: CGSize(width: 20, height: 20))
        marker.position = CGPoint(x: 100, y: size.height - 30)
        marker.zPosition = 5
        scene.addChild(marker)
        let marked = try render(scene, in: view)
        marker.removeFromParent()
        let pixels = try render(scene, in: view)

        let scale = pixels.width / Int(size.width)
        let markerRow = (0..<marked.height).first {
            let pixel = marked.rgb(100 * scale, $0)
            return pixel[0] > 200 && pixel[1] < 60
        }
        XCTAssertLessThan(
            markerRow ?? .max, marked.height / 5,
            "a node near the top of SpriteKit's y-up space did not read back near row 0"
        )

        let page = pixels.rgb(4 * scale, 4 * scale)
        // The dots are the hairline colour at 0.35 alpha over the page. Drawn white and
        // left untinted they would still count as lit below, but in the wrong colour,
        // and the theme would never reach them.
        let expectedDot = zip(rgb(Ink.day.hairline), page).map {
            Int((0.35 * Double($0) + 0.65 * Double($1)).rounded())
        }
        assertPixel(pixels.rgb(scale / 2, scale / 2), is: expectedDot, "the first dot", tolerance: 4)
        func isDot(_ x: Int, _ y: Int) -> Bool { distance(pixels.rgb(x, y), page) > 12 }
        let rowStarts = (0..<pixels.height).filter { isDot(0, $0) && ($0 == 0 || !isDot(0, $0 - 1)) }
        let columnStarts = (0..<pixels.width).filter { isDot($0, 0) && ($0 == 0 || !isDot($0 - 1, 0)) }

        XCTAssertEqual(
            rowStarts, stride(from: 0, to: Int(size.height), by: 8).map { $0 * scale },
            "dot rows are not an 8pt lattice counting down from the top"
        )
        XCTAssertEqual(
            columnStarts, stride(from: 0, to: Int(size.width), by: 8).map { $0 * scale },
            "dot columns are not an 8pt lattice counting across from the left"
        )
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

    /// The whole point of §7a: the tell must survive a posterize, because it is a
    /// pattern and not a colour. A tint at 6 levels does not.
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
    func testInkEdgeMakesBoneSeparateFromMatrixOnEverySite() {
        for site in ContentCatalog.shared.sites {
            let matrix = site.palette.matrix
            let bone = site.palette.bone
            let bare = bone.contrastRatio(against: matrix)
            let edged = SlabRenderer.inked(bone).contrastRatio(against: matrix)
            // The old relief: a lit top edge and a shadowed bottom edge. Whichever of
            // the two was stronger is the one to beat.
            let rim = max(
                bone.scaled(1.12).contrastRatio(against: matrix),
                bone.scaled(0.86).contrastRatio(against: matrix)
            )

            XCTAssertGreaterThanOrEqual(
                edged, 3.0,
                "site '\(site.id)': the ink edge does not separate bone from matrix (\(edged))"
            )
            XCTAssertGreaterThan(
                edged, bare,
                "site '\(site.id)': the ink edge is weaker than the bare fill it replaced"
            )
            XCTAssertGreaterThan(
                edged, rim,
                "site '\(site.id)': the ink edge (\(edged)) is weaker than the relief it replaced (\(rim))"
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

    /// The tell, as a pattern. Sandstone over bone takes the stipple on its dot grid and
    /// nowhere else, and both constants stay live so the debug overlay can A/B them:
    /// either one at zero gives the pure case.
    func testTheTellIsAStippleAndBothConstantsStayLive() {
        XCTAssertEqual(SimTuning.standard.boneTellStipple, 0.60, "ships at stipple 0.60")
        XCTAssertEqual(SimTuning.standard.boneTellTint, 0, "and with the tint off")

        let palette = SlabPalette.standard
        var grid = SlabGrid()
        fill(&grid, x: 0..<SlabGrid.width, y: 0..<SlabGrid.height,
             with: SlabGrid.Cell(depth: 1, flags: 0, wear: 0, noise: 0))
        fill(&grid, x: 20..<40, y: 20..<40,
             with: SlabGrid.Cell(depth: 1, flags: SlabGrid.Flag.bone, wear: 0, noise: 0))

        var renderer = SlabRenderer(palette: palette)
        renderer.redrawEverything(grid)
        let dot = palette.sandstone.lerp(to: palette.bone, SimTuning.standard.boneTellStipple)
        for y in 18..<42 {
            for x in 18..<42 {
                let inside = (20..<40).contains(x) && (20..<40).contains(y)
                let expected = inside && SlabRenderer.isStippled(x: x, y: y) ? dot : palette.sandstone
                XCTAssertEqual(renderer.pixel(x, y), expected, "cell (\(x), \(y))")
            }
        }

        // Today's behaviour, from the sliders alone: no dots, a flat tint over the bone.
        renderer.tuning.boneTellStipple = 0
        renderer.tuning.boneTellTint = 0.20
        renderer.redrawEverything(grid)
        let tint = palette.sandstone.lerp(to: palette.bone, 0.20)
        for y in 20..<40 {
            for x in 20..<40 {
                XCTAssertEqual(renderer.pixel(x, y), tint, "tint only, cell (\(x), \(y))")
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
