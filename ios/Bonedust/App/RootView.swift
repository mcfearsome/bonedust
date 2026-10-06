import BonedustCore
import SwiftUI

/// Routes between the run's screens and owns the objects that outlive a slab.
///
/// Navigation is a switch on `coordinator.screen` rather than a `NavigationStack`:
/// the flow is a state machine driven by `RunState.phase`, there is no "back" out of
/// a slab, and a push/pop stack would be a second source of truth to keep in step.
struct RootView: View {

    @State private var settings = GameSettings()
    /// The one palette the whole app reads. A dig on a dim site flips it through
    /// `DigScene.configureRenderer()`, so this is also where it is put back.
    @State private var theme = Theme()
    @State private var coordinator: RunCoordinator
    @State private var gameCenter = GameCenterService()
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
            .environment(\.theme, theme)
            .onAppear(perform: connectGameCenter)
            // The page is cream by day and lamp-lit at night, and the status bar and
            // system controls follow it. Forced dark, the clock is white on cream.
            .preferredColorScheme(theme.ink == .night ? .dark : .light)
            .tint(theme.ink.stamp)
            // A dig on a dim site lights the page from `DigScene.configureRenderer()`. This is
            // the other half: the dig opens in its own light instead of flashing the day page
            // first, and the day comes back when it ends. Every other screen is lit by no site
            // and reads the day palette (the migration shim in DesignTokens), so a night scheme
            // left behind would put light controls and a white clock on a cream page.
            .onChange(of: coordinator.screen, initial: true) { _, screen in
                theme.lightLevel = screen == .dig
                    ? coordinator.digEngine?.site.modifiers.lightLevel ?? 1
                    : 1
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    settings: settings,
                    trails: coordinator.unlockedTrails,
                    selectedTrailID: coordinator.selectedTrail.id,
                    lockedTrails: ContentCatalog.shared.trails.filter {
                        $0.reputationRequired > coordinator.meta.reputation
                    },
                    onSelectTrail: { coordinator.selectTrail($0) },
                    onAbandonRun: coordinator.run == nil ? nil : { coordinator.abandonRun() }
                )
            }
            // §5: the slab is written when the app leaves the foreground, which is the
            // only moment the mid-dig guarantee actually has to hold.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    coordinator.autosave()
                } else {
                    // Coming back to the foreground is when a player who dug offline is
                    // most likely to have a connection again.
                    Task { await coordinator.ledger.flush() }
                }
            }
    }

    /// Game Center is wired up here rather than inside the coordinator, so the run loop
    /// has no dependency on it at all and a player who is not signed in gets exactly the
    /// same game.
    private func connectGameCenter() {
        gameCenter.authenticate()
        coordinator.onRunAbsorbed = { meta, rewards in
            gameCenter.record(meta, rewards: rewards, gentleMode: settings.gentleMode)
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
                onPick: { site in Task { await coordinator.startRun(siteID: site) } },
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
                    trail: coordinator.selectedTrail,
                    onBagged: { coordinator.slabFinished($0) }
                )
                // Keyed on the slab's seed so a new day builds a new view rather than
                // reusing the previous dig's gesture and scene state.
                .id(engine.layout.seed)
            } else {
                recovery
            }

        case .sellSlab:
            // The slab is bagged but nothing is banked: who takes it decides what it pays,
            // what it costs in attention, and whether the crew sees any of it.
            if let record = coordinator.pendingSale,
               let run = coordinator.run,
               let fossil = ContentCatalog.shared.fossil(record.fossilID) {
                SellView(
                    record: record,
                    fossil: fossil,
                    run: run,
                    onSell: { coordinator.sell(to: $0) }
                )
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
                    // The slab has been banked but the run is not over, so the Collection
                    // has not absorbed it yet. Show the pips as they will stand.
                    collection: coordinator.collectionIncludingCurrentRun,
                    onContinue: { Task { await coordinator.continueFromResults() } }
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
                    onLeave: { Task { await coordinator.leaveShop() } }
                )
            } else {
                recovery
            }

        case .collection:
            CollectionView(meta: coordinator.meta) { coordinator.showTitle() }

        case .camp:
            CampView(
                meta: coordinator.meta,
                onBuy: { coordinator.buy(upgrade: $0) },
                onLeave: { coordinator.showTitle() }
            )

        case .crewLedger:
            CrewLedgerView(
                store: coordinator.ledger,
                meta: coordinator.meta,
                onOutfit: { coordinator.showOutfit() },
                onClose: { coordinator.showTitle() }
            )

        case .outfit:
            OutfitView(store: coordinator.ledger) { coordinator.showCrewLedger() }

        case .runEnd:
            if let run = coordinator.run {
                RunEndView(
                    run: run,
                    meta: coordinator.meta,
                    rewards: coordinator.lastRewards,
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
                .foregroundStyle(theme.ink.ink)
            Button("Back to the title") { coordinator.showTitle() }
                .font(Typography.ui(.subheadline, weight: .semibold))
                .foregroundStyle(theme.ink.stamp)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.ink.page.ignoresSafeArea())
    }
}
