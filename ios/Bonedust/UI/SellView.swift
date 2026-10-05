import BonedustCore
import SwiftUI

/// Who gets the specimen.
///
/// The week's second decision, and the only one that is not a brush stroke. Every option is
/// compromised: Wheeler pays least and cannot cost you anything, the dealer pays well and is
/// noticed, the docks pay double and the crew sees none of it, and the museum pays worst and
/// is the only one selling your name back.
///
/// **Everything is shown before anything is committed** — the price, the attention it draws,
/// and the chance of losing the specimen outright. A seizure the player could not see coming
/// is a tax rather than a decision, and the decision is the whole point of the screen.
struct SellView: View {

    let record: SlabRecord
    let fossil: Fossil
    let run: RunState
    let onSell: (Buyer) -> Void

    private var catalog: ContentCatalog { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(catalog.buyers) { buyer in
                    row(buyer)
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.vertical, 16)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who gets it?")
                .font(Typography.ui(.title2, weight: .bold))
                .foregroundStyle(Ink.ivory)
            Text(fossil.name)
                .font(Typography.ui(.footnote))
                .foregroundStyle(Ink.muted)
            HeatBar(heat: run.heat)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ buyer: Buyer) -> some View {
        let quote = run.quote(record, buyer: buyer)
        Button {
            onSell(buyer)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(buyer.name)
                        .font(Typography.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.ivory)
                    Spacer(minLength: 8)
                    Text("$\(quote.price)")
                        .font(Typography.number(.title3, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.accent)
                }
                Text(buyer.blurb)
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    tag(heatLabel(quote.heat), tint: quote.heat > 0 ? Ink.danger : Ink.safe)
                    if quote.risk > 0 {
                        tag(
                            "\(Int((quote.risk * 100).rounded()))% SEIZED",
                            tint: quote.risk > 0.25 ? Ink.danger : Ink.accent
                        )
                    }
                    if !buyer.paysDebt {
                        tag("CREW GETS NOTHING", tint: Ink.danger)
                    }
                    if buyer.reputation > 0 {
                        tag("+\(buyer.reputation) REPUTATION", tint: Ink.safe)
                    }
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(Ink.hairline, lineWidth: Measure.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(buyer.name)
        .accessibilityValue(spoken(buyer, quote))
        .accessibilityAddTraits(.isButton)
    }

    /// VoiceOver gets the same three facts the tags carry, in the same order, because the
    /// decision cannot be made without all of them.
    private func spoken(
        _ buyer: Buyer, _ quote: (price: Int, heat: Int, risk: Float)
    ) -> String {
        var parts = ["\(quote.price) dollars"]
        parts.append(
            quote.heat > 0 ? "adds \(quote.heat) heat"
                : quote.heat < 0 ? "removes \(-quote.heat) heat"
                : "draws no attention"
        )
        if quote.risk > 0 {
            parts.append("\(Int((quote.risk * 100).rounded())) percent chance of seizure")
        }
        if !buyer.paysDebt { parts.append("nothing reaches the crew debt") }
        if buyer.reputation > 0 { parts.append("\(buyer.reputation) reputation") }
        return parts.joined(separator: ", ") + ". " + buyer.blurb
    }

    private func heatLabel(_ heat: Int) -> String {
        heat > 0 ? "+\(heat) HEAT" : heat < 0 ? "\(heat) HEAT" : "NO HEAT"
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Typography.label(.caption2))
            .tracking(0.9)
            .foregroundStyle(tint)
    }
}

/// How much attention you are carrying.
///
/// Shown wherever a sale is, because heat is only a puzzle if it is legible *between*
/// decisions rather than discovered at the moment it costs something.
struct HeatBar: View {

    let heat: Int

    private var fraction: CGFloat {
        CGFloat(min(max(Float(heat) / Float(SimTuning.standard.heatMaximum), 0), 1))
    }
    private var isWatched: Bool { heat > SimTuning.standard.heatSafeBelow }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                FieldLabel(text: "Attention")
                Spacer()
                Text(isWatched ? "BEING WATCHED" : "UNREMARKABLE")
                    .font(Typography.label(.caption2))
                    .tracking(1.1)
                    .foregroundStyle(isWatched ? Ink.danger : Ink.safe)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.raised)
                    Capsule()
                        .fill(isWatched ? Ink.danger : Ink.safe)
                        .frame(width: max(2, geometry.size.width * fraction))
                    // The notch where seizure becomes possible, so the threshold is a place
                    // on the bar rather than a number in a patch note.
                    Rectangle()
                        .fill(Ink.ivory.opacity(0.9))
                        .frame(width: 1, height: 14)
                        .offset(
                            x: geometry.size.width
                                * CGFloat(
                                    Float(SimTuning.standard.heatSafeBelow)
                                        / Float(SimTuning.standard.heatMaximum)
                                )
                        )
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Attention")
        .accessibilityValue(
            isWatched
                ? "\(heat). Being watched; sales can be seized."
                : "\(heat). Unremarkable; nothing will be seized."
        )
    }
}
