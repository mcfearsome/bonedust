import BonedustCore
import SwiftUI

/// Routes between the run's screens and owns the objects that outlive a slab.
///
/// Navigation is a switch on `coordinator.screen` rather than a `NavigationStack`:
/// the flow is a state machine driven by `RunState.phase`, there is no "back" out of
/// a slab, and a push/pop stack would be a second source of truth to keep in step.
struct RootView: View {

    @State private var settings = GameSettings()
    @State private var coordinator: RunCoordinator
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = GameSettings()
        let coordinator = RunCoordinator(settings: settings, store: RunStore())
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: coordinator)
    }

    var body: some View {
        content
            .environment(settings)
            .preferredColorScheme(.dark)
            .tint(Ink.accent)
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    settings: settings,
                    onAbandonRun: coordinator.run == nil ? nil : { coordinator.abandonRun() }
                )
            }
            // §5: the slab is written when the app leaves the foreground, which is the
            // only moment the mid-dig guarantee actually has to hold.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { coordinator.autosave() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.screen {
        case .title:
            TitleView(coordinator: coordinator, showSettings: $showSettings)

        case .siteSelect:
            SiteSelectView(
                coordinator: coordinator,
                onPick: { coordinator.startRun(siteID: $0) },
                onCancel: { coordinator.showTitle() }
            )

        case .dig:
            if let engine = coordinator.digEngine, let run = coordinator.run {
                DigView(
                    engine: engine,
                    day: run.currentDay,
                    totalDays: run.totalDays,
                    cash: run.cash,
                    installment: run.installment,
                    onBagged: { coordinator.slabFinished($0) }
                )
                // Keyed on the slab's seed so a new day builds a new view rather than
                // reusing the previous dig's gesture and scene state.
                .id(engine.layout.seed)
            } else {
                recovery
            }

        case .slabResults:
            if let record = coordinator.lastRecord,
               let run = coordinator.run,
               let fossil = ContentCatalog.shared.fossil(record.fossilID) {
                SlabResultsView(
                    record: record,
                    fossil: fossil,
                    run: run,
                    onContinue: { coordinator.continueFromResults() }
                )
            } else {
                recovery
            }

        case .supplyTent:
            if let run = coordinator.run, case .supplyTent(let day) = run.phase {
                SupplyTentView(
                    run: run,
                    day: day,
                    reputation: coordinator.meta.reputation,
                    onBuyTool: { coordinator.buyTool($0) },
                    onBuyCharm: { coordinator.buyCharm($0) },
                    onSellTool: { coordinator.sellTool($0) },
                    onSellCharm: { coordinator.sellCharm($0) },
                    onRestock: { coordinator.restock() },
                    onLeave: { coordinator.leaveShop() }
                )
            } else {
                recovery
            }

        case .runEnd:
            if let run = coordinator.run {
                RunEndView(
                    run: run,
                    meta: coordinator.meta,
                    onDone: { coordinator.acknowledgeRunEnd() }
                )
            } else {
                recovery
            }
        }
    }

    /// Shown only if a screen's data went missing, which should not happen. Better a
    /// way back to the title than a blank screen the player cannot leave.
    private var recovery: some View {
        VStack(spacing: 14) {
            Text("That dig got away from us.")
                .font(Typography.ui(.headline))
                .foregroundStyle(Ink.ivory)
            Button("Back to the title") { coordinator.showTitle() }
                .font(Typography.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.ground.ignoresSafeArea())
    }
}
