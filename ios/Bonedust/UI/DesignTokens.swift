import SwiftUI
import UIKit

/// §7's visual direction, as the only place colours and fonts are named.
///
/// Field geology and survey kit: warm dark umber ground, bone-ivory text, one
/// accent. Green and red appear *only* for speed and intact semantics, and teal
/// *only* for gems — so when the player sees orange it always means "this is the
/// thing to press", and when they see red it always means "you are breaking it".
enum Ink {
    /// Page background.
    static let ground = Color(hex: 0x221813)
    /// Cards and trays, one step up from the ground.
    static let raised = Color(hex: 0x2E201A)
    static let hairline = Color(hex: 0x4A382E)
    /// Primary text.
    static let ivory = Color(hex: 0xF1E7D3)
    /// Secondary text and small-caps labels.
    static let muted = Color(hex: 0xB8A389)
    /// Survey flagging orange. The single accent.
    static let accent = Color(hex: 0xFF6B2C)
    /// Gems only.
    static let gem = Color(hex: 0x56B8C8)
    /// Speed and intact semantics only.
    static let safe = Color(hex: 0x7FBF6A)
    static let danger = Color(hex: 0xE05437)

    static let launchBackground = ground
}

enum Measure {
    static let gutter: CGFloat = 16
    static let cardRadius: CGFloat = 4
    static let hairline: CGFloat = 1
}

/// Three faces, each with one job.
///
/// Display is a heavy expanded system face standing in for Rubik Dirt — see
/// `Resources/Fonts/README.md` for the drop-in. It is used for the wordmark and big
/// headings only. UI is SF Pro, which gets Dynamic Type right for free. Numbers are
/// SF Mono with tabular figures so a changing readout does not jitter its own layout.
enum Typography {

    static func display(_ size: CGFloat, relativeTo style: UIFont.TextStyle = .largeTitle) -> Font {
        let base = UIFont.systemFont(ofSize: size, weight: .black, width: .expanded)
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base))
    }

    static func ui(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default).weight(weight)
    }

    /// Small caps museum-label styling, per §7.
    static func label(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, design: .default).weight(.semibold)
    }

    /// Tabular figures. Use for every number that changes while you watch it.
    static func number(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A dashed rule, the museum-label motif from §7.
struct SpecimenRule: View {
    var body: some View {
        Rectangle()
            .fill(Ink.hairline)
            .frame(height: Measure.hairline)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                    }
                    .stroke(
                        Ink.muted.opacity(0.55),
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
            .foregroundStyle(Ink.muted)
    }
}
