import BonedustCore
import SwiftUI

/// §7.4. One card, one button.
struct SlabResultsView: View {

    let record: SlabRecord
    let fossil: Fossil
    let run: RunState
    let onContinue: () -> Void

    private var isLastDay: Bool { record.day >= run.totalDays }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    FieldLabel(text: "Day \(record.day) of \(run.totalDays)")
                    Text(isLastDay ? "Last slab" : "Slab bagged")
                        .font(Typography.display(28))
                        .foregroundStyle(Ink.ivory)
                }
                .padding(.top, 20)

                SpecimenCard(
                    code: String(format: "BD-%04d", Int(record.seed % 9_000) + 1_000),
                    name: fossil.name,
                    period: fossil.period,
                    formation: fossil.formation,
                    baseValue: fossil.baseValue,
                    breakdown: record.payout,
                    gems: record.wholeGems,
                    bagged: record.bagged
                )

                installmentProgress

                Button(action: onContinue) {
                    Text(isLastDay ? "Settle with the Collector" : "Next slab")
                        .font(Typography.ui(.headline, weight: .bold))
                        .foregroundStyle(Ink.ground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Ink.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 28)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    /// The pressure gauge. This, not the daylight bar, is what the run is about.
    private var installmentProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                FieldLabel(text: "Owed by day \(run.totalDays)")
                Spacer()
                Text("$\(run.cash) / $\(run.installment)")
                    .font(Typography.number(.subheadline, weight: .semibold))
                    .foregroundStyle(run.isInstallmentCovered ? Ink.safe : Ink.ivory)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.raised)
                    Capsule()
                        .fill(run.isInstallmentCovered ? Ink.safe : Ink.accent)
                        .frame(
                            width: max(
                                2,
                                geometry.size.width
                                    * CGFloat(min(1, Double(run.cash) / Double(max(1, run.installment))))
                            )
                        )
                }
            }
            .frame(height: 8)
            Text(
                run.isInstallmentCovered
                    ? "Covered. Everything from here is Reputation."
                    : "$\(run.shortfall) short with \(run.totalDays - record.day) "
                        + "slab\(run.totalDays - record.day == 1 ? "" : "s") to go."
            )
            .font(Typography.ui(.caption))
            .foregroundStyle(run.isInstallmentCovered ? Ink.safe : Ink.muted)
        }
        .padding(13)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
