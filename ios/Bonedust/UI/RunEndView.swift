import BonedustCore
import SwiftUI

/// §7.6. Success or failure, then back to the title.
struct RunEndView: View {

    let run: RunState
    let meta: MetaProgress
    let onDone: () -> Void

    private var succeeded: Bool {
        if case .succeeded = run.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline
                stats
                Button(action: onDone) {
                    Text(succeeded ? "Take the next job" : "New run")
                        .font(Typography.ui(.headline, weight: .bold))
                        .foregroundStyle(Ink.ground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Ink.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.top, 28)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: succeeded ? "Installment paid" : "Run over")
            Text(succeeded ? "He signs the page." : "The Collector takes your tools as interest.")
                .font(Typography.display(27))
                .foregroundStyle(succeeded ? Ink.ivory : Ink.danger)
                .fixedSize(horizontal: false, vertical: true)
            if case .succeeded(let reputation, let leftover) = run.phase {
                Text("$\(leftover) left over became \(reputation) Reputation.")
                    .font(Typography.ui(.subheadline))
                    .foregroundStyle(Ink.muted)
            }
            if case .failed(let shortfall) = run.phase {
                Text("$\(shortfall) short of $\(run.installment).")
                    .font(Typography.ui(.subheadline))
                    .foregroundStyle(Ink.muted)
            }
        }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 11) {
            statRow("Earned this run", "$\(run.totalEarned)")
            statRow("Paid to the crew debt", "$\(run.crewContribution)", tint: Ink.accent)
            statRow("Best slab", "$\(run.slabs.map(\.payout.total).max() ?? 0)")
            SpecimenRule()
            statRow("Reputation", "\(meta.reputation)")
            statRow(
                "Next installment",
                "$\(meta.nextInstallment)",
                tint: succeeded ? Ink.accent : Ink.ivory
            )
            statRow("Run streak", "\(meta.currentStreak) (best \(meta.longestStreak))")
            if !succeeded {
                Text("The next installment resets to the first tier.")
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
            }
        }
        .padding(14)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
    }

    private func statRow(_ name: String, _ value: String, tint: Color = Ink.ivory) -> some View {
        HStack {
            Text(name)
                .font(Typography.ui(.subheadline))
                .foregroundStyle(Ink.muted)
            Spacer()
            Text(value)
                .font(Typography.number(.subheadline, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
