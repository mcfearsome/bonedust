import BonedustCore
import SwiftUI

/// Your outfit: a handful of diggers who pool what they pay.
///
/// "Crew" means every player alive against one debt. An outfit is the people you actually
/// dig with, and the screen is deliberately small — a name, a code to share, what you have
/// pooled, and who put in what.
struct OutfitView: View {

    let store: CrewLedgerStore
    let onClose: () -> Void

    @State private var code = ""
    @State private var isWorking = false
    @State private var confirmingLeave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let problem = store.outfitProblem { notice(problem) }
                if let outfit = store.outfit {
                    pooled(outfit)
                    roster(outfit)
                    ladder(outfit)
                    shareCode(outfit)
                    leaveButton
                } else {
                    joinOrFound
                }
                board
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 30)
        }
        .background(Ink.ground.ignoresSafeArea())
        .task {
            await store.refreshOutfit()
            await store.refreshOutfitBoard()
        }
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
            Text(store.outfit?.name.uppercased() ?? "YOUR OUTFIT")
                .font(Typography.display(26))
                .foregroundStyle(Ink.ivory)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.outfit == nil
                    ? "A few diggers who pool what they pay."
                    : "What you pool counts twice: once for the crew, once for the outfit.")
                .font(Typography.ui(.caption))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
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

    private var joinOrFound: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                run { await store.foundOutfit() }
            } label: {
                Text("Found an outfit")
                    .font(Typography.ui(.headline, weight: .bold))
                    .foregroundStyle(Ink.ground)
                    .frame(maxWidth: .infinity)
                    .scaledControlHeight(52)
                    .background(Ink.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            }
            .disabled(isWorking)

            VStack(alignment: .leading, spacing: 7) {
                FieldLabel(text: "Or join one")
                HStack(spacing: 8) {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(Typography.number(.title3, weight: .semibold))
                        .foregroundStyle(Ink.ivory)
                        .padding(.horizontal, 11)
                        .scaledControlHeight(48)
                        .background(Ink.raised)
                        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                        .accessibilityLabel("Outfit join code")
                    Button("Join") {
                        run { await store.joinOutfit(code: code) }
                    }
                    .font(Typography.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .padding(.horizontal, 16)
                    .scaledControlHeight(48)
                    .background(Ink.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                    .disabled(isWorking || code.isEmpty)
                }
                Text("Codes avoid letters that look alike, so there is no O or I in one.")
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted)
            }
        }
    }

    private func pooled(_ outfit: OutfitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Pooled")
            Text(CrewLedgerView.money(outfit.paidTotal))
                .font(Typography.number(.largeTitle, weight: .bold))
                .foregroundStyle(Ink.ivory)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let next = outfit.nextMilestone {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.ground)
                        Capsule()
                            .fill(Ink.accent)
                            .frame(width: max(3, geometry.size.width
                                * min(1, CGFloat(outfit.paidTotal) / CGFloat(max(1, next.amount)))))
                    }
                }
                .frame(height: 8)
                Text("\(CrewLedgerView.money(next.amount - outfit.paidTotal)) to \(next.name)")
                    .font(Typography.ui(.caption))
                    .foregroundStyle(Ink.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
        .accessibilityElement(children: .combine)
    }

    private func roster(_ outfit: OutfitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                FieldLabel(text: "Who dug it")
                Spacer()
                Text("\(outfit.memberCount)")
                    .font(Typography.number(.caption2))
                    .foregroundStyle(Ink.muted)
            }
            ForEach(outfit.members) { member in
                HStack {
                    Text(member.you ? "You" : member.name)
                        .font(Typography.ui(.caption))
                        .foregroundStyle(member.you ? Ink.accent : Ink.ivory)
                        .lineLimit(1)
                    Spacer()
                    Text(CrewLedgerView.money(member.paidTotal))
                        .font(Typography.number(.caption, weight: .medium))
                        .foregroundStyle(Ink.ivory)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    private func ladder(_ outfit: OutfitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            FieldLabel(text: "What the outfit has earned")
            ForEach(outfit.milestones) { milestone in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(milestone.reached ? Ink.accent : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(
                            milestone.reached ? Ink.accent : Ink.hairline, lineWidth: 1
                        ))
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(milestone.name)
                                .font(Typography.ui(.caption, weight: .semibold))
                                .foregroundStyle(milestone.reached ? Ink.ivory : Ink.muted)
                            Spacer()
                            Text(CrewLedgerView.money(milestone.amount))
                                .font(Typography.number(.caption2))
                                .foregroundStyle(Ink.muted)
                                .monospacedDigit()
                        }
                        // The beat is earned, not previewed. Printing it early spends it.
                        if milestone.reached, let beat = milestone.beat {
                            Text(beat)
                                .font(Typography.ui(.caption2))
                                .foregroundStyle(Ink.muted)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(milestone.reached ? "Reached" : "Not yet")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
    }

    @ViewBuilder
    private func shareCode(_ outfit: OutfitSnapshot) -> some View {
        if let joinCode = outfit.joinCode {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Bring someone in")
                Text(joinCode)
                    .font(Typography.number(.title, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(Ink.accent)
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text("They enter this on their own Outfit screen.")
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Join code")
            // Spelled out, because six characters read as one word are unusable aloud.
            .accessibilityValue(joinCode.map(String.init).joined(separator: " "))
        }
    }

    private var leaveButton: some View {
        Button(role: .destructive) {
            confirmingLeave = true
        } label: {
            Text("Leave outfit")
                .font(Typography.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.danger)
                .frame(maxWidth: .infinity)
                .scaledControlHeight(46)
        }
        .confirmationDialog("Leave this outfit?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) { run { await store.leaveOutfit() } }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("What you have already paid stays with the outfit.")
        }
    }

    @ViewBuilder
    private var board: some View {
        if !store.outfitBoard.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                FieldLabel(text: "Outfits by what they have paid")
                ForEach(store.outfitBoard.prefix(20)) { entry in
                    HStack {
                        Text("\(entry.rank)")
                            .font(Typography.number(.caption2))
                            .foregroundStyle(Ink.muted)
                            .frame(width: 26, alignment: .trailing)
                        Text(entry.name)
                            .font(Typography.ui(.caption))
                            .foregroundStyle(entry.yours ? Ink.accent : Ink.ivory)
                            .lineLimit(1)
                        Spacer()
                        Text(CrewLedgerView.money(entry.paidTotal))
                            .font(Typography.number(.caption, weight: .medium))
                            .foregroundStyle(Ink.ivory)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.raised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await work()
            await store.refreshOutfitBoard()
            code = ""
            isWorking = false
        }
    }
}
