# Field-Notebook Visual Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Bonedust's generic dark-mode chrome with a field-notebook identity — a cream page, a dark specimen mount, real display and typewriter faces, and a night mode that dims the whole page rather than just the slab.

**Architecture:** A single nine-stop `Earth` ramp lives in `BonedustCore` as plain `RGB8` values with no SwiftUI dependency, so the existing non-simulator test suite can pin its luminance and contrast properties. The app-layer `Ink` struct projects that ramp into SwiftUI `Color`s and gains day/night presets that a small `Theme` observable interpolates from `lightLevel`. The slab is separated from the page by a dark mount panel in the SpriteKit scene, which is what makes a light page viable at all. The renderer gains a cel pass that steps the lighting and draws a semantic ink edge, leaving every palette value untouched.

**Tech Stack:** Swift 5, SwiftUI, SpriteKit, XCTest, XcodeGen (`ios/project.yml`), iOS 17 deployment target, portrait only.

**Spec:** `docs/superpowers/specs/2026-10-04-visual-identity-design.md`

## Global Constraints

- Deployment target is **iOS 17.0**; `SWIFT_VERSION` is **5.0**. No iOS 18+ API.
- `SWIFT_STRICT_CONCURRENCY: minimal`. Types crossing into `BonedustCore` must stay `Sendable`.
- `BonedustCore` must not import SwiftUI or UIKit. Ramp values there are `RGB8` only.
- The app is **portrait only**. Do not add landscape layout branches.
- All 94 existing `BonedustCore` tests and the existing `BonedustTests` suite must stay green.
- Dynamic Type must keep working everywhere outside the slab. Every custom font goes through `Font.custom(_:size:relativeTo:)`, never `Font.custom(_:fixedSize:)`.
- Colour literals are written as `RGB8(0xNN, 0xNN, 0xNN)` so they can be diffed against the spec's hex table by eye.
- **Pick a simulator that exists.** `export SIM=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9]+' | tail -1)` before any `xcodebuild` command. iPhone 16 is not installed on this machine; iPhone 17 is.
- **`BonedustTests` has two failures that predate this plan.** `testEstimatedValueExcludesTheRushBonus` and `testPublishedReadoutsTrackTheSimulation` are byte-identical to the merge-base and exercise only `DigEngine` and the economy — nothing this plan touches. **Do not fix them; they are out of scope.** Scope every `xcodebuild test` run with `-only-testing:` to the classes the task owns, so a red pre-existing test never masks a real one.
- Two test homes, both XCTest: `ios/BonedustCore/Tests/BonedustCoreTests/` for anything pure, `ios/BonedustTests/AppLayerTests.swift` for anything needing UIKit or SwiftUI.

## Review Focus

These are the failure modes the spec implies but that no task's happy path exercises. Each one has its test assigned to the task that owns the code.

1. **A font file is missing or fails to register.** The app must fall back to today's system faces, not render blank or crash. → Task 4.
2. **A site is added to `content.json` later with no palette override.** It inherits the defaults and must still clear the mount. The guard test iterates the catalog rather than a hardcoded list. → Task 2.
3. **`lightLevel` arrives outside `0...1`.** `SiteModifiers.lightLevel` is a `Float` multiplied by charms and set perks, so a stacked buff can push it above 1 or a bug below 0. The page lerp must clamp instead of producing an out-of-range colour. → Task 5.
4. **Dynamic Type at accessibility sizes.** Custom faces must scale with `AX5` and the HUD must not clip. → Task 3.
5. **Increase Contrast is enabled.** Paper fibre at 3% and the grid at 0.35 alpha are below the threshold the setting exists to fix; both must drop out rather than sit there as noise. → Task 6.
6. **A fossil only two cells thick.** green_river's twist is "the fish are paper". A four-sided ink edge would render such a specimen as solid outline with no interior — silent content destruction on one whole site, visible only by playing it. → Task 8.

---

### Task 1: The Earth ramp and its colour maths

**Files:**
- Create: `ios/BonedustCore/Sources/BonedustCore/Content/EarthRamp.swift`
- Create: `ios/BonedustCore/Tests/BonedustCoreTests/EarthRampTests.swift`

**Interfaces:**
- Consumes: `RGB8` from `Content/ContentModels.swift` — `public struct RGB8: Sendable, Codable, Equatable` with `public init(_ r: UInt8, _ g: UInt8, _ b: UInt8)`.
- Produces: `public enum Earth` with stops `s0`...`s8`, `all: [RGB8]`, and the named roles `stamp`, `gem`, `safe`, `mount`, `nightPage`. Also `RGB8.relativeLuminance: Double` and `RGB8.contrastRatio(against:) -> Double`, which Tasks 2 and 3 both use.

- [ ] **Step 1: Write the failing test**

Create `ios/BonedustCore/Tests/BonedustCoreTests/EarthRampTests.swift`:

```swift
import XCTest
@testable import BonedustCore

final class EarthRampTests: XCTestCase {

    func testRampDarkensMonotonically() {
        let stops = Earth.all
        XCTAssertEqual(stops.count, 9)
        for i in 1..<stops.count {
            XCTAssertLessThan(
                stops[i].relativeLuminance, stops[i - 1].relativeLuminance,
                "stop \(i) is not darker than stop \(i - 1); a hex is mistyped"
            )
        }
    }

    func testContrastRatioIsSymmetricAndBounded() {
        let white = RGB8(255, 255, 255)
        let black = RGB8(0, 0, 0)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.01)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.01)
    }

    /// §Testing item 2. These are the pairs the design actually puts on screen.
    func testEveryTextPairClearsWCAGAAOnThePage() {
        let page = Earth.s1
        let bodyPairs: [(String, RGB8)] = [
            ("primary text", Earth.s8),
            ("secondary text", Earth.s5),
            ("stamp", Earth.stamp),
            ("gem", Earth.gem),
            ("safe", Earth.safe),
        ]
        for (name, colour) in bodyPairs {
            XCTAssertGreaterThanOrEqual(
                colour.contrastRatio(against: page), 4.5,
                "\(name) fails AA body contrast on the page"
            )
        }
    }

    /// The reason no text is allowed above s5. If someone lightens s5 this fails.
    func testDecorativeStopsCannotCarryBodyText() {
        XCTAssertLessThan(
            Earth.s4.contrastRatio(against: Earth.s1), 4.5,
            "s4 now clears AA; if that is deliberate, update the spec's role table"
        )
    }

    func testNightPageKeepsPrimaryTextReadableWhenInverted() {
        XCTAssertGreaterThanOrEqual(
            Earth.s1.contrastRatio(against: Earth.nightPage), 4.5,
            "night mode text is unreadable"
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/BonedustCore && swift test --filter EarthRampTests`
Expected: FAIL to compile with "cannot find 'Earth' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `ios/BonedustCore/Sources/BonedustCore/Content/EarthRamp.swift`:

```swift
import Foundation

/// The one colour ramp. Chrome takes the light end, the slab takes the dark end.
///
/// This lives in Core, not the app, for one reason: it must be testable without a
/// simulator. The contrast guarantees in `EarthRampTests` are the whole point of
/// the ramp, and they would be untestable sitting next to SwiftUI.
///
/// Values are the spec's hex table verbatim. If you change one, the tests tell you
/// which guarantee you broke.
public enum Earth {
    /// Pasted-label / raised surface.
    public static let s0 = RGB8(0xF6, 0xEF, 0xDE)
    /// The page.
    public static let s1 = RGB8(0xED, 0xE4, 0xCF)
    /// Ruled box fill.
    public static let s2 = RGB8(0xDF, 0xD4, 0xBB)
    /// Grid, dividers, hairlines.
    public static let s3 = RGB8(0xC4, 0xB5, 0x96)
    /// Decorative and disabled only. Never text — see `testDecorativeStopsCannotCarryBodyText`.
    public static let s4 = RGB8(0x9C, 0x8A, 0x6E)
    /// Secondary text. The first stop dark enough to carry it on `s1`.
    public static let s5 = RGB8(0x6E, 0x5E, 0x48)
    /// The specimen mount.
    public static let s6 = RGB8(0x4A, 0x3D, 0x2E)
    public static let s7 = RGB8(0x2E, 0x26, 0x19)
    /// Ink. Primary text.
    public static let s8 = RGB8(0x1C, 0x1A, 0x17)

    public static let all: [RGB8] = [s0, s1, s2, s3, s4, s5, s6, s7, s8]

    /// The single accent. Flat for actions, animated for damage — see spec §5.
    public static let stamp = RGB8(0xB0, 0x3A, 0x2B)
    /// Gems only.
    public static let gem = RGB8(0x17, 0x65, 0x74)
    /// Speed and intact semantics only.
    public static let safe = RGB8(0x41, 0x64, 0x2F)

    /// The slab sits on this. Without it a cleared slab vanishes into the page.
    public static let mount = s6
    /// The page at full dark. Not black: a notebook under a work lamp.
    public static let nightPage = RGB8(0x2A, 0x26, 0x20)
}

extension RGB8 {

    /// WCAG 2.1 relative luminance, 0 for black to 1 for white.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG 2.1 contrast ratio, 1 (identical) to 21 (black on white).
    public func contrastRatio(against other: RGB8) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/BonedustCore && swift test --filter EarthRampTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Run the whole Core suite**

Run: `cd ios/BonedustCore && swift test`
Expected: PASS. The 94 existing tests are untouched.

- [ ] **Step 6: Commit**

```bash
git add ios/BonedustCore/Sources/BonedustCore/Content/EarthRamp.swift \
        ios/BonedustCore/Tests/BonedustCoreTests/EarthRampTests.swift
git commit -m "feat: add the Earth ramp and WCAG contrast maths"
```

---

### Task 2: Pin every site's matrix against the mount

The spec claims no palette retune is needed because every existing site already clears the mount. This task turns that claim into a test, so it stays true when sites are added.

**Files:**
- Modify: `ios/BonedustCore/Tests/BonedustCoreTests/EarthRampTests.swift`

**Interfaces:**
- Consumes: `Earth.mount` and `RGB8.contrastRatio(against:)` from Task 1; `ContentCatalog.shared.sites` and `Site.palette: SlabPalette` from `Content/`.
- Produces: nothing. This is a guard.

- [ ] **Step 1: Write the failing test**

Append to `EarthRampTests.swift`:

```swift
extension EarthRampTests {

    /// Review Focus 2. This iterates the catalog rather than a hardcoded list, so a
    /// site added later with no palette override is covered without anyone
    /// remembering to come back here.
    ///
    /// `matrix` is the top layer — a fully-excavated slab is this colour across its
    /// whole face. It is the colour most at risk of vanishing, which is why it, and
    /// not `topsoil`, is what gets pinned.
    func testEverySiteMatrixSeparatesFromTheMount() {
        let sites = ContentCatalog.shared.sites
        XCTAssertFalse(sites.isEmpty, "catalog failed to load; the rest proves nothing")

        for site in sites {
            let ratio = site.palette.matrix.contrastRatio(against: Earth.mount)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "site '\(site.id)': a cleared slab vanishes into the mount at \(ratio)"
            )
        }
    }
}
```


- [ ] **Step 2: Run the test**

Run: `cd ios/BonedustCore && swift test --filter EarthRampTests`
Expected: PASS without changing any palette. The spec predicts green_river at ~7.6:1 and wheeler at ~5.8:1 against the mount.

If either test fails, **stop and report the numbers** rather than editing palettes. A failure means the spec's measurement was wrong and the mount colour needs revisiting — that is a design decision, not an implementation one.

- [ ] **Step 3: Commit**

```bash
git add ios/BonedustCore/Tests/BonedustCoreTests/EarthRampTests.swift
git commit -m "test: pin every site's slab palette against the mount"
```

---

### Task 3: Ink as a day/night struct, and Typography with a fallback chain

**Files:**
- Modify: `ios/Bonedust/UI/DesignTokens.swift` (full rewrite)
- Modify: `ios/BonedustTests/AppLayerTests.swift` (append)

**Interfaces:**
- Consumes: `Earth`, `RGB8` from Task 1.
- Produces: `struct Ink` with instance properties `page`, `raised`, `hairline`, `ink`, `muted`, `stamp`, `gem`, `safe`, `mount`; statics `Ink.day`, `Ink.night`, `Ink.lerp(from:to:_:)`. Task 5 consumes `lerp`, Task 9 consumes the instance properties. Also `Typography.display/ui/label/number` with unchanged call signatures except `display`, whose `relativeTo:` parameter changes from `UIFont.TextStyle` to `Font.TextStyle`.

**Why the deprecated block exists:** there are 51 `Ink.` call sites across three views. Migrating them is Task 9. Keeping the old static names alive here means the app still compiles at the end of this task, so Task 3 is independently reviewable and Task 9 is a pure rename.

- [ ] **Step 1: Write the failing test**

Append to `ios/BonedustTests/AppLayerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/DesignTokenTests`
Expected: FAIL to compile — `Ink.day`, `Ink.lerp`, and `Typography.resolvedDisplayPointSize` do not exist.

- [ ] **Step 3: Write the implementation**

Replace the whole of `ios/Bonedust/UI/DesignTokens.swift`:

```swift
import BonedustCore
import SwiftUI
import UIKit

/// §7's visual direction, as the only place colours and fonts are named.
///
/// Field notebook: a cream page, ink text, and one accent. The slab is the only
/// dark object, and it sits on a mount so a cleared slab cannot bleed into the
/// paper. Green and teal appear *only* for speed and gems; stamp red is the single
/// accent and carries two meanings separated by motion — flat for actions, blooming
/// for damage. See spec §5.
///
/// Every value comes from `Earth` in BonedustCore, which is where the contrast
/// guarantees are tested.
struct Ink: Equatable {
    var page: Color
    var raised: Color
    var hairline: Color
    var ink: Color
    var muted: Color
    var stamp: Color
    var gem: Color
    var safe: Color
    var mount: Color

    static let day = Ink(
        page: Color(Earth.s1),
        raised: Color(Earth.s0),
        hairline: Color(Earth.s3),
        ink: Color(Earth.s8),
        muted: Color(Earth.s5),
        stamp: Color(Earth.stamp),
        gem: Color(Earth.gem),
        safe: Color(Earth.safe),
        mount: Color(Earth.mount)
    )

    /// The ramp inverted. Text goes pale, the page goes to lamp-lit brown.
    ///
    /// The accents keep their meaning but not their values: the day accents sit at
    /// 2.2-2.5:1 against `nightPage`, far under AA, so night has its own three.
    /// `gemNight` and `safeNight` are the original values from the dark UI this
    /// redesign replaces — that palette was never wrong, it was a dark-mode
    /// palette, and it is correct again here.
    static let night = Ink(
        page: Color(Earth.nightPage),
        raised: Color(Earth.s7),
        hairline: Color(Earth.s5),
        ink: Color(Earth.s1),
        muted: Color(Earth.s3),   // s4 is 4.49:1 on nightPage — under AA
        stamp: Color(Earth.stampNight),
        gem: Color(Earth.gemNight),
        safe: Color(Earth.safeNight),
        mount: Color(Earth.s8)
    )

    /// `fraction` is clamped, so an out-of-range `lightLevel` cannot produce a
    /// palette that is neither day nor night. See Review Focus 3.
    static func lerp(from: Ink, to: Ink, _ fraction: Double) -> Ink {
        let t = min(max(fraction, 0), 1)
        if t == 0 { return from }
        if t == 1 { return to }
        return Ink(
            page: from.page.mixed(with: to.page, t),
            raised: from.raised.mixed(with: to.raised, t),
            hairline: from.hairline.mixed(with: to.hairline, t),
            ink: from.ink.mixed(with: to.ink, t),
            muted: from.muted.mixed(with: to.muted, t),
            stamp: from.stamp.mixed(with: to.stamp, t),
            gem: from.gem.mixed(with: to.gem, t),
            safe: from.safe.mixed(with: to.safe, t),
            mount: from.mount.mixed(with: to.mount, t)
        )
    }
}

// MARK: - Deprecated static accessors
//
// The 51 call sites across RootView, DigView and SpeedMeter still use the old flat
// names. These keep the app compiling until Task 9 migrates them, then this block
// is deleted. Do not add new uses.

extension Ink {
    static var ground: Color { Ink.day.page }
    static var ivory: Color { Ink.day.ink }
    static var accent: Color { Ink.day.stamp }
    /// Damage is now motion, not hue. Maps to the same red; see spec §5.
    static var danger: Color { Ink.day.stamp }
    static var raised: Color { Ink.day.raised }
    static var hairline: Color { Ink.day.hairline }
    static var muted: Color { Ink.day.muted }
    static var gem: Color { Ink.day.gem }
    static var safe: Color { Ink.day.safe }
    static var launchBackground: Color { Ink.day.page }
}

enum Measure {
    static let gutter: CGFloat = 16
    /// Notebooks have no rounded corners. Cards are ruled boxes, not filled panels.
    static let cardRadius: CGFloat = 0
    static let hairline: CGFloat = 1
    /// How far the mount extends past the slab on every side.
    static let mountMargin: CGFloat = 6
}

/// Three faces, each with one job.
///
/// Display is Rubik Dirt — a rough, dirt-textured face, which is both the right
/// notebook-stamp texture and the choice `Resources/Fonts/README.md` already made.
/// UI is SF Pro, which gets Dynamic Type right for free and should stay neutral.
/// Numbers are Courier Prime with tabular figures, so a changing readout does not
/// jitter its own layout.
///
/// Every accessor falls back to the previous system face when the custom font is
/// not registered. A missing `.ttf` degrades the look; it never blanks or crashes.
enum Typography {

    static let displayFace = "RubikDirt-Regular"
    static let numberFace = "CourierPrime-Regular"

    /// Resolved once. `UIFont(name:size:)` is a dictionary lookup, but this is read
    /// on every text render and there is no reason to repeat it.
    static let displayAvailable = UIFont(name: displayFace, size: 12) != nil
    static let numberAvailable = UIFont(name: numberFace, size: 12) != nil

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        guard displayAvailable else {
            let base = UIFont.systemFont(ofSize: size, weight: .black, width: .expanded)
            return Font(UIFontMetrics(forTextStyle: style.uiStyle).scaledFont(for: base))
        }
        return .custom(displayFace, size: size, relativeTo: style)
    }

    static func ui(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default).weight(weight)
    }

    /// Small-caps museum-label styling, per §7.
    static func label(_ style: Font.TextStyle = .caption2) -> Font {
        guard displayAvailable else {
            return .system(style, design: .default).weight(.semibold)
        }
        return .custom(displayFace, size: style.baseSize, relativeTo: style)
    }

    /// Tabular figures. Use for every number that changes while you watch it.
    static func number(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        guard numberAvailable else {
            return .system(style, design: .monospaced).weight(weight)
        }
        return .custom(numberFace, size: style.baseSize, relativeTo: style)
    }

    // MARK: Test seams
    //
    // `display` and `number` are thin wrappers over these, which take the
    // availability flags as parameters. The tests call the SAME functions with
    // availability injected, so they exercise the real code path -- including the
    // custom-font branch, which is where a `fixedSize` regression would hide.
    //
    // An earlier draft had the seams rebuild the font independently. That version
    // could not fail: changing `display()` to `Font.custom(_:fixedSize:)` left
    // every Dynamic Type test green. Sharing only a base `UIFont` would not have
    // fixed it either, because `number()` builds no `UIFont` at all on the custom
    // path. Injecting availability is what makes one code path serve both callers.

    static func displayFont(
        _ size: CGFloat, relativeTo style: Font.TextStyle, customFaceAvailable: Bool
    ) -> Font

    static func numberFont(
        _ style: Font.TextStyle, weight: Font.Weight,
        regularAvailable: Bool, boldAvailable: Bool
    ) -> Font

    // Note: `Font.Weight` is NOT Comparable, so the bold test is set membership:
    // `[.semibold, .bold, .heavy, .black].contains(weight)`.
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/DesignTokenTests`
Expected: PASS, 6 tests. The Dynamic Type tests pass against the *system fallback* at this point, because no font file exists yet. That is the point — Task 4 proves the custom path.

- [ ] **Step 5: Confirm the app still builds**

Run: `xcodebuild build -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM"`
Expected: SUCCESS. The deprecated block keeps all 51 call sites compiling. The app will look wrong — cream tokens behind a dark layout — until Task 9. That is expected.

- [ ] **Step 6: Commit**

```bash
git add ios/Bonedust/UI/DesignTokens.swift ios/BonedustTests/AppLayerTests.swift
git commit -m "feat: Ink becomes a day/night palette over the Earth ramp"
```

---

### Task 4: Bundle the two faces

**Files:**
- Create: `ios/Bonedust/Resources/Fonts/RubikDirt-Regular.ttf` (downloaded)
- Create: `ios/Bonedust/Resources/Fonts/CourierPrime-Regular.ttf` (downloaded)
- Modify: `ios/project.yml` — add `UIAppFonts` under the `Bonedust` target's `info.properties`
- Modify: `ios/Bonedust/Resources/Fonts/README.md`
- Modify: `ios/BonedustTests/AppLayerTests.swift` (append)

**Interfaces:**
- Consumes: `Typography.displayFace`, `Typography.numberFace`, `Typography.displayAvailable`, `Typography.numberAvailable` from Task 3.
- Produces: nothing in code. Registered fonts.

**Blocker:** this task cannot start until both `.ttf` files are present. Both are SIL OFL: Rubik Dirt and Courier Prime are on Google Fonts. Every other task in this plan is independent of this one.

- [ ] **Step 1: Write the failing test**

Append to `ios/BonedustTests/AppLayerTests.swift`:

```swift
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

    func testTabularFiguresAreOnForNumerals() {
        guard let font = UIFont(name: Typography.numberFace, size: 17) else {
            return XCTFail("numeral face missing")
        }
        let wide = ("1111" as NSString).size(withAttributes: [.font: font])
        let narrow = ("8888" as NSString).size(withAttributes: [.font: font])
        XCTAssertEqual(
            wide.width, narrow.width, accuracy: 0.5,
            "numerals are not tabular; a changing readout will jitter its layout"
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/FontRegistrationTests`
Expected: FAIL — "RubikDirt-Regular is not registered."

- [ ] **Step 3: Add the font files**

Download `RubikDirt-Regular.ttf` and `CourierPrime-Regular.ttf` from Google Fonts into `ios/Bonedust/Resources/Fonts/`. XcodeGen picks them up with the rest of `Resources`.

- [ ] **Step 4: Register them**

In `ios/project.yml`, under the `Bonedust` target's `info.properties`, after the `CFBundleVersion` line:

```yaml
        UIAppFonts:
          - RubikDirt-Regular.ttf
          - CourierPrime-Regular.ttf
```

Then regenerate: `cd ios && xcodegen generate`

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests`
Expected: PASS. `DesignTokenTests` now exercises the custom-font path rather than the fallback, and must still pass.

- [ ] **Step 6: Update the README**

Replace `ios/Bonedust/Resources/Fonts/README.md`:

```markdown
# Fonts

Two bundled faces, both SIL OFL-1.1. The licence only requires that the fonts
themselves stay OFL and are not sold on their own, so shipping them in a paid
app is fine.

| File | Used by | Role |
|---|---|---|
| `RubikDirt-Regular.ttf` | `Typography.display`, `Typography.label` | Wordmark, large headings, small-caps field labels |
| `CourierPrime-Regular.ttf` | `Typography.number` | Every number that changes while you watch it |

Body text is SF Pro via `Typography.ui` and is deliberately not a custom face:
it gets Dynamic Type right for free, and a notebook's body text should be
neutral. The character lives in the display face and the numerals.

## Adding or replacing a face

1. Put the `.ttf` in this directory.
2. List it under `UIAppFonts` in the `Bonedust` target's `info.properties` in
   `ios/project.yml`.
3. Run `xcodegen generate`.
4. Point the matching constant in `UI/DesignTokens.swift` at the PostScript name
   (`Typography.displayFace` or `Typography.numberFace`).

`FontRegistrationTests` fails loudly if a face is missing, so you will know.

## Fallbacks

Every `Typography` accessor falls back to the system face it used before these
fonts existed — SF Pro Black Expanded for display, SF Mono for numerals. A
missing file changes how the app looks; it never blanks a label or crashes.
```

- [ ] **Step 7: Commit**

```bash
git add ios/Bonedust/Resources/Fonts/ ios/project.yml ios/BonedustTests/AppLayerTests.swift
git commit -m "feat: bundle Rubik Dirt and Courier Prime"
```

---

### Task 5: Theme — derive the palette from lightLevel

**Files:**
- Create: `ios/Bonedust/UI/Theme.swift`
- Modify: `ios/BonedustTests/AppLayerTests.swift` (append)

**Interfaces:**
- Consumes: `Ink.day`, `Ink.night`, `Ink.lerp(from:to:_:)` from Task 3.
- Produces: `@Observable final class Theme` with `var lightLevel: Float` (settable) and `private(set) var ink: Ink`; `Theme.nightFraction(for:) -> Double` as a pure static for testing; and `EnvironmentValues.theme`. Task 6 and Task 9 both read `theme.ink`.

- [ ] **Step 1: Write the failing test**

Append to `ios/BonedustTests/AppLayerTests.swift`:

```swift
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
    /// the matrix is (123, 112, 91) against a mount that has itself darkened
    /// toward s8. That pair clears 3:1 by roughly 0.1, which is exactly the
    /// kind of margin that regresses silently when someone nudges `nightFloor`.
    ///
    /// Iterates the catalog, like Task 2's test: no night_dig literal, so a
    /// second dim site added later is covered.
    func testEverySiteMatrixSeparatesFromTheMountAtItsOwnLightLevel() {
        for site in ContentCatalog.shared.sites {
            let level = site.modifiers.lightLevel
            let onScreen = site.palette.matrix.scaled(level)
            // Read the mount the Theme actually produces. Modelling it as a
            // blend was left over from before the switch ruling: it overstated
            // day-side dim sites and could not see `switchPoint` move at all.
            let theme = Theme()
            theme.lightLevel = level
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/ThemeTests`
Expected: FAIL to compile — "cannot find 'Theme' in scope".

- [ ] **Step 3: Write the implementation**

Create `ios/Bonedust/UI/Theme.swift`:

```swift
import SwiftUI

/// Holds the palette the whole page is currently drawn in.
///
/// Night digs used to dim only the slab. Against a cream page that reads as a
/// rendering bug, so one `lightLevel` now drives both surfaces: the page darkens
/// toward lamplight as the slab does. The pleasant side effect is a real dark mode.
@Observable
final class Theme {

    /// Where the page stops getting darker. Below this the slab keeps dimming but
    /// the page does not, because a notebook under a headlamp is not black.
    static let nightFloor: Float = 0.35

    /// Where the palette flips. A switch, not a blend: see spec §6. Blending two
    /// inverted palettes drives text and page together — ink-on-page is 1.09:1 at
    /// the midpoint, and night_dig's lightLevel 0.55 lands at t=0.69, i.e. 2.52:1.
    static let switchPoint: Double = 0.5

    var lightLevel: Float = 1 {
        didSet { ink = Theme.nightFraction(for: lightLevel) >= Theme.switchPoint ? .night : .day }
    }

    private(set) var ink: Ink = .day

    init() {}

    /// How far toward the night palette a given light level sits, 0...1.
    ///
    /// Pure and static so the clamping can be tested without a view. NaN maps to
    /// daylight rather than propagating: an unreadable page is worse than a page
    /// that ignores a bad input.
    ///
    /// `Theme` is deliberately not `@MainActor`: `EnvironmentValues` builds its
    /// default value outside any actor, and isolating the class makes `@Entry`
    /// fail to compile.
    static func nightFraction(for lightLevel: Float) -> Double {
        guard lightLevel.isFinite else { return lightLevel < 0 ? 1 : 0 }
        let span = 1 - nightFloor
        let raw = (1 - lightLevel) / span
        return Double(min(max(raw, 0), 1))
    }
}

extension EnvironmentValues {
    /// One shared instance, not `Theme()` inline.
    ///
    /// `@Entry`'s default expression is evaluated on every read, so writing
    /// `@Entry var theme = Theme()` hands each reading view its own Theme. Views
    /// that were never explicitly injected would then disagree about the palette,
    /// and nothing would look wrong until two of them were on screen at once.
    fileprivate static let environmentDefault = Theme()

    @Entry var theme = Theme.environmentDefault
}
```

Note: `@Entry` requires iOS 17 with Xcode 16's macro, which this project has. If the macro is unavailable, replace the extension with an explicit `EnvironmentKey`.

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/ThemeTests`
Expected: PASS, 10 tests. night_dig now measures 3.56:1 against the 3.0 floor — the switch gives it the full `s8` mount instead of a partial blend, so the margin is wider than the 3.12 an earlier draft predicted.

- [ ] **Step 5: Commit**

```bash
git add ios/Bonedust/UI/Theme.swift ios/BonedustTests/AppLayerTests.swift
git commit -m "feat: Theme derives the palette from lightLevel"
```

---

### Task 6: The scene — page, mount, grid, paper

**Files:**
- Modify: `ios/Bonedust/Dig/DigScene.swift`

**Interfaces:**
- Consumes: `Earth` from Task 1; `Ink`, `Measure.mountMargin` from Task 3; `Theme` from Task 5.
- Produces: `DigScene.applyTheme(ink:)` and `DigScene.bloomFracture(at:)`, both called by later tasks.

**zPosition order after this task:** grid `-3`, paper fibre `-2`, mount `-1`, slab `0`, dust emitter `1` (unchanged).

- [ ] **Step 1: Replace the hardcoded background**

`DigScene.swift:41` currently reads:

```swift
backgroundColor = SKColor(red: 0x22 / 255, green: 0x18 / 255, blue: 0x13 / 255, alpha: 1)
```

Replace with:

```swift
backgroundColor = SKColor(Earth.s1)
```

and add near the top of the file, after the existing imports:

```swift
extension SKColor {
    convenience init(_ rgb: RGB8) {
        self.init(
            red: CGFloat(rgb.r) / 255,
            green: CGFloat(rgb.g) / 255,
            blue: CGFloat(rgb.b) / 255,
            alpha: 1
        )
    }
}
```

This also kills a duplicated source of truth: the old literal was `Ink.ground`'s value typed out a second time.

- [ ] **Step 2: Add the backdrop nodes**

Add these properties alongside the existing `slabNode` / `slabTexture`:

```swift
private var gridNode: SKSpriteNode?
private var paperNode: SKSpriteNode?
private var mountNode: SKSpriteNode?
```

Add this method, and call it from the same place `buildSlab()` is called, immediately before it so the backdrop is built first:

```swift
/// The page furniture behind the slab.
///
/// Three layers, cheapest first. The grid and paper are regenerated on resize
/// rather than tiled with a shader, because a resize happens about twice in a
/// session and a shader would be a lot of machinery for that.
private func buildBackdrop() {
    gridNode?.removeFromParent()
    paperNode?.removeFromParent()
    mountNode?.removeFromParent()

    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    let contrastRaised = UIAccessibility.isDarkerSystemColorsEnabled

    // Graph grid. Dropped entirely under Increase Contrast: a 0.35-alpha dot
    // pattern is exactly the low-contrast decoration that setting exists to
    // remove, and leaving it in would be noise. See Review Focus 5.
    if !contrastRaised, let texture = DigScene.gridTexture(size: size) {
        let node = SKSpriteNode(texture: texture)
        node.position = centre
        node.zPosition = -3
        addChild(node)
        gridNode = node
    }

    // Paper fibre. Same reasoning, and it is 3% alpha, so it is the first thing
    // to go.
    if !contrastRaised, let texture = DigScene.paperTexture() {
        let node = SKSpriteNode(texture: texture)
        node.position = centre
        node.size = size
        node.alpha = 0.03
        node.zPosition = -2
        addChild(node)
        paperNode = node
    }

    // The mount. This one is never optional: it is what stops a cleared slab
    // from vanishing into the page, so Increase Contrast makes it more
    // necessary, not less.
    let mount = SKSpriteNode(color: SKColor(Earth.mount), size: .zero)
    mount.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    mount.position = centre
    mount.zPosition = -1
    addChild(mount)
    mountNode = mount
    layoutMount()
}

private func layoutMount() {
    let inset = Measure.mountMargin * 2
    mountNode?.size = CGSize(width: size.width + inset, height: size.height + inset)
    mountNode?.position = CGPoint(x: size.width / 2, y: size.height / 2)
}

/// An 8pt dotted rule. One screen-sized texture beats hundreds of nodes.
private static func gridTexture(size: CGSize) -> SKTexture? {
    guard size.width > 0, size.height > 0 else { return nil }
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
        let cg = context.cgContext
        cg.setFillColor(SKColor(Earth.s3).withAlphaComponent(0.35).cgColor)
        let step: CGFloat = 8
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = 0
            while x < size.width {
                cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                x += step
            }
            y += step
        }
    }
    return SKTexture(image: image)
}

/// A 256x256 noise tile, generated once and reused.
///
/// Generated rather than shipped so it tints with the ramp and keeps the bundle
/// flat. `CIFilter.randomGenerator` is high-frequency on its own, so it is blurred
/// and desaturated before use; raw it looks like television static.
private static let paperTextureCache: SKTexture? = {
    let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
    guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage,
          let mono = CIFilter(
              name: "CIColorControls",
              parameters: [kCIInputImageKey: noise, kCIInputSaturationKey: 0]
          )?.outputImage,
          let blurred = CIFilter(
              name: "CIGaussianBlur",
              parameters: [kCIInputImageKey: mono, kCIInputRadiusKey: 0.6]
          )?.outputImage
    else { return nil }

    let context = CIContext()
    guard let cgImage = context.createCGImage(blurred, from: extent) else { return nil }
    return SKTexture(image: UIImage(cgImage: cgImage))
}()

private static func paperTexture() -> SKTexture? { paperTextureCache }

/// Repaints the backdrop when the theme changes. Called by DigView.
///
/// Named `applyTheme` rather than `apply` because `DigScene` already has a
/// private `apply(_:at:engine:)` for stroke results, and two unrelated methods
/// called `apply` on one scene is a trap for whoever reads this next.
func applyTheme(ink: Ink) {
    backgroundColor = SKColor(UIColor(ink.page))
    mountNode?.color = SKColor(UIColor(ink.mount))
}
```

- [ ] **Step 3: Keep the backdrop sized on rotation and resize**

`didChangeSize(_:)` currently resizes only the slab. Add the backdrop:

```swift
override func didChangeSize(_ oldSize: CGSize) {
    super.didChangeSize(oldSize)
    slabNode?.size = size
    slabNode?.position = CGPoint(x: size.width / 2, y: size.height / 2)

    // The grid is baked at a specific size, so it is rebuilt rather than scaled —
    // stretching it would turn round dots into ovals.
    buildBackdrop()
}
```

- [ ] **Step 4: Build and look at it**

Run: `xcodebuild build -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM"`
Expected: SUCCESS.

Then launch and confirm by eye:
- The page behind the slab is cream, not dark umber.
- A dark mount band is visible around all four edges of the slab.
- The dotted grid is visible but quiet on the page.
- Settings → Accessibility → Display & Text Size → **Increase Contrast** on: grid and paper disappear, mount stays.
- Rotate on iPad: the grid dots stay round.

- [ ] **Step 5: Commit**

```bash
git add ios/Bonedust/Dig/DigScene.swift
git commit -m "feat: cream page, specimen mount, graph grid, paper fibre"
```

---

### Task 7: Fracture feedback — the bloom and the hatch

Spec §5 splits red into two behaviours so one hue can mean two things. Both halves ship here, because either alone is wrong: the bloom without the hatch leaves no record, and the hatch without the bloom is too slow to read mid-stroke.

- **The bloom** is the alarm. A stamp-red ink bleed at the point of fracture, gone in 200ms. Red *in motion*.
- **The hatch** is the record. A permanent diagonal over fractured cells. Red at rest stays reserved for buttons, which never animate, so the two never compete.

**Files:**
- Modify: `ios/Bonedust/Dig/SlabRenderer.swift` (the hatch)
- Modify: `ios/Bonedust/Dig/DigScene.swift` (the bloom)
- Modify: `ios/BonedustTests/AppLayerTests.swift` (append)

**Interfaces:**
- Consumes: `Earth.s8` and `Earth.stamp` from Task 1.
- Produces: `SlabRenderer.isHatched(x:y:)`, `SlabRenderer.hatched(_:x:y:)`, `DigScene.bloomFracture(at:)`.

- [ ] **Step 1: Write the failing test**

Append to `ios/BonedustTests/AppLayerTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/FractureHatchTests`
Expected: FAIL to compile — "type 'SlabRenderer' has no member 'isHatched'".

- [ ] **Step 3: Write the implementation**

In `ios/Bonedust/Dig/SlabRenderer.swift`, add to the `// MARK: - Per-cell colour` section:

```swift
/// Whether a cell falls on a hatch stripe.
///
/// `(x + y)` is what makes it diagonal; `% 4 < 2` is what makes it 2 on, 2 off.
/// Internal rather than private so the pattern can be tested directly — the
/// alternative is reconstructing it from pixel bytes, which tests the test.
static func isHatched(x: Int, y: Int) -> Bool {
    (x + y) % 4 < 2
}

/// Darkens a cell that sits on a hatch stripe, leaves the rest alone.
static func hatched(_ colour: RGB8, x: Int, y: Int) -> RGB8 {
    isHatched(x: x, y: y) ? colour.lerp(to: Earth.s8, 0.5) : colour
}
```

Then, in `colour(_:_:_:_:)`, immediately after the bone edge-shading block and before the `revealBuriedBone` block, insert:

```swift
// Fracture leaves a permanent record on the page. The transient red bloom is
// the alarm; this is the annotation that stays. See spec §5.
if cell.flags & SlabGrid.Flag.cracked != 0 {
    result = SlabRenderer.hatched(result, x: x, y: y)
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/FractureHatchTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Add the bloom to the scene**

In `ios/Bonedust/Dig/DigScene.swift`, add alongside `emitDust(_:at:)`:

```swift
/// A red ink bleed at the point of fracture.
///
/// This is the *motion* half of spec §5. It exists for 200ms and then it is gone,
/// which is what lets the same red sit flat and permanent on a button without the
/// two reading as the same thing. The lasting record is the hatch, in SlabRenderer.
func bloomFracture(at point: Vec2) {
    let bloom = SKShapeNode(circleOfRadius: 4)
    bloom.fillColor = SKColor(Earth.stamp)
    bloom.strokeColor = .clear
    bloom.alpha = 0.9
    // Same grid-to-scene conversion the dust emitter uses; see `emitDust`.
    bloom.position = CGPoint(
        x: CGFloat(point.x) / CGFloat(SlabGrid.width) * size.width,
        y: (1 - CGFloat(point.y) / CGFloat(SlabGrid.height)) * size.height
    )
    bloom.zPosition = 2
    addChild(bloom)
    bloom.run(.sequence([
        .group([.scale(to: 5, duration: 0.2), .fadeOut(withDuration: 0.2)]),
        .removeFromParent(),
    ]))
}
```

Check the two position lines against the existing conversion at `DigScene.swift:237` and match it exactly rather than trusting the above — if `emitDust` flips the y axis differently, the bloom will appear mirrored.

- [ ] **Step 6: Trigger it**

In `apply(_ result: StrokeResult, at point: Vec2, engine: DigEngine)` around `DigScene.swift:201`, next to the existing dust call:

```swift
if result.cracksStarted > 0 { bloomFracture(at: point) }
```

`StrokeResult.cracksStarted` is the same signal `DigEngine.swift:201` already uses to set `hasCracked`, so no new engine plumbing is needed.

- [ ] **Step 7: Confirm the bloom and the hatch agree by eye**

Launch, pick `green_river` (its twist is "the fish are paper. Cracks come at a third again the usual rate", so it fractures readily), and brush fast until something cracks. Confirm:
- A red bleed appears at the brush and is gone inside a blink.
- The cracked area keeps a visible diagonal hatch afterwards.
- The hatch is legible against bone *and* against matrix.

- [ ] **Step 8: Confirm the Core suite is unaffected**

Run: `cd ios/BonedustCore && swift test`
Expected: PASS. Cracking behaviour is unchanged; only its appearance moved.

- [ ] **Step 9: Commit**

```bash
git add ios/Bonedust/Dig/SlabRenderer.swift ios/Bonedust/Dig/DigScene.swift \
        ios/BonedustTests/AppLayerTests.swift
git commit -m "feat: fracture blooms red, then keeps a diagonal hatch"
```

---

### Task 8: The cel pass and the stipple tell

Spec §7 and §7a. The slab is already four discrete palette colours per layer; the renderer smears them. This flattens the smear and adds a real edge.

**Files:**
- Modify: `ios/BonedustCore/Sources/BonedustCore/Sim/SimTuning.swift`
- Modify: `ios/Bonedust/Dig/SlabRenderer.swift`
- Modify: `ios/BonedustTests/AppLayerTests.swift` (append)

**Interfaces:**
- Consumes: `Earth.s8` from Task 1; `SlabRenderer.isHatched(x:y:)` from Task 7.
- Produces: `SimTuning.boneTellStipple`; `SlabRenderer.isStippled(x:y:)`, `SlabRenderer.celShade(_:)`, `SlabRenderer.inkEdge(_:_:_:)`.

**The rule that governs this whole task:** quantize the *lighting*, never the albedo. Posterizing each channel independently shifts hue — on the standard palette at 8 levels, `topsoil RGB8(74, 52, 40)` lands on `(73, 36, 36)`, visibly redder — and `cellNoise` then flips neighbouring cells between buckets, which reads as static. Every palette value stays exact.

- [ ] **Step 1: Add the tuning constant**

In `SimTuning.swift`, in the `// MARK: Presentation` block, directly after `boneTellTint`:

```swift
    /// The tell as a pattern rather than a tint: how far a stippled cell goes
    /// toward bone. Ships at 0.60 with `boneTellTint` at 0, but both stay live so
    /// the debug overlay's sliders can A/B them without a rebuild. Set this to 0
    /// and `boneTellTint` to 0.20 for the pre-cel behaviour.
    public var boneTellStipple: Float = 0.60
```

and change `boneTellTint`'s default from `0.20` to `0`.

- [ ] **Step 2: Write the failing tests**

Append to `ios/BonedustTests/AppLayerTests.swift`:

```swift
final class CelShadingTests: XCTestCase {

    /// The stipple is a 1-in-4 grid of isolated dots. Isolated matters: a 50%
    /// checkerboard averages back into a flat tint at this cell size.
    func testStippleIsAOneInFourGridOfIsolatedCells() {
        XCTAssertTrue(SlabRenderer.isStippled(x: 0, y: 0))
        XCTAssertFalse(SlabRenderer.isStippled(x: 1, y: 0))
        XCTAssertFalse(SlabRenderer.isStippled(x: 0, y: 1))
        XCTAssertTrue(SlabRenderer.isStippled(x: 2, y: 2))
        // No two stippled cells are orthogonally adjacent.
        for y in 0..<8 {
            for x in 0..<8 where SlabRenderer.isStippled(x: x, y: y) {
                XCTAssertFalse(SlabRenderer.isStippled(x: x + 1, y: y))
                XCTAssertFalse(SlabRenderer.isStippled(x: x, y: y + 1))
            }
        }
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
        XCTAssertEqual(SlabRenderer.celShade(0.9), 1 - 0.07, accuracy: 0.0001)
        XCTAssertEqual(SlabRenderer.celShade(0.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(SlabRenderer.celShade(-0.9), 1 + 0.07, accuracy: 0.0001)

        // A scaled colour keeps its channel ratios; a posterized one does not.
        let topsoil = SlabPalette.standard.topsoil
        let shaded = topsoil.scaled(SlabRenderer.celShade(0.9))
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
    func testInkEdgeMakesBoneSeparateFromMatrixOnEverySite() {
        let ink = RGB8(0x1C, 0x1A, 0x17)   // Earth.s8
        for site in ContentCatalog.shared.sites {
            let matrix = site.palette.matrix
            let bare = site.palette.bone.contrastRatio(against: matrix)
            let edged = site.palette.bone.lerp(to: ink, 0.72).contrastRatio(against: matrix)

            XCTAssertGreaterThanOrEqual(
                edged, 3.0,
                "site '\(site.id)': the ink edge does not separate bone from matrix (\(edged))"
            )
            XCTAssertGreaterThan(
                edged, bare,
                "site '\(site.id)': the ink edge is weaker than the bare fill it replaced"
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
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/CelShadingTests`
Expected: FAIL to compile — `isStippled`, `celShade`, `inkEdge` do not exist.

- [ ] **Step 4: Add the helpers**

In `SlabRenderer.swift`, beside `isHatched(x:y:)`:

```swift
/// The tell's dot grid: 1 in 4, no two orthogonally adjacent.
///
/// Isolated dots matter. A 50% checkerboard averages back into a flat tint at
/// this cell size, which is the problem the stipple exists to solve.
static func isStippled(x: Int, y: Int) -> Bool {
    x % 2 == 0 && y % 2 == 0
}

/// Per-cell noise as a stepped shade multiplier rather than a continuous one.
///
/// Returns a multiplier, never a colour, because quantizing colour channels
/// shifts hue: topsoil (74,52,40) posterized at 8 levels lands on (73,36,36).
static func celShade(_ noise: Float) -> Float {
    if noise > 0.33 { return 1 - SimTuning.standard.cellNoise }
    if noise < -0.33 { return 1 + SimTuning.standard.cellNoise }
    return 1
}

/// Whether this cell takes an ink edge.
///
/// `runBehind` is how many cells of the same material sit in the opposite
/// direction. Under 3 and the edge is skipped, so a paper-thin fossil keeps an
/// interior instead of becoming solid outline.
static func inkEdge(runBehind: Int, neighbourDiffers: Bool) -> Bool {
    neighbourDiffers && runBehind >= 3
}
```

- [ ] **Step 5: Wire the pass into `colour()`**

Four edits inside `colour(_:_:_:_:)`:

**a. Step the wear** — replace the wear blend's fraction:

```swift
if cell.depth > 0, cell.wear > 0 {
    // Cel: wear advances in four visible steps rather than a gradient. The
    // renderer's note about brushing feeling unresponsive still holds, so the
    // blend stays; only its resolution changes.
    let wear = (cell.wear * 4).rounded() / 4
    result = result.lerp(
        to: surface(cell, depth: cell.depth - 1, style),
        wear * style.tuning.wearColorBlend
    )
}
```

**b. Drop the soft bone relief.** Delete the `boneAbove` / `boneBelow` block and its two `scaled(1.12)` / `scaled(0.86)` calls. The ink edge replaces it.

**c. Add the ink edge**, where that block was:

```swift
// A semantic edge, drawn from flags rather than colour difference — which is
// why this is on the CPU. A fragment shader cannot tell gem-on-matrix from a
// noise boundary. Right and bottom only: two sides read as ink without eating
// a thin specimen from both ends.
if cell.depth == 0, cell.flags & (SlabGrid.Flag.bone | SlabGrid.Flag.gem) != 0 {
    let mine = cell.flags & SlabGrid.Flag.bone != 0
        ? SlabGrid.Flag.bone : SlabGrid.Flag.gem
    func same(_ dx: Int, _ dy: Int) -> Bool {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, nx < SlabRenderer.width, ny >= 0, ny < SlabRenderer.height
        else { return false }
        let n = grid.cells[SlabGrid.index(nx, ny)]
        return n.depth == 0 && n.flags & mine != 0
    }
    let right = SlabRenderer.inkEdge(
        runBehind: same(-1, 0) ? (same(-2, 0) ? 3 : 2) : 1,
        neighbourDiffers: !same(1, 0)
    )
    let down = SlabRenderer.inkEdge(
        runBehind: same(0, -1) ? (same(0, -2) ? 3 : 2) : 1,
        neighbourDiffers: !same(0, 1)
    )
    if right || down { result = result.lerp(to: Earth.s8, 0.72) }
}
```

**d. Step the noise** — replace `result = result.scaled(1 + cell.noise * style.tuning.cellNoise)` with:

```swift
result = result.scaled(SlabRenderer.celShade(cell.noise))
```

- [ ] **Step 6: Make the tell a stipple**

In `surface(_:depth:_:)`, replace the `boneTellTint` block:

```swift
// The tell, from §3: the only legitimate way to read the fossil before
// exposing it. A pattern rather than a tint, so it survives any future
// posterize — and so it is legible at all; the 20% tint is close to invisible
// once the cel pass flattens everything around it. Both constants stay live
// so the debug overlay can A/B them. See spec §7a.
if depth == 1, cell.flags & SlabGrid.Flag.bone != 0 {
    if style.tuning.boneTellTint > 0 {
        layer = layer.lerp(to: palette.bone, style.tuning.boneTellTint)
    }
    if style.tuning.boneTellStipple > 0, SlabRenderer.isStippled(x: x, y: y) {
        layer = layer.lerp(to: palette.bone, style.tuning.boneTellStipple)
    }
}
```

`surface` does not currently take `x` and `y`. Thread them through from `colour()`; both call sites are in that one function.

- [ ] **Step 7: Run the tests**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM" -only-testing:BonedustTests/CelShadingTests`
Expected: PASS, 5 tests. The per-site edge test is the one carried over from Task 2 — green_river should land near 5.49:1 against a bare-fill 1.14:1.

- [ ] **Step 8: Confirm the Core suite is unaffected**

Run: `cd ios/BonedustCore && swift test`
Expected: PASS. `SimTuning` gained a field; `bonedust-tool dump-constants` writes it out and nothing reads it server-side yet.

- [ ] **Step 9: A/B the tell on device**

Open the debug overlay and move the two sliders. Dig a `charmouth` slab to the point where sandstone covers the shell, then compare:
- `boneTellStipple 0.60`, `boneTellTint 0` — the ship default
- `boneTellStipple 0`, `boneTellTint 0.20` — today's behaviour

**This is a game-feel call, not a visual one.** The stipple is louder, and the renderer's own comment says reading the tell separates a careful player from a fast one. If the stipple gives it away, drop it toward 0.35 or restore the tint. Record which you picked and why.

- [ ] **Step 10: Commit**

```bash
git add ios/BonedustCore/Sources/BonedustCore/Sim/SimTuning.swift \
        ios/Bonedust/Dig/SlabRenderer.swift ios/BonedustTests/AppLayerTests.swift
git commit -m "feat: cel pass -- stepped shade, ink edge, stippled tell"
```

---

### Task 9: Migrate the 51 call sites

**Files:**
- Modify: `ios/Bonedust/App/RootView.swift` (20 `Ink.` references)
- Modify: `ios/Bonedust/Dig/DigView.swift` (22 `Ink.` references)
- Modify: `ios/Bonedust/UI/SpeedMeter.swift` (9 `Ink.` references)
- Modify: `ios/Bonedust/UI/DesignTokens.swift` (delete the deprecated block)

`ios/Bonedust/UI/DebugOverlay.swift` is **not** in this list. It references no design token.

**Interfaces:**
- Consumes: `Ink` instance properties and `Theme` from Tasks 3 and 5; `DigScene.apply(ink:)` from Task 6.
- Produces: nothing.

**The rename map.** Apply it mechanically:

| Old | New |
|---|---|
| `Ink.ground` | `theme.ink.page` |
| `Ink.ivory` | `theme.ink.ink` |
| `Ink.accent` | `theme.ink.stamp` |
| `Ink.danger` | `theme.ink.stamp` |
| `Ink.raised` | `theme.ink.raised` |
| `Ink.hairline` | `theme.ink.hairline` |
| `Ink.muted` | `theme.ink.muted` |
| `Ink.safe` | `theme.ink.safe` |
| `Ink.gem` | `theme.ink.gem` |
| `Ink.launchBackground` | `theme.ink.page` |

Two things to watch while substituting:

- **`Ink.danger` and `Ink.accent` now collapse to the same colour.** Anywhere they previously sat side by side to distinguish two states, that distinction is gone and the state must be carried another way. `SpeedMeter.swift:32` and `:42` use `isOverSafe ? Ink.danger : …` — over-safe now reads through *weight and motion*, not hue. Make the over-safe bar pulse its opacity between 0.65 and 1.0 over 0.5s rather than changing colour.
- **`RootView.swift:95`, `:233`, `DigView.swift:179`, `:306`** use `Ink.ground` as a *foreground* on an accent fill. That is now `theme.ink.page` on `theme.ink.stamp` — cream on stamp red, which is 4.8:1 and fine.

- [ ] **Step 1: Install the theme at the root**

In `ios/Bonedust/App/RootView.swift`, add the state and inject it. Near the top of the view:

```swift
@State private var theme = Theme()
```

and on the outermost view in `body`, alongside the existing `.tint(...)`:

```swift
.environment(\.theme, theme)
```

Change `.tint(Ink.accent)` at line 39 to `.tint(theme.ink.stamp)`.

- [ ] **Step 2: Read the theme in the two child views**

At the top of `DigView` and `SpeedMeter`:

```swift
@Environment(\.theme) private var theme
```

- [ ] **Step 3: Apply the rename map**

Work through all three files using the table above. After this step there must be zero matches for:

```bash
grep -rn 'Ink\.\(ground\|ivory\|accent\|danger\|raised\|hairline\|muted\|safe\|gem\|launchBackground\)' ios/Bonedust/
```

`Ink.day` inside `SpecimenRule` and `FieldLabel` in `DesignTokens.swift` stays — those are leaf views with no environment access, and they are correct in day mode.

- [ ] **Step 4: Drive the scene from the theme**

`lightLevel` is **not** a stream. `DigScene.swift:51` reads it once per dig:

```swift
renderer.lightLevel = engine.site.modifiers.lightLevel
```

There is no `engine.lightLevel` property and nothing to observe. Set the theme in
the same place, in `configureRenderer()`:

```swift
renderer.lightLevel = engine.site.modifiers.lightLevel
theme.lightLevel = engine.site.modifiers.lightLevel
applyTheme(ink: theme.ink)
```

`DigScene` needs the theme handed to it, since a scene has no SwiftUI environment.
Add `var theme: Theme?` to the scene and set it from `DigView` where the scene is
constructed, then guard the three lines above on it.

**Expected result for the one night site:** `night_dig` has `lightLevel: 0.55`,
so `nightFraction(0.55)` is about 0.69 — a dusky page, not full night. The 0.35
floor is defensive and no current site reaches it. That is correct; do not
"fix" the floor to make night_dig bottom out.

- [ ] **Step 5: Delete the deprecated block**

Remove the entire `// MARK: - Deprecated static accessors` extension from `DesignTokens.swift`.

- [ ] **Step 6: Build and verify the grep is clean**

```bash
xcodebuild build -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM"
grep -rn 'Ink\.\(ground\|ivory\|accent\|danger\)' ios/Bonedust/ && echo "STILL REFERENCED" || echo "clean"
```
Expected: build SUCCESS, grep prints `clean`.

- [ ] **Step 7: Run the whole suite**

Run: `xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM"`
Expected: PASS.

- [ ] **Step 8: Look at it at an accessibility text size**

Launch, then Settings → Accessibility → Display & Text Size → Larger Text → maximum. Confirm the HUD readouts in `DigView` do not clip or overlap. This is the Review Focus 4 case that a unit test cannot see.

- [ ] **Step 9: Commit**

```bash
git add ios/Bonedust/App/RootView.swift ios/Bonedust/Dig/DigView.swift \
        ios/Bonedust/UI/SpeedMeter.swift ios/Bonedust/UI/DesignTokens.swift
git commit -m "refactor: migrate every view to the day/night Ink palette"
```

---

### Task 10: Launch background and app icon

**Files:**
- Modify: `ios/Bonedust/Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json`
- Modify: `ios/Bonedust/Resources/Assets.xcassets/AppIcon.appiconset/`

**Interfaces:** none.

**Why this is not cosmetic:** `UILaunchScreen.UIColorName` points at `LaunchBackground`. Left dark, every cold start flashes dark umber before the cream page appears.

- [ ] **Step 1: Repoint the launch colour**

Set the colour in `LaunchBackground.colorset/Contents.json` to `earth1`, sRGB `0.929 / 0.894 / 0.812` (`#EDE4CF`), alpha 1. Keep the existing JSON shape; change only the components.

- [ ] **Step 2: Verify there is no flash**

Launch from cold on the simulator. The launch screen and the first frame of `RootView` must be the same cream. Any visible dark frame means the colorset did not take.

- [ ] **Step 3: Regenerate the app icon**

Render the icon against `earth1` with the wordmark in Rubik Dirt and the stamp red accent. Replace the contents of `AppIcon.appiconset`, keeping `Contents.json`'s existing slot structure.

- [ ] **Step 4: Commit**

```bash
git add ios/Bonedust/Resources/Assets.xcassets/
git commit -m "feat: launch background and icon follow the cream page"
```

---

## Done

Run the full sweep:

```bash
cd ios/BonedustCore && swift test && cd ..
xcodebuild test -scheme Bonedust -destination "platform=iOS Simulator,name=$SIM"
```

Then look at the app in daylight and in a dark room, on a night-dig site and a day site, at default and maximum text size, with Increase Contrast both off and on.
