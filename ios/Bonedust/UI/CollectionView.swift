import BonedustCore
import SwiftUI

/// §5's museum drawer: every species, found or not, with the best you have managed.
///
/// Undiscovered species are shown as empty slots rather than hidden. A drawer with gaps
/// in it is the thing that makes you want to go back to Wheeler Shale; a drawer that only
/// lists what you already have is a receipt.
struct CollectionView: View {

    let meta: MetaProgress
    let onClose: () -> Void

    private var catalog: ContentCatalog { .shared }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 10)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                sets
                ForEach(catalog.sites) { site in
                    drawer(for: site)
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: 4) {
            Text("COLLECTION")
                .font(Typography.display(32))
                .foregroundStyle(Ink.ivory)
            Text("\(meta.collection.discoveredCount) of \(catalog.fossils.count) species"
                + (meta.collection.perfectCount > 0
                    ? "  ·  \(meta.collection.perfectCount) flawless"
                    : ""))
                .font(Typography.number(.subheadline))
                .foregroundStyle(Ink.accent)
                .monospacedDigit()
        }
        .padding(.top, 26)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sets: some View {
        if !catalog.sets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Skeleton sets")
                ForEach(catalog.sets) { set in
                    setRow(set)
                }
            }
        }
    }

    private func setRow(_ set: SkeletonSet) -> some View {
        let progress = meta.collection.progress(for: set)
        let complete = progress.found == progress.total
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(set.name)
                    .font(Typography.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(complete ? Ink.accent : Ink.ivory)
                Spacer()
                SetPips(found: progress.found, total: progress.total)
            }
            Text(complete ? set.perk.label : pieceList(set))
                .font(Typography.ui(.caption2))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(complete ? Ink.accent.opacity(0.5) : Ink.hairline, lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(set.name)
        .accessibilityValue(
            "\(progress.found) of \(progress.total) pieces."
                + (complete ? " Complete. \(set.perk.label)" : "")
        )
    }

    private func pieceList(_ set: SkeletonSet) -> String {
        set.pieces
            .map { id in
                let name = catalog.fossil(id)?.name ?? id
                return meta.collection.has(id) ? name : "—"
            }
            .joined(separator: " · ")
    }

    private func drawer(for site: Site) -> some View {
        let fossils = catalog.fossils(forSite: site.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel(text: site.name)
                Spacer()
                Text("\(fossils.filter { meta.collection.has($0.id) }.count)/\(fossils.count)")
                    .font(Typography.number(.caption2))
                    .foregroundStyle(Ink.muted)
                    .monospacedDigit()
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(fossils) { fossil in
                    card(fossil)
                }
            }
        }
    }

    private func card(_ fossil: Fossil) -> some View {
        let record = meta.collection.record(for: fossil.id)
        return VStack(alignment: .leading, spacing: 5) {
            Text(record == nil ? "Unfound" : fossil.name)
                .font(Typography.ui(.footnote, weight: .semibold))
                .foregroundStyle(record == nil ? Ink.muted : Ink.ivory)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(record == nil ? "—" : "\(fossil.period) · $\(fossil.baseValue)")
                .font(Typography.ui(.caption2))
                .foregroundStyle(Ink.muted)
            SpecimenRule()
            if let record {
                statLine("Best exposed", "\(Int((record.bestExposure * 100).rounded()))%")
                statLine("Best intact", "\(Int((record.bestIntact * 100).rounded()))%")
                statLine("Best paid", "$\(record.bestPayout)")
                statLine("Found", "\(record.timesFound)x")
                if record.isPerfect {
                    Text("FLAWLESS")
                        .font(Typography.label(.caption2))
                        .tracking(1.2)
                        .foregroundStyle(Ink.accent)
                }
            } else {
                Text("Not yet out of the ground.")
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.hairline)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Ink.raised.opacity(record == nil ? 0.4 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record == nil ? "Unfound specimen" : fossil.name)
        .accessibilityValue(
            record.map {
                "Best exposed \(Int($0.bestExposure * 100)) percent, "
                    + "best intact \(Int($0.bestIntact * 100)) percent, "
                    + "found \($0.timesFound) times."
            } ?? "Not yet found."
        )
    }

    private func statLine(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(Typography.ui(.caption2))
                .foregroundStyle(Ink.muted)
            Spacer()
            Text(value)
                .font(Typography.number(.caption2, weight: .medium))
                .foregroundStyle(Ink.ivory)
                .monospacedDigit()
        }
    }
}

/// Set progress as filled and empty pips. Shown on the results screen too, per §4.
struct SetPips: View {
    let found: Int
    let total: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(0, total), id: \.self) { index in
                Circle()
                    .fill(index < found ? Ink.accent : Color.clear)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(
                            index < found ? Ink.accent : Ink.hairline, lineWidth: 1
                        )
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(found) of \(total) pieces")
    }
}
