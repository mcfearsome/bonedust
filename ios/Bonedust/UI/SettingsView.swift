import BonedustCore
import SwiftUI

/// §7.7. Haptics, sound, reduced motion, left-handed tray, Gentle mode.
struct SettingsView: View {

    let settings: GameSettings
    let trails: [BrushTrail]
    let selectedTrailID: String
    let lockedTrails: [BrushTrail]
    let onSelectTrail: (String) -> Void
    let onAbandonRun: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Haptics", isOn: Binding(
                        get: { settings.hapticsEnabled },
                        set: { settings.hapticsEnabled = $0 }
                    ))
                    Toggle("Sound", isOn: Binding(
                        get: { settings.soundEnabled },
                        set: { settings.soundEnabled = $0 }
                    ))
                    Toggle("Reduced motion", isOn: Binding(
                        get: { settings.reducedMotion },
                        set: { settings.reducedMotion = $0 }
                    ))
                    // Named for what it does to the microphone rather than for the
                    // mechanic, so the switch is findable by someone who wants the mic off
                    // and does not read as a feature list to someone who does not.
                    Toggle("Listen while digging", isOn: Binding(
                        get: { settings.breathEnabled },
                        set: { settings.breathEnabled = $0 }
                    ))
                } header: {
                    Text("Feel")
                } footer: {
                    Text(
                        "Bonedust can listen while you dig. Audio is never recorded, saved "
                            + "or sent anywhere."
                    )
                }

                Section {
                    Toggle("Left-handed tool tray", isOn: Binding(
                        get: { settings.leftHandedTray },
                        set: { settings.leftHandedTray = $0 }
                    ))
                } header: {
                    Text("Layout")
                } footer: {
                    Text("Moves Bag it to the left of the tools, away from your thumb.")
                }

                if trails.count > 1 || !lockedTrails.isEmpty {
                    Section {
                        Picker("Brush trail", selection: Binding(
                            get: { selectedTrailID },
                            set: { onSelectTrail($0) }
                        )) {
                            ForEach(trails) { trail in
                                Text(trail.name).tag(trail.id)
                            }
                        }
                        ForEach(lockedTrails) { trail in
                            HStack {
                                Text(trail.name).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(trail.reputationRequired) Reputation")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Cosmetic")
                    } footer: {
                        Text("Trails are decoration only. None of them changes how a slab digs.")
                    }
                }

                Section {
                    Toggle("Gentle mode", isOn: Binding(
                        get: { settings.gentleMode },
                        set: { settings.gentleMode = $0 }
                    ))
                } header: {
                    Text("Gentle mode")
                } footer: {
                    Text(
                        "Bone cracks half as readily and payouts are reduced by a fifth. "
                        + "Gentle mode runs do not appear on leaderboards, but every dollar "
                        + "still pays down the crew debt in full."
                    )
                }

                if let onAbandonRun {
                    Section {
                        Button("Abandon this run", role: .destructive) {
                            onAbandonRun()
                            dismiss()
                        }
                    } footer: {
                        Text("Counts as a failed run. The next installment resets.")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
