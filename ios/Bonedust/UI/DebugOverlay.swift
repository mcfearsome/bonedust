import BonedustCore
import SwiftUI

/// §9's M1 requirement: "a debug overlay with sliders for every tuning constant."
///
/// It edits a copy of `SimTuning` and applies it to the dig in progress, so a value
/// can be changed and felt in the same stroke. That immediacy is the whole point —
/// tuning the brush by editing a constant, rebuilding and re-digging loses the thread
/// of what the change actually did to the feel.
struct DebugOverlay: View {

    let engine: DigEngine
    @Binding var orientationProbe: Bool
    let onChange: () -> Void

    @State private var tuning: SimTuning
    @Environment(\.dismiss) private var dismiss

    init(
        engine: DigEngine,
        orientationProbe: Binding<Bool> = .constant(false),
        onChange: @escaping () -> Void
    ) {
        self.engine = engine
        _orientationProbe = orientationProbe
        self.onChange = onChange
        _tuning = State(initialValue: engine.sim.tuning)
    }

    /// Every float constant, with a range wide enough to break the game in both
    /// directions. A slider that cannot produce a bad value cannot teach you where
    /// the good value is.
    private static let knobs: [(String, String, WritableKeyPath<SimTuning, Float>, ClosedRange<Float>)] = [
        ("Removal", "Rate", \.removalRate, 0.02...1.2),
        ("Removal", "Rock hardness", \.rockHardnessMultiplier, 1...8),
        ("Removal", "Step factor", \.stepFactor, 0.1...1.0),
        ("Speed", "EMA alpha", \.emaAlpha, 0.02...1.0),
        ("Speed", "Idle decay", \.emaIdleDecay, 0.5...0.99),
        ("Speed", "Sample ceiling", \.maxSampleSpeed, 5...120),
        ("Cracking", "Rate", \.crackRate, 0...0.01),
        ("Payout", "Exposure exponent", \.exposureExponent, 0.5...3),
        ("Payout", "Crack weight", \.intactCrackWeight, 0...8),
        ("Payout", "Identify at", \.identifyExposure, 0.02...1),
        ("Daylight", "Seconds", \.daylightSeconds, 10...180),
        ("Look", "Wear blend", \.wearColorBlend, 0...1),
        ("Look", "Bone tell tint", \.boneTellTint, 0...0.6),
        ("Look", "Cell noise", \.cellNoise, 0...0.3),
    ]

    private static let intKnobs: [(String, String, WritableKeyPath<SimTuning, Int>, ClosedRange<Float>)] = [
        ("Cracking", "Walk min", \.crackWalkMin, 1...12),
        ("Cracking", "Walk max", \.crackWalkMax, 1...20),
        ("Generation", "Gems max", \.gemsMax, 0...6),
    ]

    private var groups: [String] {
        var seen: [String] = []
        for knob in Self.knobs where !seen.contains(knob.0) { seen.append(knob.0) }
        for knob in Self.intKnobs where !seen.contains(knob.0) { seen.append(knob.0) }
        return seen
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Orientation") {
                    Toggle("Orientation probe", isOn: $orientationProbe)
                        .onChange(of: orientationProbe) { _, _ in onChange() }
                    Text(
                        "Red marks grid rows 0-5, green marks columns 0-5. Red belongs at "
                            + "the TOP and green at the LEFT. Anywhere else and the slab is "
                            + "mirrored on that axis."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Slab") {
                    row("Fossil", engine.fossil.name)
                    row("Site", engine.site.name)
                    row("Seed", String(engine.layout.seed))
                    row("Bone cells", String(engine.layout.boneCells))
                    row("Rock cells", String(engine.layout.rockCells))
                    row("Gems", String(engine.layout.gemCount))
                    row("Crack multiplier", String(format: "%.2f", engine.modifiers.crackMultiplier))
                }

                Section("Layer hardness") {
                    ForEach(1...3, id: \.self) { depth in
                        knobRow(
                            name: depth == 3 ? "Topsoil" : depth == 2 ? "Clay" : "Sandstone",
                            value: Binding(
                                get: { tuning.layerHardness.indices.contains(depth)
                                        ? tuning.layerHardness[depth] : 1 },
                                set: { newValue in
                                    guard tuning.layerHardness.indices.contains(depth) else { return }
                                    tuning.layerHardness[depth] = newValue
                                    apply()
                                }
                            ),
                            range: 0.2...4
                        )
                    }
                }

                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(Self.knobs.filter { $0.0 == group }, id: \.1) { knob in
                            knobRow(
                                name: knob.1,
                                value: Binding(
                                    get: { tuning[keyPath: knob.2] },
                                    set: { tuning[keyPath: knob.2] = $0; apply() }
                                ),
                                range: knob.3
                            )
                        }
                        ForEach(Self.intKnobs.filter { $0.0 == group }, id: \.1) { knob in
                            knobRow(
                                name: knob.1,
                                value: Binding(
                                    get: { Float(tuning[keyPath: knob.2]) },
                                    set: { tuning[keyPath: knob.2] = Int($0.rounded()); apply() }
                                ),
                                range: knob.3,
                                step: 1
                            )
                        }
                    }
                }

                Section {
                    Button("Reset to shipped values") {
                        tuning = .standard
                        apply()
                    }
                }
            }
            .navigationTitle("Tuning")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .font(Typography.number(.footnote))
                .foregroundStyle(.secondary)
        }
    }

    private func knobRow(
        name: String, value: Binding<Float>, range: ClosedRange<Float>, step: Float? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.footnote)
                Spacer()
                Text(step == nil
                        ? String(format: "%.4g", value.wrappedValue)
                        : String(Int(value.wrappedValue)))
                    .font(Typography.number(.footnote))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    private func apply() {
        engine.applyTuning(tuning)
        onChange()
    }
}
