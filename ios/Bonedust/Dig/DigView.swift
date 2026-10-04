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
    @State private var breath = BreathDetector()
    @State private var showDebug = false
    @State private var orientationProbe = false
    @State private var showHint = false
    @State private var hintHasBeenShown = false

    @Environment(GameSettings.self) private var settings
    @Environment(\.theme) private var theme
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
        // Resize with the view from the moment it is presented. Set later, in `didMove`, it is
        // too late: the scene keeps its initial 1x1 and SpriteKit stretches it to the view, so
        // every length in scene units (the slab's inset, the bloom, the dust) is wrong by the
        // view's width. A 12pt inset on a 1pt scene is a slab with no area.
        let scene = DigScene()
        scene.scaleMode = .resizeFill
        _scene = State(initialValue: scene)
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
            SpeedMeter(
                speed: engine.speed,
                safeSpeed: engine.safeSpeed,
                overBone: engine.isBrushOverBone
            )
            passiveBadges
            toolTray
        }
        .padding(.horizontal, Measure.gutter)
        .padding(.bottom, 10)
        // The slab is width-limited at 3:4, so the stack is shorter than the screen and
        // floats a little inside the safe area. `ignoresSafeArea` only extends an edge that
        // touches the safe area, so without this the page stops short and leaves a white
        // band above and below it. Filling the screen changes nothing else: the stack is
        // centred in it, which is where the hosting view already put it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotebookPage())
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            // §5: killing or backgrounding the app pauses the slab rather than
            // burning daylight the player cannot see.
            if phase != .active {
                engine.pause()
                // Holding the microphone open in the background is not something to do
                // quietly, whatever iOS would allow.
                breath.stop()
            } else if settings.breathEnabled, !breath.permissionDenied {
                Task { await breath.start() }
            }
        }
        .onChange(of: settings.hapticsEnabled) { _, enabled in haptics.isEnabled = enabled }
        .onChange(of: settings.soundEnabled) { _, enabled in audio.isEnabled = enabled }
        .onChange(of: engine.phase) { _, phase in
            if case .finished = phase { finish() }
        }
        .sheet(isPresented: $showDebug) {
            DebugOverlay(engine: engine, breath: breath, orientationProbe: $orientationProbe) {
                scene.orientationProbe = orientationProbe
                scene.configureRenderer()
            }
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
                    .foregroundStyle(theme.ink.muted)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Tuning")

            VStack(alignment: .leading, spacing: 1) {
                Text("Day \(day) of \(totalDays)")
                    .font(Typography.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.ink.ink)
                Text(engine.site.name)
                    .font(Typography.ui(.caption2))
                    .foregroundStyle(theme.ink.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text("$\(cash)")
                    .font(Typography.number(.footnote, weight: .semibold))
                    .foregroundStyle(cash >= installment ? theme.ink.safe : theme.ink.ink)
                Text("/")
                    .font(Typography.number(.footnote))
                    .foregroundStyle(theme.ink.hairline)
                Text("$\(installment)")
                    .font(Typography.number(.footnote))
                    .foregroundStyle(theme.ink.muted)
            }
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .fill(theme.ink.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Measure.cardRadius)
                            .stroke(theme.ink.hairline, lineWidth: Measure.hairline)
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
                .stroke(theme.ink.hairline, lineWidth: Measure.hairline)
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
                .foregroundStyle(theme.ink.ink)
            SpecimenRule().frame(width: 92)
            // Identifying a fossil early is only worth paying for if the name tells you
            // something you can act on. These two lines are that: whether the slab is worth
            // half as much again, and how easily it breaks under the brush.
            if engine.isIdentified {
                if engine.isFirstFind {
                    Text("NEVER CATALOGUED · PAYS MORE")
                        .font(Typography.label(.caption2))
                        .tracking(0.9)
                        .foregroundStyle(theme.ink.stamp)
                }
                Text(engine.fragilityNote)
                    .font(Typography.label(.caption2))
                    .tracking(0.9)
                    .foregroundStyle(
                        engine.fossil.crackMultiplier > 1.15 ? theme.ink.stamp : theme.ink.muted
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.ink.page.opacity(0.76))
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
                .foregroundStyle(theme.ink.page)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.ink.stamp)
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
                        .foregroundStyle(theme.ink.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(theme.ink.hairline, lineWidth: Measure.hairline)
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
            // This used to be three colours, ink, accent and danger. The last two are
            // one `stamp` now, so what separates "some damage" from "badly broken" is
            // motion: below 60 the number pulses. Red in motion, spec §5.
            Readout(
                label: "Intact",
                value: "\(engine.intactPercent)%",
                tint: engine.intactPercent >= 90 ? nil : theme.ink.stamp,
                isAlarmed: engine.intactPercent < 60
            )
            Readout(label: "Est. value", value: "$\(engine.estimatedValue)")
            if engine.wholeGems > 0 {
                Readout(
                    label: engine.wholeGems == 1 ? "Gem" : "Gems",
                    value: "\(engine.wholeGems)",
                    tint: theme.ink.gem
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
                .foregroundStyle(theme.ink.page)
                .frame(maxWidth: .infinity)
                .scaledControlHeight(52)
                .background(theme.ink.stamp)
                .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        }
        .accessibilityLabel("Bag it")
        .accessibilityHint("Ends the dig and banks the specimen at its current value.")
    }

    // MARK: Lifecycle

    /// A gust landed. The slab has already changed; this is the part the player feels.
    private func gusted(_ strength: Float) {
        guard let result = engine.gust(strength: strength) else { return }
        guard result.didAnything else { return }
        if result.cracksStarted > 0 {
            haptics.crack()
            audio.playCrack()
            showCrackHint()
        } else {
            haptics.boneRevealed()
        }
        // Spoken, because the slab changing everywhere at once is the one event on this
        // screen with no sound of its own and no place on it to look.
        AccessibilityNotification.Announcement(
            result.cracksStarted > 0
                ? "Dust blows off. Bone cracked."
                : "Dust blows off the slab."
        ).post()
    }

    private func start() {
        scene.engine = engine
        // Before `configureRenderer()`, which is what reads it: a dig on a dim site
        // lights the whole page from there, once, because `lightLevel` is static per
        // site. Without this line the night palette is only ever reached in tests.
        scene.theme = theme
        scene.haptics = haptics
        scene.audio = audio
        scene.reducedMotion = reduceMotion
        scene.trail = trail
        scene.onCrack = showCrackHint
        scene.configureRenderer()
        haptics.isEnabled = settings.hapticsEnabled
        audio.isEnabled = settings.soundEnabled
        haptics.prepare()
        audio.prepare()
        guard settings.breathEnabled else { return }
        breath.onGust = { strength in gusted(strength) }
        Task { await breath.start() }
    }

    private func stop() {
        haptics.teardown()
        audio.teardown()
        breath.teardown()
    }

    private func showCrackHint() {
        // §7: crack feedback must not rely on colour alone. There is already a haptic and
        // a speed meter whose fill crosses a notch, but a player using VoiceOver gets
        // neither — so the crack is spoken. Announced on every crack, not just the first,
        // because it is the only channel that player has.
        AccessibilityNotification.Announcement("Bone cracked. Slow down.").post()
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

    @Environment(\.theme) private var theme

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
            .foregroundStyle(isSelected ? theme.ink.page : theme.ink.muted)
            .frame(maxWidth: .infinity)
            .scaledControlHeight(52)
            .background(isSelected ? theme.ink.ink : theme.ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(isSelected ? Color.clear : theme.ink.hairline, lineWidth: Measure.hairline)
            )
        }
        .accessibilityLabel(tool.name)
        .accessibilityValue(
            "Safe up to \(String(format: "%.1f", tool.safeSpeed)) cells per frame"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
