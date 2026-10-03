import BonedustCore
import SpriteKit
import SwiftUI

/// The main screen (§7.3). Top bar, daylight, the slab as large as it will go,
/// readouts, speed meter, tool tray, Bag it.
struct DigView: View {

    @State private var engine: DigEngine
    @State private var scene: DigScene
    @State private var haptics = HapticEngine()
    @State private var audio = DigAudio()
    @State private var showDebug = false
    @State private var showHint = false
    @State private var hintHasBeenShown = false

    @Environment(GameSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Supplied by the run loop at M2. Hardcoded for M1.
    let day: Int
    let totalDays: Int
    let cash: Int
    let installment: Int
    let trail: BrushTrail
    let onBagged: (DigEngine) -> Void

    init(
        engine: DigEngine,
        day: Int = 1,
        totalDays: Int = 5,
        cash: Int = 0,
        installment: Int = 350,
        trail: BrushTrail = .natural,
        onBagged: @escaping (DigEngine) -> Void = { _ in }
    ) {
        _engine = State(initialValue: engine)
        _scene = State(initialValue: DigScene())
        self.day = day
        self.totalDays = totalDays
        self.cash = cash
        self.installment = installment
        self.trail = trail
        self.onBagged = onBagged
    }

    private var reduceMotion: Bool { settings.reducedMotion || systemReduceMotion }

    var body: some View {
        VStack(spacing: 14) {
            topBar
            DaylightBar(remaining: engine.daylightRemaining, total: engine.totalDaylight)
            slab
            readouts
            SpeedMeter(speed: engine.speed, safeSpeed: engine.safeSpeed)
            passiveBadges
            toolTray
        }
        .padding(.horizontal, Measure.gutter)
        .padding(.bottom, 10)
        .background(Ink.ground.ignoresSafeArea())
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            // §5: killing or backgrounding the app pauses the slab rather than
            // burning daylight the player cannot see.
            if phase != .active { engine.pause() }
        }
        .onChange(of: settings.hapticsEnabled) { _, enabled in haptics.isEnabled = enabled }
        .onChange(of: settings.soundEnabled) { _, enabled in audio.isEnabled = enabled }
        .onChange(of: engine.phase) { _, phase in
            if case .finished = phase { finish() }
        }
        .sheet(isPresented: $showDebug) {
            DebugOverlay(engine: engine) { scene.configureRenderer() }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                showDebug = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.muted)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Tuning")

            VStack(alignment: .leading, spacing: 1) {
                Text("Day \(day) of \(totalDays)")
                    .font(Typography.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.ivory)
                Text(engine.site.name)
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text("$\(cash)")
                    .font(Typography.number(.footnote, weight: .semibold))
                    .foregroundStyle(cash >= installment ? Ink.safe : Ink.ivory)
                Text("/")
                    .font(Typography.number(.footnote))
                    .foregroundStyle(Ink.hairline)
                Text("$\(installment)")
                    .font(Typography.number(.footnote))
                    .foregroundStyle(Ink.muted)
            }
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .fill(Ink.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Measure.cardRadius)
                            .stroke(Ink.hairline, lineWidth: Measure.hairline)
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cash")
            .accessibilityValue("\(cash) dollars of \(installment) owed")
        }
    }

    private var slab: some View {
        SpriteView(
            scene: scene,
            preferredFramesPerSecond: 60,
            options: [.ignoresSiblingOrder, .shouldCullNonVisibleNodes]
        )
        .aspectRatio(
            CGFloat(SlabGrid.width) / CGFloat(SlabGrid.height),
            contentMode: .fit
        )
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(Ink.hairline, lineWidth: Measure.hairline)
        )
        .overlay(alignment: .topLeading) { specimenChip }
        .overlay(alignment: .bottom) { hint }
        .accessibilityLabel("Dig slab")
        .accessibilityValue(
            "\(engine.specimenCode), \(engine.specimenName). "
                + "\(engine.exposurePercent) percent exposed, "
                + "\(engine.intactPercent) percent intact."
        )
        .accessibilityHint("Drag to brush sediment away. Brush slowly over bone.")
    }

    /// Museum-label styling, per §7: dashed rule, small caps.
    private var specimenChip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(engine.specimenCode) · \(engine.specimenName.uppercased())")
                .font(Typography.label(.caption2))
                .tracking(1.0)
                .foregroundStyle(Ink.ivory)
            SpecimenRule().frame(width: 92)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Ink.ground.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(8)
        .accessibilityHidden(true)
    }

    /// §9's single diegetic hint, shown once, the first time a crack happens.
    @ViewBuilder
    private var hint: some View {
        if showHint {
            Text("Go slow over bone.")
                .font(Typography.ui(.footnote, weight: .semibold))
                .foregroundStyle(Ink.ground)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Ink.accent)
                .clipShape(Capsule())
                .padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Passive tools have no button, so they are shown as always-on badges. Otherwise
    /// a player who spent $95 on goggles has nothing on screen telling them so.
    @ViewBuilder
    private var passiveBadges: some View {
        let passives = engine.passiveTools
        if !passives.isEmpty {
            HStack(spacing: 6) {
                ForEach(passives) { tool in
                    Text(tool.name)
                        .font(Typography.label(.caption2))
                        .tracking(0.8)
                        .foregroundStyle(Ink.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Ink.hairline, lineWidth: Measure.hairline)
                        )
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Carrying " + passives.map(\.name).joined(separator: ", "))
        }
    }

    private var readouts: some View {
        HStack(spacing: 10) {
            Readout(label: "Exposed", value: "\(engine.exposurePercent)%")
            Readout(
                label: "Intact",
                value: "\(engine.intactPercent)%",
                tint: engine.intactPercent >= 90 ? Ink.ivory
                    : engine.intactPercent >= 60 ? Ink.accent : Ink.danger
            )
            Readout(label: "Est. value", value: "$\(engine.estimatedValue)")
            if engine.wholeGems > 0 {
                Readout(
                    label: engine.wholeGems == 1 ? "Gem" : "Gems",
                    value: "\(engine.wholeGems)",
                    tint: Ink.gem
                )
            }
        }
    }

    private var toolTray: some View {
        HStack(spacing: 10) {
            let tools = engine.availableBrushes
            let tray = ForEach(tools) { tool in
                ToolButton(tool: tool, isSelected: tool.id == engine.tool.id) {
                    engine.tool = tool
                }
            }
            if settings.leftHandedTray {
                bagButton
                tray
            } else {
                tray
                bagButton
            }
        }
    }

    private var bagButton: some View {
        Button {
            engine.bagIt()
        } label: {
            Text("Bag it")
                .font(Typography.ui(.headline, weight: .bold))
                .foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Ink.accent)
                .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
        .accessibilityLabel("Bag it")
        .accessibilityHint("Ends the dig and banks the specimen at its current value.")
    }

    // MARK: Lifecycle

    private func start() {
        scene.engine = engine
        scene.haptics = haptics
        scene.audio = audio
        scene.reducedMotion = reduceMotion
        scene.trail = trail
        scene.onFirstCrack = showCrackHint
        scene.configureRenderer()
        haptics.isEnabled = settings.hapticsEnabled
        audio.isEnabled = settings.soundEnabled
        haptics.prepare()
        audio.prepare()
    }

    private func stop() {
        haptics.teardown()
        audio.teardown()
    }

    private func showCrackHint() {
        guard !hintHasBeenShown else { return }
        hintHasBeenShown = true
        withAnimation(.easeOut(duration: 0.2)) { showHint = true }
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            withAnimation(.easeIn(duration: 0.4)) { showHint = false }
        }
    }

    private func finish() {
        haptics.stopTexture()
        audio.stopScrape()
        onBagged(engine)
    }
}

/// One tool slot.
struct ToolButton: View {

    let tool: BrushTool
    let isSelected: Bool
    let action: () -> Void

    private var symbol: String {
        switch tool.id {
        case "fine_brush": return "paintbrush.pointed.fill"
        case "air_blower": return "wind"
        default: return "paintbrush.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(tool.name)
                    .font(Typography.label(.caption2))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Ink.ground : Ink.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isSelected ? Ink.ivory : Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(isSelected ? Color.clear : Ink.hairline, lineWidth: Measure.hairline)
            )
        }
        .accessibilityLabel(tool.name)
        .accessibilityValue(
            "Safe up to \(String(format: "%.1f", tool.safeSpeed)) cells per frame"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
