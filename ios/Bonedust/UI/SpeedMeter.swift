import SwiftUI

/// §3's speed meter: a thin bar under the slab, green below the tool's safe speed and
/// red above it, with a visible tick at the limit.
///
/// The bar must not rely on colour (§7), so the safe limit is marked by a notch the
/// fill visibly crosses, and the state is also spelled out in words. A player who
/// cannot distinguish the green from the red can still see the fill pass the notch
/// and read "TOO FAST" — which, with the crack haptic, is three independent channels
/// carrying the same information.
struct SpeedMeter: View {

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
                Text(isOverSafe ? "TOO FAST" : "SAFE")
                    .font(Typography.label(.caption2))
                    .tracking(1.1)
                    .foregroundStyle(isOverSafe ? Ink.danger : Ink.safe)
                    .animation(nil, value: isOverSafe)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Ink.raised)

                    Capsule(style: .continuous)
                        .fill(isOverSafe ? Ink.danger : Ink.safe)
                        .frame(width: max(2, geometry.size.width * fillFraction))

                    // The safe-limit notch. Full height and in the ground colour so it
                    // cuts the fill rather than sitting on top of it.
                    Rectangle()
                        .fill(Ink.ground)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * safeFraction - 1)

                    Rectangle()
                        .fill(Ink.ivory.opacity(0.9))
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

/// Daylight remaining. Turns to the accent colour in the last ten seconds, which is
/// also when the "Rush job" bonus window has closed, so the colour change is telling
/// the player something true rather than just adding urgency.
struct DaylightBar: View {

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
                    .foregroundStyle(isLow ? Ink.accent : Ink.muted)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Ink.raised)
                    Capsule(style: .continuous)
                        .fill(isLow ? Ink.accent : Ink.muted)
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

    let label: String
    let value: String
    var tint: Color = Ink.ivory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(text: label)
            Text(value)
                .font(Typography.number(.title3, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
