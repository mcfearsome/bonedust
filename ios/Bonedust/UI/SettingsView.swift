import SwiftUI

/// §7.7. Haptics, sound, reduced motion, left-handed tray, Gentle mode.
struct SettingsView: View {

    let settings: GameSettings
    let onAbandonRun: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Feel") {
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
