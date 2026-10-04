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
