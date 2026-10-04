import BonedustCore
import SwiftUI

/// Where Reputation is spent, between weeks.
///
/// This exists because kit stopped carrying. Tools and charms used to survive a successful
/// run, which meant a brush bought in week one was still doing the job in week nine and the
/// supply tent had nothing left to say — reported from play as "once i made my purchases i
/// never really looked at the store again".
///
/// Splitting the two currencies is what makes both shops worth opening. Cash buys kit for
/// *this* week and is gone with it; Reputation buys what you keep. And Reputation survives
/// a failed run, which tools never did, so a bad week costs a week rather than a career.
struct CampView: View {

    let meta: MetaProgress
    let onBuy: (Upgrade) -> Void
    let onLeave: () -> Void

    private var catalog: ContentCatalog { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(catalog.upgrades) { upgrade in
                        row(upgrade)
                    }
                }
                .padding(.horizontal, Measure.gutter)
                .padding(.vertical, 14)
            }
            Button(action: onLeave) {
                Text("Back to it")
                    .font(Typography.ui(.headline, weight: .bold))
                    .foregroundStyle(Ink.ground)
                    .frame(maxWidth: .infinity)
                    .scaledControlHeight(52)
                    .background(Ink.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 12)
        }
        .background(Ink.ground.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Camp")
                .font(Typography.ui(.title2, weight: .bold))
                .foregroundStyle(Ink.ivory)
            Text("What you keep. Paid for in standing, not in his money.")
                .font(Typography.ui(.footnote))
                .foregroundStyle(Ink.muted)
            HStack(spacing: 5) {
                Text("\(meta.reputation)")
                    .font(Typography.number(.title3, weight: .bold))
                    .foregroundStyle(Ink.accent)
                Text("REPUTATION")
                    .font(Typography.label(.caption2))
                    .tracking(1.1)
                    .foregroundStyle(Ink.muted)
            }
            .monospacedDigit()
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reputation")
            .accessibilityValue("\(meta.reputation)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Measure.gutter)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func row(_ upgrade: Upgrade) -> some View {
        let owned = meta.ownedUpgradeIDs.contains(upgrade.id)
        let affordable = meta.reputation >= upgrade.reputation

        Button {
            guard !owned, affordable else { return }
            onBuy(upgrade)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(upgrade.name)
                        .font(Typography.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(owned ? Ink.muted : Ink.ivory)
                    Text(upgrade.blurb)
                        .font(Typography.ui(.caption))
                        .foregroundStyle(Ink.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(effectLine(upgrade))
                        .font(Typography.label(.caption2))
                        .tracking(0.8)
                        .foregroundStyle(Ink.safe)
                        .padding(.top, 1)
                }
                Spacer(minLength: 6)
                if owned {
                    Text("KEPT")
                        .font(Typography.label(.caption2))
                        .tracking(1)
                        .foregroundStyle(Ink.safe)
                } else {
                    Text("\(upgrade.reputation)")
                        .font(Typography.number(.subheadline, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(affordable ? Ink.accent : Ink.hairline)
                }
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
        .disabled(owned || !affordable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(upgrade.name)
        .accessibilityValue(
            owned
                ? "Kept. \(effectLine(upgrade))"
                : "\(upgrade.reputation) reputation. \(effectLine(upgrade)). "
                    + (affordable ? "You can afford this." : "Not enough reputation yet.")
        )
        .accessibilityAddTraits(owned ? [] : .isButton)
    }

    /// What the upgrade actually does, spelled out rather than left to the blurb.
    ///
    /// A player choosing between two of these needs the number, and the fiction line above
    /// it is never going to give them one.
    private func effectLine(_ upgrade: Upgrade) -> String {
        var parts: [String] = []
        let m = upgrade.modifiers
        if m.safeSpeedMultiplier != 1 {
            parts.append("Brush \(percent(m.safeSpeedMultiplier)) faster before bone cracks")
        }
        if m.payoutMultiplier != 1 {
            parts.append("\(percent(m.payoutMultiplier)) more for every slab")
        }
        if m.crackMultiplier != 1 {
            parts.append("\(percent(1 / m.crackMultiplier)) less cracking")
        }
        if m.daylightDelta != 0 {
            parts.append("\(Int(m.daylightDelta)) more seconds of daylight")
        }
        if upgrade.extraCharmSlot { parts.append("One more charm slot") }
        if upgrade.extraDays > 0 {
            parts.append(
                "\(upgrade.extraDays) more day\(upgrade.extraDays == 1 ? "" : "s") a week"
            )
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func percent(_ multiplier: Float) -> String {
        "\(Int(((multiplier - 1) * 100).rounded()))%"
    }
}
