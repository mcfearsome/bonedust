import BonedustCore
import Foundation
import Observation

/// Owns one slab: the simulation, the daylight clock, and the readouts the HUD binds
/// to. Knows nothing about SpriteKit, haptics or audio.
///
/// The split that matters: `sim` is `@ObservationIgnored`. Coalesced touches mutate
/// it up to 120 times a second, and if it were observed, every one of those would
/// invalidate the entire SwiftUI HUD. Instead the scene calls `publish()` once per
/// frame, which writes the observed scalars only when they have actually changed.
@MainActor
@Observable
final class DigEngine {

    enum Phase: Equatable {
        /// Generated, untouched. Daylight has not started.
        case waiting
        case digging
        /// Out of daylight, or bagged.
        case finished(bagged: Bool)
    }

    // MARK: Fixed for this slab

    let site: Site
    let fossil: Fossil
    let catalog: ContentCatalog
    /// Museum accession number shown on the specimen chip.
    let specimenNumber: Int
    let totalDaylight: Float
    let modifiers: ModifierSet
    /// What the player is carrying. Drives the tool tray and the passive badges.
    let loadout: Loadout

    // MARK: Hot state, deliberately not observed

    @ObservationIgnored private(set) var sim: SlabSimulation

    // MARK: Observed, refreshed once per frame

    var tool: BrushTool {
        didSet { safeSpeed = sim.safeSpeed(for: tool) }
    }
    private(set) var phase: Phase = .waiting
    private(set) var daylightRemaining: Float
    private(set) var exposurePercent = 0
    private(set) var intactPercent = 100
    private(set) var estimatedValue = 0
    private(set) var speed: Float = 0
    /// Whether the last brush sample was on exposed bone.
    ///
    /// Published for the speed meter, which only warns about speed where speed can break
    /// something. The simulation guards cracking on `depth == 0 && bone`, so over bare rock
    /// going fast costs nothing — and a meter that said otherwise sent careful players into
    /// the one strategy that cannot pay an installment.
    private(set) var isBrushOverBone = false
    @ObservationIgnored private var lastGustAt: TimeInterval = -.greatestFiniteMagnitude
    private(set) var safeSpeed: Float = 1.4
    private(set) var isIdentified = false
    private(set) var wholeGems = 0
    /// Set the first time a crack happens, for the one diegetic hint in §9.
    private(set) var hasCracked = false
    /// Seconds of X-ray goggle reveal left. Counts down only while digging, so looking
    /// at the slab before the first touch does not spend it.
    private(set) var revealRemaining: Float = 0

    var isRevealing: Bool { revealRemaining > 0 }

    /// Brushes the player can select, and the always-on tools they are carrying.
    var availableBrushes: [BrushTool] { loadout.brushes }
    var passiveTools: [Tool] { loadout.passives }

    // MARK: Init

    init(
        seed: UInt64,
        site: Site,
        day: Int = 1,
        loadout: Loadout = Loadout(),
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard,
        extraModifiers: ModifierSet = ModifierSet(),
        tool: BrushTool? = nil
    ) {
        let generated = SlabGenerator.generate(
            seed: seed, site: site, catalog: catalog, tuning: tuning
        )
        let fossil = catalog.fossil(generated.layout.fossilID) ?? catalog.fossils[0]

        var composed = ModifierSet.combining([
            site.modifiers.modifierSet,
            loadout.modifiers(context: CharmContext(day: day, siteID: site.id)),
            extraModifiers,
        ])
        // Fossil fragility multiplies the site's. A Knightia at Green River is the
        // worst case in the game and that is the point.
        composed.crackMultiplier *= fossil.crackMultiplier

        self.site = site
        self.fossil = fossil
        self.catalog = catalog
        self.modifiers = composed
        self.loadout = loadout
        self.specimenNumber = Int(seed % 9_000) + 1_000
        self.tool = tool ?? loadout.brushes.first ?? .brush

        var simulation = SlabSimulation(
            grid: generated.grid, layout: generated.layout, tuning: tuning
        )
        simulation.crackMultiplier = composed.crackMultiplier
        simulation.safeSpeedMultiplier = composed.safeSpeedMultiplier
        simulation.rockHardnessMultiplier = composed.rockHardnessMultiplier
        self.sim = simulation

        let daylight = max(5, tuning.daylightSeconds + composed.daylightDelta)
        self.totalDaylight = daylight
        self.daylightRemaining = daylight
        self.safeSpeed = simulation.safeSpeed(for: self.tool)
        self.revealRemaining = composed.revealSeconds
        publish(force: true)
    }

    /// Resumes a dig from an autosave (§5). Daylight picks up where it paused.
    init(
        restored: SlabSnapshot.Restored,
        site: Site,
        loadout: Loadout = Loadout(),
        catalog: ContentCatalog = .shared,
        extraModifiers: ModifierSet = ModifierSet()
    ) {
        let simulation = restored.simulation
        let fossil = catalog.fossil(simulation.layout.fossilID) ?? catalog.fossils[0]
        var composed = ModifierSet.combining([
            site.modifiers.modifierSet,
            loadout.modifiers(context: CharmContext(day: restored.day, siteID: site.id)),
            extraModifiers,
        ])
        composed.crackMultiplier *= fossil.crackMultiplier

        self.site = site
        self.loadout = loadout
        self.fossil = fossil
        self.catalog = catalog
        self.modifiers = composed
        self.specimenNumber = Int(simulation.layout.seed % 9_000) + 1_000
        self.tool = restored.tool
        self.sim = simulation
        // The slab was already in progress, so the clock does not restart: total
        // daylight is reconstructed from the budget, and what is left is what was saved.
        self.totalDaylight = max(5, simulation.tuning.daylightSeconds + composed.daylightDelta)
        self.daylightRemaining = min(restored.daylightRemaining, self.totalDaylight)
        self.safeSpeed = simulation.safeSpeed(for: restored.tool)
        // The reveal is spent: it is three seconds at the start of a slab, not three
        // seconds every time the app is reopened.
        self.revealRemaining = 0
        // Waiting, not digging: §5 says the slab comes back with daylight paused, and
        // it resumes on the next touch.
        self.phase = .waiting
        publish(force: true)
    }

    /// Captures the dig for the autosave slot.
    func snapshot(day: Int) -> SlabSnapshot {
        SlabSnapshot.capture(
            sim, daylightRemaining: daylightRemaining, toolID: tool.id, day: day
        )
    }

    /// The record the run banks for this slab.
    func slabRecord(day: Int) -> SlabRecord {
        var bagged = false
        if case .finished(let wasBagged) = phase { bagged = wasBagged }
        return SlabRecord(
            day: day,
            seed: sim.layout.seed,
            siteID: site.id,
            fossilID: fossil.id,
            payout: payout(),
            durationMillis: Int(elapsedSeconds * 1_000),
            bagged: bagged,
            wholeGems: sim.wholeGems,
            daylightLeft: max(0, daylightRemaining),
            identified: isIdentified
        )
    }

    // MARK: Derived

    var layout: SlabLayout { sim.layout }

    // Read-only windows onto the simulation, so the scene can render and route
    // feedback without being handed a mutable reference to the dig.
    var grid: SlabGrid { sim.grid }
    var isBrushing: Bool { sim.isBrushing }
    var exposedBoneCells: Int { sim.exposedBone }
    var crackedBoneCells: Int { sim.crackedBone }

    /// Hands the changed rectangle to the renderer and clears it.
    func consumeDirtyRegion() -> DirtyRegion { sim.consumeDirty() }

    func markEverythingDirty() { sim.markEverythingDirty() }

    /// True when the brush is currently over an exposed bone cell, for haptic grain.
    func isOverBone(_ point: Vec2) -> Bool {
        let x = Int(point.x), y = Int(point.y)
        guard SlabGrid.contains(x, y) else { return false }
        let index = SlabGrid.index(x, y)
        return sim.grid.isBone(index) && sim.grid.isExposed(index)
    }

    var specimenCode: String { String(format: "BD-%04d", specimenNumber) }

    /// §3: hidden until exposure reaches the identify threshold.
    var specimenName: String { isIdentified ? fossil.name : "Unidentified" }

    /// Seconds of daylight spent so far, for the slab record's duration.
    var elapsedSeconds: Float { max(0, totalDaylight - daylightRemaining) }

    var daylightFraction: Float {
        totalDaylight <= 0 ? 0 : max(0, daylightRemaining / totalDaylight)
    }

    var isOverSafeSpeed: Bool { speed > safeSpeed }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Rock nodules whose every cell has been cleared, for the Rock hound charm.
    /// Flood-filled on demand at bag time rather than tracked per cell — it is once
    /// per slab, and tracking nodule membership would need a byte per cell.
    func clearedNodules() -> Int {
        guard modifiers.rockNodulePayout > 0 else { return 0 }
        var seen = [Bool](repeating: false, count: SlabGrid.cellCount)
        var cleared = 0
        var stack: [Int] = []
        for start in 0..<SlabGrid.cellCount where !seen[start] && sim.grid.isRock(start) {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            var allExposed = true
            while let index = stack.popLast() {
                if sim.grid.cells[index].depth > 0 { allExposed = false }
                let x = index % SlabGrid.width
                let y = index / SlabGrid.width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard SlabGrid.contains(nx, ny) else { continue }
                    let neighbour = SlabGrid.index(nx, ny)
                    guard !seen[neighbour], sim.grid.isRock(neighbour) else { continue }
                    seen[neighbour] = true
                    stack.append(neighbour)
                }
            }
            if allExposed { cleared += 1 }
        }
        return cleared
    }

    func payout() -> PayoutBreakdown {
        Payout.evaluate(PayoutContext(
            baseValue: fossil.baseValue,
            instances: sim.layout.instances,
            exposure: sim.exposure,
            boneCells: sim.boneCells,
            crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems,
            clearedNodules: clearedNodules(),
            daylightRemaining: max(0, daylightRemaining),
            totalDaylight: totalDaylight,
            modifiers: modifiers,
            tuning: sim.tuning
        ))
    }

    // MARK: Input

    @discardableResult
    func brushBegan(at point: Vec2) -> StrokeResult {
        startDaylightIfNeeded()
        guard !isFinished else { return StrokeResult() }
        isBrushOverBone = isOverBone(point)
        return record(sim.beginStroke(at: point, tool: tool))
    }

    @discardableResult
    func brushMoved(to point: Vec2, deltaMillis: Float) -> StrokeResult {
        guard !isFinished else { return StrokeResult() }
        isBrushOverBone = isOverBone(point)
        return record(sim.moveStroke(to: point, deltaMillis: deltaMillis, tool: tool))
    }

    /// Blows loose material off patches across the whole slab (§ breath).
    ///
    /// Rate-limited here rather than in the detector, because the cooldown is a rule of the
    /// game and belongs with the other rules -- the detector only knows about microphones.
    /// Returns nil when the gust was swallowed by the cooldown or the slab is over.
    @discardableResult
    func gust(strength: Float) -> SlabSimulation.GustResult? {
        guard !isFinished, strength > 0 else { return nil }
        let now = Date.timeIntervalSinceReferenceDate
        let cooldown = Double(sim.tuning.gustCooldownSeconds)
        guard now - lastGustAt >= cooldown else { return nil }
        lastGustAt = now
        let result = sim.gust(strength: strength)
        publish(force: true)
        return result
    }

    func brushEnded() {
        sim.endStroke()
        // Finger up: there is no brush, so it is not over anything.
        isBrushOverBone = false
    }

    private func record(_ result: StrokeResult) -> StrokeResult {
        if result.cracksStarted > 0 { hasCracked = true }
        return result
    }

    /// §3: the daylight timer starts on the first touch, not when the slab appears.
    /// A player should be able to look at the slab and plan.
    private func startDaylightIfNeeded() {
        guard phase == .waiting else { return }
        phase = .digging
    }

    // MARK: Clock

    func tick(delta: TimeInterval) {
        guard phase == .digging else { return }
        if revealRemaining > 0 {
            revealRemaining = max(0, revealRemaining - Float(delta))
        }
        if !sim.isBrushing {
            // The EMA decays in frames, so convert. 60 Hz nominal.
            sim.tickIdle(frames: max(1, Int((delta * 60).rounded())))
        }
        daylightRemaining -= Float(delta)
        if daylightRemaining <= 0 {
            daylightRemaining = 0
            finish(bagged: false)
        }
    }

    func bagIt() {
        guard phase != .waiting || sim.exposedBone > 0 else { return }
        finish(bagged: true)
    }

    private func finish(bagged: Bool) {
        guard !isFinished else { return }
        sim.endStroke()
        phase = .finished(bagged: bagged)
        publish(force: true)
    }

    /// Mid-slab autosave support (§5): daylight is paused simply by not ticking.
    func pause() {
        if phase == .digging { sim.endStroke() }
    }

    // MARK: Publishing

    /// Copies the handful of values the HUD binds to out of the simulation, writing
    /// only what changed so SwiftUI does not invalidate on every frame.
    func publish(force: Bool = false) {
        let exposure = Int((sim.exposure * 100).rounded())
        if force || exposure != exposurePercent { exposurePercent = exposure }

        let intact = Int((sim.intact * 100).rounded())
        if force || intact != intactPercent { intactPercent = intact }

        let identified = sim.exposure >= modifiers.identifyExposure
        if force || identified != isIdentified { isIdentified = identified }

        if force || sim.wholeGems != wholeGems { wholeGems = sim.wholeGems }

        // Speed drives the meter, which has to move smoothly, so it is published
        // every frame rather than only on change.
        speed = sim.speed

        let value = payoutEstimate()
        if force || value != estimatedValue { estimatedValue = value }
    }

    /// The "Est. value" readout. Deliberately excludes the rush bonus and nodule
    /// money: showing a number that jumps when a timer crosses a threshold would read
    /// as a bug, and those are revealed on the results screen instead.
    private func payoutEstimate() -> Int {
        var quiet = modifiers
        quiet.rushMultiplier = 1
        quiet.rockNodulePayout = 0
        return Payout.evaluate(PayoutContext(
            baseValue: fossil.baseValue,
            instances: sim.layout.instances,
            exposure: sim.exposure,
            boneCells: sim.boneCells,
            crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems,
            clearedNodules: 0,
            daylightRemaining: 0,
            totalDaylight: totalDaylight,
            modifiers: quiet,
            tuning: sim.tuning
        )).total
    }

    // MARK: Debug

    /// Used by the M1 debug overlay, which retunes constants with a dig in progress.
    func applyTuning(_ tuning: SimTuning) {
        sim.tuning = tuning
        safeSpeed = sim.safeSpeed(for: tool)
        publish(force: true)
    }
}
