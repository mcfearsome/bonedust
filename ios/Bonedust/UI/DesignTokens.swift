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
        muted: Color(Earth.s4),
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
    /// Apple's minimum comfortable target. Nothing tappable goes below it.
    static let minimumTarget: CGFloat = 44
}

/// A control height that grows with the player's text size.
///
/// §7 requires Dynamic Type everywhere outside the slab, and a button pinned to 54 points
/// clips its own label at the accessibility sizes — which is worse than a button that is
/// simply large, because the text that disappears is the one telling you what it does.
struct ScaledControlHeight: ViewModifier {
    // Needs a declared default even though `init` replaces it; the property wrapper
    // cannot be declared without a wrapped value.
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 54

    init(_ base: CGFloat) {
        _height = ScaledMetric(wrappedValue: base, relativeTo: .headline)
    }

    func body(content: Content) -> some View {
        content.frame(minHeight: max(Measure.minimumTarget, height))
    }
}

extension View {
    /// Replaces a fixed `.frame(height:)` on a control.
    func scaledControlHeight(_ base: CGFloat) -> some View {
        modifier(ScaledControlHeight(base))
    }
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
    // SwiftUI's `Font` is opaque, so a test cannot read a point size back out of it.
    // These mirror what `display` and `number` ask for, against an explicit trait
    // collection, which is what makes the Dynamic Type guarantee testable at all.

    static func resolvedDisplayPointSize(
        _ size: CGFloat, for traits: UITraitCollection
    ) -> CGFloat {
        let base = displayAvailable
            ? UIFont(name: displayFace, size: size)!
            : UIFont.systemFont(ofSize: size, weight: .black, width: .expanded)
        return UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: base, compatibleWith: traits).pointSize
    }

    static func resolvedNumberPointSize(
        _ size: CGFloat, for traits: UITraitCollection
    ) -> CGFloat {
        let base = numberAvailable
            ? UIFont(name: numberFace, size: size)!
            : UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
        return UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: base, compatibleWith: traits).pointSize
    }
}

// MARK: - Bridging

extension Color {
    init(_ rgb: RGB8) {
        self.init(
            .sRGB,
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255,
            opacity: 1
        )
    }

    /// Component-wise blend. Used only by `Ink.lerp`.
    func mixed(with other: Color, _ fraction: Double) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = CGFloat(min(max(fraction, 0), 1))
        return Color(
            .sRGB,
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t),
            opacity: Double(aa + (ba - aa) * t)
        )
    }
}

extension Font.TextStyle {
    /// SwiftUI and UIKit name the same styles with different types.
    var uiStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// The unscaled point size Apple specifies for each style at the default
    /// content size. `Font.custom(_:size:relativeTo:)` scales from here.
    var baseSize: CGFloat {
        UIFont.preferredFont(
            forTextStyle: uiStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
    }
}

/// A dashed rule, the museum-label motif from §7.
struct SpecimenRule: View {
    var body: some View {
        Rectangle()
            .fill(Ink.day.hairline)
            .frame(height: Measure.hairline)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                    }
                    .stroke(
                        Ink.day.muted.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }
            )
            .accessibilityHidden(true)
    }
}

/// Small-caps field label.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Typography.label())
            .tracking(1.1)
            .foregroundStyle(Ink.day.muted)
    }
}
