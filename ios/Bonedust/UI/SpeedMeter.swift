import SwiftUI

/// Red in motion means "you are breaking it" (spec §5).
///
/// The old danger red and the accent are one `stamp` now, so a state that used to be a
/// second red has to be carried by something other than hue. This is the carrier: the
/// view's opacity pulses between `floor` and 1, taking `halfCycle` each way.
///
/// It is a fade, not a scale or a slide, so it stays inside what Reduce Motion permits
/// (the fracture bloom makes the same substitution) and it keeps running when that
/// setting is on: it is the one cue here that does not depend on telling red from
/// green. At one cycle a second it is well under the three-flashes-a-second limit.
struct AlarmPulse: ViewModifier {
    let isActive: Bool

    /// Opacity at the dim end of the pulse.
    static let floor = 0.65
    /// Seconds from full opacity to `floor`, and again from `floor` back to full.
    static let halfCycle: TimeInterval = 0.5

    /// Opacity at `time`, in seconds: 1 at the start of a cycle, `floor` at its middle.
    ///
    /// Pure, and a function of absolute time rather than of when the view appeared, so
    /// every view that is pulsing at once beats together.
    static func opacity(at time: TimeInterval) -> Double {
        let phase = time / (2 * halfCycle)
        let wave = (1 + cos(2 * .pi * phase)) / 2
        return floor + (1 - floor) * wave
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            TimelineView(.animation) { timeline in
                content.opacity(Self.opacity(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        } else {
            // Not a paused timeline: at rest the view is exactly itself, and costs no frames.
            content
        }
    }
}

extension View {
    /// Pulses this view's opacity while `isActive`. See `AlarmPulse`.
    func alarmPulse(_ isActive: Bool) -> some View {
        modifier(AlarmPulse(isActive: isActive))
    }
}

/// §3's speed meter: a thin bar under the slab, green below the tool's safe speed and
/// red above it, with a visible tick at the limit.
///
/// The bar must not rely on colour (§7), so the safe limit is marked by a notch the
/// fill visibly crosses, the state is also spelled out in words, and over the limit the
/// bar pulses. A player who cannot distinguish the green from the red can still see the
/// fill pass the notch, see it beat, and read "TOO FAST" — which, with the crack
/// haptic, is four independent channels carrying the same information.
struct SpeedMeter: View {

    @Environment(\.theme) private var theme

    let speed: Float
    let safeSpeed: Float

    /// Full-scale is three times the safe speed, so the safe zone takes the first
    /// third of the bar. Showing more range would make careful brushing register as
    /// almost no movement at all.
    private var fullScale: Float { max(0.1, safeSpeed * 3) }
    private var fillFraction: CGFloat { CGFloat(min(1, max(0, speed / fullScale))) }
    private var safeFraction: CGFloat { CGFloat(min(1, safeSpeed / fullScale)) }
    private var isOverSafe: Bool { speed > safeSpeed }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                FieldLabel(text: "Brush speed")
                Spacer()
                // The words stay at full opacity: 11pt text has no room to dip to 0.65.
                Text(isOverSafe ? "TOO FAST" : "SAFE")
                    .font(Typography.label(.caption2))
                    .tracking(1.1)
                    .foregroundStyle(isOverSafe ? theme.ink.stamp : theme.ink.safe)
                    .animation(nil, value: isOverSafe)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(theme.ink.raised)

                    // Over the limit the fill is stamp red and it pulses. Red at rest
                    // means "press this" and red in motion means "you are breaking it",
                    // so it is the pulse that says which of the two this is.
                    Capsule(style: .continuous)
                        .fill(isOverSafe ? theme.ink.stamp : theme.ink.safe)
                        .frame(width: max(2, geometry.size.width * fillFraction))
                        .alarmPulse(isOverSafe)

                    // The safe-limit notch. Full height and in the page colour so it
                    // cuts the fill rather than sitting on top of it.
                    Rectangle()
                        .fill(theme.ink.page)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * safeFraction - 1)

                    Rectangle()
                        .fill(theme.ink.ink.opacity(0.9))
                        .frame(width: 1, height: 14)
                        .offset(x: geometry.size.width * safeFraction - 0.5, y: 0)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brush speed")
        .accessibilityValue(
            isOverSafe
                ? "Too fast. Above the safe limit for this tool, bone may crack."
                : "Safe. Below the limit for this tool."
        )
    }
}

/// Daylight remaining. Turns to the stamp colour in the last ten seconds, which is
/// also when the "Rush job" bonus window has closed, so the colour change is telling
/// the player something true rather than just adding urgency.
struct DaylightBar: View {

    @Environment(\.theme) private var theme

    let remaining: Float
    let total: Float

    private var fraction: CGFloat {
        total <= 0 ? 0 : CGFloat(min(1, max(0, remaining / total)))
    }
    private var isLow: Bool { remaining <= 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                FieldLabel(text: "Daylight")
                Spacer()
                Text("\(Int(remaining.rounded(.up)))s")
                    .font(Typography.number(.caption, weight: .semibold))
                    .foregroundStyle(isLow ? theme.ink.stamp : theme.ink.muted)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(theme.ink.raised)
                    Capsule(style: .continuous)
                        .fill(isLow ? theme.ink.stamp : theme.ink.muted)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daylight remaining")
        .accessibilityValue("\(Int(remaining.rounded())) seconds of \(Int(total)) ")
    }
}

/// One of the three readouts under the slab.
struct Readout: View {

    @Environment(\.theme) private var theme

    let label: String
    let value: String
    /// `nil` is the palette's ink.
    var tint: Color?
    /// The number pulses. For a value that is not merely off but getting worse: red in
    /// motion, spec §5.
    var isAlarmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(text: label)
            Text(value)
                .font(Typography.number(.title3, weight: .semibold))
                .foregroundStyle(tint ?? theme.ink.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .alarmPulse(isAlarmed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
