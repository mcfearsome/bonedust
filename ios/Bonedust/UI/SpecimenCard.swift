import BonedustCore
import SwiftUI

/// §7.4's museum label: dashed rules, small-caps field names, tabular figures.
///
/// A specimen card is the game's one piece of ceremony. It is deliberately the same
/// component on the results screen and in the Collection, because the whole fantasy is
/// that the thing you just dug out is now a catalogued object.
struct SpecimenCard: View {

    let code: String
    let name: String
    let period: String
    let formation: String
    let baseValue: Int
    let breakdown: PayoutBreakdown
    let gems: Int
    let bagged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            SpecimenRule()
            rows
            SpecimenRule()
            total
        }
        .padding(14)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                FieldLabel(text: code)
                Spacer()
                FieldLabel(text: bagged ? "Bagged" : "Out of daylight")
            }
            Text(name)
                .font(Typography.display(23))
                .foregroundStyle(Ink.ivory)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(period) · \(formation)")
                .font(Typography.ui(.caption))
                .foregroundStyle(Ink.muted)
        }
    }

    private var rows: some View {
        VStack(spacing: 4) {
            row("Exposed", percent(breakdown.exposure))
            row("Intact", percent(breakdown.intact),
                tint: breakdown.intact >= 0.9 ? Ink.ivory
                    : breakdown.intact >= 0.6 ? Ink.accent : Ink.danger)
            // "$84 of $90" makes the exposure and intact penalty concrete in money,
            // which is the only unit the player is actually budgeting in.
            // The base shown is the instance-adjusted one: three brachiopods really are
            // worth three brachiopods, and the card has to agree with the arithmetic.
            row("Fossil", "$\(breakdown.fossil) of $\(max(baseValue, breakdown.baseValue))")
            if gems > 0 {
                row(gems == 1 ? "Gem" : "Gems", "$\(breakdown.gems)", tint: Ink.gem)
            }
            if breakdown.bonuses > 0 {
                row("Bonuses", "$\(breakdown.bonuses)")
            }
            if breakdown.multiplier != 1 {
                row(
                    breakdown.rushApplied ? "Rush job" : "Multiplier",
                    String(format: "x%.2f", breakdown.multiplier),
                    tint: Ink.accent
                )
            }
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                FieldLabel(text: "Total")
                Spacer()
                Text("$\(breakdown.total)")
                    .font(Typography.number(.title2, weight: .bold))
                    .foregroundStyle(Ink.accent)
                    .monospacedDigit()
            }
            // Every dollar also pays the crew debt (§6). Saying so on every card is
            // what makes a solo run feel communal.
            Text("+$\(breakdown.total) to the crew debt")
                .font(Typography.ui(.caption2))
                .foregroundStyle(Ink.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ name: String, _ value: String, tint: Color = Ink.ivory) -> some View {
        HStack {
            Text(name)
                .font(Typography.ui(.caption))
                .foregroundStyle(Ink.muted)
            Spacer()
            Text(value)
                .font(Typography.number(.caption, weight: .medium))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
