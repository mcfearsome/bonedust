import BonedustCore
import SwiftUI

/// §7.1, minus the crew debt card — the ledger client arrives at M5 and a fabricated
/// debt figure would be worse than none.
struct TitleView: View {

    let coordinator: RunCoordinator
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                wordmark
                crewDebtCard
                if let problem = coordinator.resumeProblem { notice(problem) }
                if let run = coordinator.run { resumeCard(run) }
                standing
                actions
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.top, 36)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private var wordmark: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("BONEDUST")
                .font(Typography.display(44))
                .foregroundStyle(Ink.ivory)
            Text("Pay the Collector")
                .font(Typography.label(.caption))
                .tracking(1.4)
                .foregroundStyle(Ink.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bonedust. Pay the Collector.")
    }

    /// §7.1's crew debt card. Shown even with no figures yet, because the debt is the
    /// premise of the game and an empty space where it should be reads as a bug.
    @ViewBuilder
    private var crewDebtCard: some View {
        Button {
            coordinator.showCrewLedger()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    FieldLabel(text: "The crew owes")
                    Spacer()
                    if !coordinator.ledger.isReachable {
                        FieldLabel(text: "Offline")
                    }
                }
                Text(coordinator.ledger.hasEverLoaded
                        ? CrewLedgerView.money(coordinator.ledger.remaining)
                        : "—")
                    .font(Typography.number(.title, weight: .bold))
                    .foregroundStyle(Ink.ivory)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.ground)
                        Capsule()
                            .fill(Ink.accent)
                            .frame(
                                width: max(
                                    coordinator.ledger.fractionPaid > 0 ? 3 : 0,
                                    geometry.size.width * coordinator.ledger.fractionPaid
                                )
                            )
                    }
                }
                .frame(height: 7)
                if coordinator.ledger.queue.pending.isEmpty {
                    Text("Every dollar you dig comes off it.")
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted)
                } else {
                    Text("\(CrewLedgerView.money(coordinator.ledger.queue.pendingTotal)) of "
                        + "yours is waiting to send.")
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(Ink.hairline, lineWidth: Measure.hairline)
            )
        }
        .accessibilityLabel("Crew ledger")
        .accessibilityValue(
            coordinator.ledger.hasEverLoaded
                ? "\(CrewLedgerView.money(coordinator.ledger.remaining)) still owed"
                : "Not loaded yet"
        )
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(.caption))
            .foregroundStyle(Ink.ground)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.accent)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    private func resumeCard(_ run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Run in progress")
            Text(ContentCatalog.shared.site(run.siteID)?.name ?? run.siteID)
                .font(Typography.ui(.headline, weight: .semibold))
                .foregroundStyle(Ink.ivory)
            Text("Day \(run.currentDay) of \(run.totalDays) · $\(run.cash) of $\(run.installment)")
                .font(Typography.number(.caption))
                .foregroundStyle(Ink.muted)
                .monospacedDigit()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.accent.opacity(0.5), lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .combine)
    }

    private var standing: some View {
        HStack(spacing: 10) {
            Readout(label: "Reputation", value: "\(coordinator.meta.reputation)")
            Readout(label: "Next owed", value: "$\(coordinator.meta.nextInstallment)")
            Readout(
                label: "Streak",
                value: "\(coordinator.meta.currentStreak)",
                tint: coordinator.meta.currentStreak > 0 ? Ink.safe : Ink.ivory
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if coordinator.canContinue {
                primary("Continue run") { coordinator.continueRun() }
                secondary("New run") { coordinator.beginNewRun() }
            } else {
                primary("New run") { coordinator.beginNewRun() }
            }
            secondary("Collection") { coordinator.showCollection() }
            secondary("Crew Ledger") { coordinator.showCrewLedger() }
            secondary("Settings") { showSettings = true }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(.headline, weight: .bold))
                .foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity)
                .scaledControlHeight(54)
                .background(Ink.accent)
                .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.ivory)
                .frame(maxWidth: .infinity)
                .scaledControlHeight(48)
                .background(Ink.raised)
                .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Measure.cardRadius)
                        .stroke(Ink.hairline, lineWidth: Measure.hairline)
                )
        }
    }
}

/// §7.2. Unlocked sites as cards with the fossil table and the twist.
struct SiteSelectView: View {

    let coordinator: RunCoordinator
    let onPick: (String) -> Void
    let onCancel: () -> Void

    private var unlocked: Set<String> {
        Set(coordinator.unlockedSites.map(\.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    FieldLabel(text: "Tier \(coordinator.meta.nextTier)")
                    Text("Pick a site")
                        .font(Typography.display(30))
                        .foregroundStyle(Ink.ivory)
                    Text("$\(coordinator.meta.nextInstallment) due in five days.")
                        .font(Typography.ui(.subheadline))
                        .foregroundStyle(Ink.accent)
                }
                .padding(.top, 26)

                ForEach(ContentCatalog.shared.sites) { site in
                    card(site, isUnlocked: unlocked.contains(site.id))
                }

                Button(action: onCancel) {
                    Text("Back")
                        .font(Typography.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity)
                        .scaledControlHeight(46)
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 28)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private func card(_ site: Site, isUnlocked: Bool) -> some View {
        Button {
            if isUnlocked { onPick(site.id) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(site.name)
                        .font(Typography.ui(.headline, weight: .semibold))
                        .foregroundStyle(isUnlocked ? Ink.ivory : Ink.muted)
                    Spacer()
                    FieldLabel(text: site.period)
                }
                Text(site.twist)
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                SpecimenRule()
                // The fossil table, so the choice is informed rather than a name.
                Text(fossilPreview(site))
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !isUnlocked {
                    Text("Locked · \(site.unlock.label)")
                        .font(Typography.label(.caption2))
                        .tracking(1)
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(Ink.hairline, lineWidth: Measure.hairline)
            )
            .opacity(isUnlocked ? 1 : 0.55)
        }
        .disabled(!isUnlocked)
        .accessibilityLabel(site.name)
        .accessibilityValue(
            isUnlocked ? site.twist : "Locked. Requires \(site.unlock.label)."
        )
    }

    private func fossilPreview(_ site: Site) -> String {
        let fossils = ContentCatalog.shared.fossils(forSite: site.id)
            .sorted { $0.baseValue > $1.baseValue }
            .prefix(4)
        return fossils.map { "\($0.name) $\($0.baseValue)" }.joined(separator: " · ")
    }
}
