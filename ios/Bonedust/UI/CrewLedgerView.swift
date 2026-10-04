import BonedustCore
import SwiftUI

/// §7: the Crew Ledger screen — remaining, progress, milestone track, diggers this season,
/// paid today, your lifetime share, and a recent-payments feed.
struct CrewLedgerView: View {

    let store: CrewLedgerStore
    let meta: MetaProgress
    let onOutfit: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let snapshot = store.snapshot {
                    debtCard(snapshot)
                    season(snapshot)
                    yourShare
                    personalLadder
                    outfitCard
                    milestoneTrack(snapshot)
                    feed(snapshot)
                } else {
                    placeholder
                }
                if !store.queue.pending.isEmpty { queueCard }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
        // §6: poll every 30 s while a ledger screen is visible, and not otherwise.
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .task { await store.refreshMe() }
        .safeAreaInset(edge: .bottom) {
            Button(action: onClose) {
                Text("Close")
                    .font(Typography.ui(.headline, weight: .bold))
                    .foregroundStyle(Ink.ground)
                    .frame(maxWidth: .infinity)
                    .scaledControlHeight(50)
                    .background(Ink.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 8)
            .background(Ink.ground.opacity(0.96))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CREW LEDGER")
                .font(Typography.display(30))
                .foregroundStyle(Ink.ivory)
            Text(store.isReachable
                    ? "Every dollar anyone digs comes off this."
                    : "Offline. Showing the last figures you saw.")
                .font(Typography.ui(.caption))
                .foregroundStyle(store.isReachable ? Ink.muted : Ink.accent)
        }
        .padding(.top, 26)
        .accessibilityElement(children: .combine)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No figures yet.")
                .font(Typography.ui(.headline))
                .foregroundStyle(Ink.ivory)
            Text("The ledger loads when you next have a connection. Nothing you dig is lost "
                + "in the meantime — it queues up and counts when it arrives.")
                .font(Typography.ui(.caption))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    private func debtCard(_ snapshot: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            FieldLabel(text: "Still owed")
            Text(Self.money(snapshot.remaining))
                .font(Typography.number(.largeTitle, weight: .bold))
                .foregroundStyle(Ink.ivory)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.ground)
                    Capsule()
                        .fill(Ink.accent)
                        .frame(width: max(3, geometry.size.width * snapshot.fractionPaid))
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(Self.money(snapshot.paid)) paid")
                    .font(Typography.number(.caption))
                    .foregroundStyle(Ink.accent)
                Spacer()
                Text("of \(Self.money(snapshot.totalDebt))")
                    .font(Typography.number(.caption))
                    .foregroundStyle(Ink.muted)
            }
            .monospacedDigit()
        }
        .padding(14)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crew debt")
        .accessibilityValue(
            "\(Self.money(snapshot.remaining)) still owed, "
                + "\(Int(snapshot.fractionPaid * 100)) percent paid."
        )
    }

    private func season(_ snapshot: LedgerSnapshot) -> some View {
        HStack(spacing: 10) {
            Readout(label: "Paid today", value: Self.money(snapshot.paidToday), tint: Ink.accent)
            Readout(label: "Diggers", value: "\(snapshot.diggersSeason)")
            Readout(label: "Season", value: snapshot.season)
        }
    }

    @ViewBuilder
    private var yourShare: some View {
        if let me = store.me {
            VStack(alignment: .leading, spacing: 7) {
                FieldLabel(text: "Your share")
                HStack(spacing: 10) {
                    Readout(label: "Lifetime", value: Self.money(me.paidTotal))
                    Readout(label: "Rank", value: "#\(me.rank)")
                    Readout(label: "Best slab", value: Self.money(me.bestSlabAmount))
                }
            }
            .padding(13)
            .background(Ink.raised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
    }

    /// What this player's own contribution has earned.
    ///
    /// Awarded from the local lifetime total rather than the server's, so it keeps working
    /// with no connection — the same reason these rungs ship in the app's content while the
    /// crew's and the outfit's arrive over the wire.
    private var personalLadder: some View {
        let ladder = ContentCatalog.shared.personalMilestones
        let paid = meta.lifetimeContribution
        let next = ladder.first { !$0.reached(by: paid) }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                FieldLabel(text: "What you have paid")
                Spacer()
                Text(CrewLedgerView.money(paid))
                    .font(Typography.number(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.ivory)
                    .monospacedDigit()
            }
            ForEach(ladder) { milestone in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(milestone.reached(by: paid) ? Ink.accent : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(
                            milestone.reached(by: paid) ? Ink.accent : Ink.hairline, lineWidth: 1
                        ))
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(milestone.name)
                                .font(Typography.ui(.caption, weight: .semibold))
                                .foregroundStyle(milestone.reached(by: paid) ? Ink.ivory : Ink.muted)
                            Spacer()
                            Text(CrewLedgerView.money(milestone.amount))
                                .font(Typography.number(.caption2))
                                .foregroundStyle(Ink.muted)
                                .monospacedDigit()
                        }
                        if milestone.reached(by: paid), let beat = milestone.beat {
                            Text(beat)
                                .font(Typography.ui(.caption2))
                                .foregroundStyle(Ink.muted)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        } else if milestone.id == next?.id {
                            Text("\(CrewLedgerView.money(milestone.amount - paid)) to go.")
                                .font(Typography.ui(.caption2))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(milestone.reached(by: paid) ? "Reached" : "Not yet")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    /// The way in to outfits. Deliberately a card rather than a tab: most players will dig
    /// alone, and the screen should not imply they are missing something required.
    private var outfitCard: some View {
        Button(action: onOutfit) {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Your outfit")
                Text(store.outfitMembership?.name ?? "Dig with people you know")
                    .font(Typography.ui(.headline, weight: .semibold))
                    .foregroundStyle(Ink.ivory)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.outfitMembership.map {
                    "\(CrewLedgerView.money($0.paidTotal)) pooled between \($0.memberCount)."
                } ?? "Found one, or join with a code. What you pool counts for the crew too.")
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityLabel("Your outfit")
    }

    private func milestoneTrack(_ snapshot: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Milestones")
            ForEach(snapshot.milestones) { milestone in
                milestoneRow(milestone, isNext: milestone.key == snapshot.nextMilestone?.key)
            }
        }
    }

    private func milestoneRow(_ milestone: LedgerMilestone, isNext: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(milestone.reached ? Ink.accent : Color.clear)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(milestone.reached ? Ink.accent : Ink.hairline, lineWidth: 1))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(milestone.name)
                        .font(Typography.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(milestone.reached ? Ink.ivory : Ink.muted)
                    Spacer()
                    Text(Self.money(milestone.amount))
                        .font(Typography.number(.caption))
                        .foregroundStyle(milestone.reached ? Ink.accent : Ink.muted)
                        .monospacedDigit()
                }
                // The story beat is shown once the crew has earned it, never before.
                // Printing it early would spend the moment for nothing.
                if milestone.reached, let beat = milestone.beat {
                    Text(beat)
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                } else if isNext {
                    Text("Next.")
                        .font(Typography.label(.caption2))
                        .tracking(1)
                        .foregroundStyle(Ink.accent)
                }
                if milestone.reached, !milestone.unlocks.isEmpty {
                    Text(milestone.unlocks.map(Self.describeUnlock).joined(separator: " · "))
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(milestone.reached ? Ink.raised : Ink.raised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityValue(milestone.reached ? "Reached" : "Not yet reached")
    }

    private func feed(_ snapshot: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Just paid")
            if snapshot.recent.isEmpty {
                Text("Nothing yet today.")
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
            }
            ForEach(snapshot.recent) { payment in
                HStack {
                    Text(payment.name)
                        .font(Typography.ui(.caption))
                        .foregroundStyle(Ink.ivory)
                        .lineLimit(1)
                    if let fossilID = payment.fossilID,
                       let fossil = ContentCatalog.shared.fossil(fossilID) {
                        Text("· \(fossil.name)")
                            .font(Typography.ui(.caption2))
                            .foregroundStyle(Ink.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("$\(payment.amount)")
                        .font(Typography.number(.caption, weight: .medium))
                        .foregroundStyle(Ink.accent)
                        .monospacedDigit()
                    Text(Self.ago(payment.at))
                        .font(Typography.ui(.caption2))
                        .foregroundStyle(Ink.muted)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    /// Shown only when something is waiting. Reassurance, not a warning: the dollars are
    /// not lost, they just have not arrived.
    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Waiting to send")
            Text("\(Self.money(store.queue.pendingTotal)) from "
                + "\(store.queue.pending.count) slab\(store.queue.pending.count == 1 ? "" : "s")")
                .font(Typography.number(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.ivory)
                .monospacedDigit()
            Text("These count toward the debt as soon as you have a connection.")
                .font(Typography.ui(.caption2))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .accessibilityElement(children: .combine)
    }

    // MARK: Formatting

    /// Billions need to be readable at a glance, so large figures are abbreviated and
    /// small ones are not. "$2.4B still owed" lands; "$2,400,000,000" is a wall.
    static func money(_ amount: Int) -> String {
        switch abs(amount) {
        case 1_000_000_000...:
            return "$\(String(format: "%.2f", Double(amount) / 1_000_000_000))B"
        case 10_000_000...:
            return "$\(String(format: "%.1f", Double(amount) / 1_000_000))M"
        case 1_000_000...:
            return "$\(String(format: "%.2f", Double(amount) / 1_000_000))M"
        case 10_000...:
            return "$\(amount / 1_000)k"
        default:
            return "$\(amount)"
        }
    }

    static func describeUnlock(_ identifier: String) -> String {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return identifier }
        switch parts[0] {
        case "site": return ContentCatalog.shared.site(parts[1])?.name ?? parts[1]
        case "tool": return ContentCatalog.shared.tool(parts[1])?.name ?? parts[1]
        case "charmpool": return "Rare charms"
        case "perk": return "Crew perk"
        case "mode": return "New game plus"
        case "ending": return "The ending"
        default:
            // Sentence case, to match the branches above ("Rare charms", "New game plus").
            // `.capitalized` gives "Future Thing", which reads like a product name.
            let words = parts[1].replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
