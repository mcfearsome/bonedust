import BonedustCore
import SwiftUI

/// §7.5. Three tools, three charms, one restock, and a number at the top telling you
/// how much of your cushion you are about to spend.
struct SupplyTentView: View {

    let run: RunState
    let day: Int
    let reputation: Int
    let onBuyTool: (String) -> Void
    let onBuyCharm: (String) -> Void
    let onSellTool: (String) -> Void
    let onSellCharm: (String) -> Void
    let onRestock: () -> Void
    let onLeave: () -> Void

    private var catalog: ContentCatalog { .shared }
    private var slabsLeft: Int { run.totalDays - day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ledger
                owned
                forSale
                leaveButton
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(text: "After day \(day) of \(run.totalDays)")
            Text("Supply tent")
                .font(Typography.display(30))
                .foregroundStyle(Ink.ivory)
        }
        .padding(.top, 24)
    }

    /// The whole decision, stated plainly. A player should never have to work out
    /// whether a purchase is affordable in their head.
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("$\(run.cash)")
                    .font(Typography.number(.title, weight: .bold))
                    .foregroundStyle(Ink.ivory)
                    .monospacedDigit()
                Text("in hand")
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(run.isInstallmentCovered
                            ? "Installment covered"
                            : "$\(run.shortfall) still owed")
                        .font(Typography.number(.footnote, weight: .semibold))
                        .foregroundStyle(run.isInstallmentCovered ? Ink.safe : Ink.accent)
                        .monospacedDigit()
                    Text("\(slabsLeft) slab\(slabsLeft == 1 ? "" : "s") left")
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted)
                }
            }
            SpecimenRule()
            Text(run.isInstallmentCovered
                    ? "Everything you spend now comes out of your Reputation."
                    : "Everything you spend now has to be dug back out of the ground.")
                .font(Typography.ui(.caption))
                .foregroundStyle(Ink.muted)
        }
        .padding(13)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
    }

    private var owned: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel(text: "Your kit")
                Spacer()
                Text("\(run.toolIDs.count)/\(RunState.toolSlots) tools  ·  "
                    + "\(run.charmIDs.count)/\(RunState.charmSlots) charms")
                    .font(Typography.number(.caption2))
                    .foregroundStyle(Ink.muted)
                    .monospacedDigit()
            }
            ForEach(run.toolIDs, id: \.self) { id in
                if let tool = catalog.tool(id) {
                    ownedRow(
                        name: tool.name,
                        blurb: tool.blurb,
                        refund: tool.resaleValue,
                        // The starting brush is not sellable: a run with no brush is a
                        // run you cannot play.
                        sellable: id != BrushTool.brush.id
                    ) { onSellTool(id) }
                }
            }
            ForEach(run.charmIDs, id: \.self) { id in
                if let charm = catalog.charm(id) {
                    ownedRow(
                        name: charm.name, blurb: charm.blurb,
                        refund: charm.resaleValue, sellable: true
                    ) { onSellCharm(id) }
                }
            }
        }
    }

    private func ownedRow(
        name: String, blurb: String, refund: Int, sellable: Bool, sell: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Typography.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.ivory)
                Text(blurb)
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if sellable {
                Button(action: sell) {
                    Text("Sell $\(refund)")
                        .font(Typography.number(.caption2, weight: .semibold))
                        .foregroundStyle(Ink.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Ink.hairline, lineWidth: Measure.hairline)
                        )
                }
                .accessibilityLabel("Sell \(name) for \(refund) dollars")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    private var forSale: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel(text: "For sale")
                Spacer()
                Button(action: onRestock) {
                    Text("Restock $\(Shop.restockPrice)")
                        .font(Typography.number(.caption2, weight: .semibold))
                        .foregroundStyle(run.cash >= Shop.restockPrice ? Ink.accent : Ink.hairline)
                }
                .disabled(run.cash < Shop.restockPrice)
            }
            ForEach(run.shop.toolIDs, id: \.self) { id in
                if let tool = catalog.tool(id) {
                    saleRow(
                        name: tool.name,
                        blurb: tool.blurb,
                        price: tool.price,
                        kind: tool.isBrush ? "Brush" : "Tool",
                        blocked: !run.hasToolSlot ? "No tool slot" : nil
                    ) { onBuyTool(id) }
                }
            }
            ForEach(run.shop.charmIDs, id: \.self) { id in
                if let charm = catalog.charm(id) {
                    saleRow(
                        name: charm.name,
                        blurb: charm.blurb,
                        price: charm.price,
                        kind: charm.pool == .vault ? "Vault charm" : "Charm",
                        blocked: !run.hasCharmSlot ? "No charm slot" : nil
                    ) { onBuyCharm(id) }
                }
            }
            if run.shop.isEmpty {
                Text("Nothing left worth selling you.")
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
            }
        }
    }

    private func saleRow(
        name: String, blurb: String, price: Int, kind: String,
        blocked: String?, buy: @escaping () -> Void
    ) -> some View {
        let affordable = run.cash >= price && blocked == nil
        return Button(action: buy) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(Typography.ui(.subheadline, weight: .semibold))
                            .foregroundStyle(affordable ? Ink.ivory : Ink.muted)
                        FieldLabel(text: kind)
                    }
                    Text(blurb)
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let blocked {
                        Text(blocked)
                            .font(Typography.label(.caption2))
                            .tracking(1)
                            .foregroundStyle(Ink.danger)
                    }
                }
                Spacer(minLength: 6)
                Text("$\(price)")
                    .font(Typography.number(.subheadline, weight: .bold))
                    .foregroundStyle(affordable ? Ink.accent : Ink.hairline)
                    .monospacedDigit()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(affordable ? Ink.hairline : Color.clear, lineWidth: Measure.hairline)
            )
            .opacity(affordable ? 1 : 0.5)
        }
        .disabled(!affordable)
        .accessibilityLabel("\(name), \(kind), \(price) dollars")
        .accessibilityValue(blocked ?? blurb)
    }

    private var leaveButton: some View {
        Button(action: onLeave) {
            Text("Day \(day + 1)")
                .font(Typography.ui(.headline, weight: .bold))
                .foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity)
                .scaledControlHeight(54)
                .background(Ink.accent)
                .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
        .accessibilityHint("Leaves the tent and starts the next slab.")
    }
}
