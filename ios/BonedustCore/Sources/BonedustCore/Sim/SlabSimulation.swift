import Foundation

/// The dig. Pure value type, no rendering, no clock — the caller supplies time.
///
/// Three properties make this testable and deterministic:
///
/// - It owns its own PRNG, forked from the slab seed, so crack rolls cannot
///   desynchronise generation and vice versa.
/// - Removal is a function of *distance brushed*, never of elapsed time (§3). A
///   held finger does nothing; you have to sweep.
/// - Nothing reads the system clock. `moveStroke` takes the frame delta, so a
///   recorded input trace replays bit-identically.
public struct SlabSimulation: Sendable {

    // MARK: Slab state

    public private(set) var grid: SlabGrid
    public let layout: SlabLayout
    /// Mutable so the M1 debug overlay can retune the sim with the slab in progress.
    public var tuning: SimTuning

    // MARK: Composed modifiers
    //
    // Site twists, fossil fragility, charms and set perks all land here as plain
    // multipliers. That is the whole reason charms can stack and stay
    // order-independent: nothing special-cases a charm inside the brush loop.

    /// Multiplies the tool's crack multiplier. Site twist x fossil fragility x charms.
    public var crackMultiplier: Float = 1
    /// The site's share of that, alone.
    ///
    /// Kept separately because the baseline fragility has to be scaled by the site but
    /// *not* by the fossil. A fossil's own multiplier is written for thin, breakable
    /// shapes -- a knightia's ribs, a leaf's veins -- and `propagateCrack` walks across
    /// adjacent bone, so a crack cannot travel far inside a one-cell-wide feature.
    /// Contact-driven cracking therefore damages chunky fossils *more*, and folding the
    /// fossil term into the baseline made Green River, whose entire twist is fragility,
    /// come out 3.8 points more intact than Charmouth.
    public var siteCrackMultiplier: Float = 1
    /// Multiplies every tool's safe speed. "Steady hands" sets this to 1.25.
    public var safeSpeedMultiplier: Float = 1
    /// Multiplies rock hardness. The dental pick sets this to 0.33.
    public var rockHardnessMultiplier: Float = 1

    // MARK: Live metrics (maintained incrementally)

    public private(set) var exposedBone = 0
    public private(set) var crackedBone = 0
    public private(set) var exposedGemCells = 0
    public private(set) var wholeGems = 0
    public private(set) var rockCellsCleared = 0
    /// The speed EMA, in cells per 60 Hz frame.
    public private(set) var speed: Float = 0
    public private(set) var dirty: DirtyRegion = .everything
    public private(set) var isBrushing = false

    // MARK: Private

    private var rng: SplitMix64
    private var kernel: BrushKernel
    private var lastPoint: Vec2?

    // MARK: - Init

    /// `randomState` resumes a dig in progress. Leave it nil for a fresh slab.
    ///
    /// It has to be part of the restorable state, not re-derived from the seed: §5
    /// allows killing the app mid-slab, and a sim that re-seeded on load would let a
    /// player who cracked a Triceratops horn force-quit and re-roll the crack
    /// results. Persisting it costs eight bytes and closes that off.
    public init(
        grid: SlabGrid,
        layout: SlabLayout,
        tuning: SimTuning = .standard,
        randomState: UInt64? = nil
    ) {
        self.grid = grid
        self.layout = layout
        self.tuning = tuning
        // A separate stream for gameplay. Seeded from the slab seed so replays are
        // reproducible, but independent of the generation draws.
        self.rng = SplitMix64(
            seed: randomState ?? SlabSimulation.gameplaySeed(from: layout.seed)
        )
        self.kernel = BrushKernel(radius: BrushTool.brush.radius)
        recountMetrics()
    }

    /// The gameplay PRNG's position. Save this alongside the grid.
    public var randomState: UInt64 { rng.state }

    public init(
        seed: UInt64,
        site: Site,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) {
        let generated = SlabGenerator.generate(
            seed: seed, site: site, catalog: catalog, tuning: tuning
        )
        self.init(grid: generated.grid, layout: generated.layout, tuning: tuning)
        self.siteCrackMultiplier = site.modifiers.crackMultiplier
        self.crackMultiplier = site.modifiers.crackMultiplier
            * (catalog.fossil(generated.layout.fossilID)?.crackMultiplier ?? 1)
    }

    static func gameplaySeed(from slabSeed: UInt64) -> UInt64 {
        // Any fixed, reversible mix works; this one just has to be different from
        // the generation seed so the two streams never line up.
        slabSeed ^ 0xD1B5_4A32_D192_ED03
    }

    // MARK: - Metrics

    public var boneCells: Int { layout.boneCells }

    /// Fraction of the fossil that is showing.
    public var exposure: Float {
        boneCells == 0 ? 0 : Float(exposedBone) / Float(boneCells)
    }

    /// 1.0 for a perfect specimen, 0 once a third of the bone is cracked.
    public var intact: Float {
        guard boneCells > 0 else { return 1 }
        return max(0, 1 - Float(crackedBone) / Float(boneCells) * tuning.intactCrackWeight)
    }

    public var isIdentified: Bool { exposure >= tuning.identifyExposure }

    /// Full rescan. Used at init and after loading a save; never in the hot path.
    public mutating func recountMetrics() {
        var exposed = 0, cracked = 0, gemCells = 0, rockCleared = 0
        for cell in grid.cells {
            let bone = cell.flags & SlabGrid.Flag.bone != 0
            if bone, cell.flags & SlabGrid.Flag.cracked != 0 { cracked += 1 }
            guard cell.depth == 0 else { continue }
            if bone { exposed += 1 }
            if cell.flags & SlabGrid.Flag.gem != 0 { gemCells += 1 }
            if cell.flags & SlabGrid.Flag.rock != 0 { rockCleared += 1 }
        }
        exposedBone = exposed
        crackedBone = cracked
        exposedGemCells = gemCells
        rockCellsCleared = rockCleared
        wholeGems = countWholeGems()
    }

    private func countWholeGems() -> Int {
        var whole = 0
        for origin in layout.gemClusters {
            let x = origin % SlabGrid.width
            let y = origin / SlabGrid.width
            guard x + 1 < SlabGrid.width, y + 1 < SlabGrid.height else { continue }
            let indices = [
                origin, origin + 1,
                SlabGrid.index(x, y + 1), SlabGrid.index(x + 1, y + 1),
            ]
            if indices.allSatisfy({ grid.cells[$0].depth == 0 }) { whole += 1 }
        }
        return whole
    }

    // MARK: - Dirty tracking

    /// Hands the changed rectangle to the renderer and clears it.
    public mutating func consumeDirty() -> DirtyRegion {
        let region = dirty
        dirty = .empty
        return region
    }

    public mutating func markEverythingDirty() { dirty = .everything }

    /// Marks one cell for repaint without changing it.
    ///
    /// For the gem shimmer, which animates cells the brush never touched.
    public mutating func markDirty(x: Int, y: Int) {
        guard SlabGrid.contains(x, y) else { return }
        dirty.insert(x: x, y: y)
    }

    /// Sets a cell's depth directly. Only for rendering reference frames, where the point
    /// is to see a specific layer rather than to simulate reaching it.
    public mutating func setDepthForRendering(_ index: Int, depth: UInt8) {
        guard grid.cells.indices.contains(index) else { return }
        grid.cells[index].depth = depth
        grid.cells[index].wear = 0
        dirty = .everything
        recountMetrics()
    }

    // MARK: - Input

    /// Finger down. Applies one step's worth of brushing so that a tap does
    /// something — removal is distance-based, so a stationary touch would
    /// otherwise be inert and the slab would feel dead on first contact.
    @discardableResult
    public mutating func beginStroke(at point: Vec2, tool: BrushTool) -> StrokeResult {
        isBrushing = true
        lastPoint = point
        let seg = tool.radius * tuning.stepFactor
        return brush(from: point, to: point, steps: 1, seg: seg, tool: tool)
    }

    /// Finger moved. `deltaMillis` is the time since the previous sample.
    @discardableResult
    public mutating func moveStroke(
        to point: Vec2, deltaMillis: Float, tool: BrushTool
    ) -> StrokeResult {
        guard isBrushing else { return beginStroke(at: point, tool: tool) }
        let from = lastPoint ?? point
        let delta = point - from
        let distance = delta.length
        updateSpeed(distance: distance, deltaMillis: deltaMillis)
        lastPoint = point

        guard distance > 0.0001 else {
            var idle = StrokeResult()
            idle.speed = speed
            return idle
        }
        // §3: steps = max(1, ceil(dist / (r * 0.35))), seg = dist / steps. Without
        // this a fast flick would apply one huge brush stamp at the destination and
        // tunnel straight through the slab.
        let stride = max(0.0001, tool.radius * tuning.stepFactor)
        let steps = max(1, Int((distance / stride).rounded(.up)))
        let seg = distance / Float(steps)
        var result = brush(from: from, to: point, steps: steps, seg: seg, tool: tool)
        result.distance = distance
        return result
    }

    public mutating func endStroke() {
        isBrushing = false
        lastPoint = nil
    }

    /// Decays the speed EMA while no finger is down. Call once per rendered frame.
    public mutating func tickIdle(frames: Int = 1) {
        guard frames > 0 else { return }
        speed *= pow(tuning.emaIdleDecay, Float(frames))
        if speed < 0.0005 { speed = 0 }
    }

    private mutating func updateSpeed(distance: Float, deltaMillis: Float) {
        // Clamp the sample rather than the EMA: one long frame (a scroll hitch, the
        // debugger pausing) should not read as a 200 cell/frame swipe and shatter
        // the fossil the player was being careful with.
        let dt = max(4, min(100, deltaMillis))
        let v = min(tuning.maxSampleSpeed, distance * tuning.referenceFrameMillis / dt)
        speed = speed * (1 - tuning.emaAlpha) + v * tuning.emaAlpha
    }

    /// Safe speed for a tool after charms.
    public func safeSpeed(for tool: BrushTool) -> Float {
        tool.safeSpeed * safeSpeedMultiplier
    }

    /// True when the current speed is in the red for this tool.
    public func isOverSafeSpeed(for tool: BrushTool) -> Bool {
        speed > safeSpeed(for: tool)
    }

    // MARK: - The hot loop

    private mutating func brush(
        from: Vec2, to: Vec2, steps: Int, seg: Float, tool: BrushTool
    ) -> StrokeResult {
        if kernel.radius != tool.radius {
            kernel = BrushKernel(radius: tool.radius)
        }

        // Everything the loop touches is hoisted into a local, and `self` is not
        // read inside the buffer closure. That keeps one exclusive access on
        // `grid.cells` and keeps the per-cell cost to arithmetic.
        var result = StrokeResult()
        result.speed = speed

        let width = SlabGrid.width
        let height = SlabGrid.height
        let offsets = kernel.offsets
        let hardness = tuning.layerHardness
        let rockHardness = tuning.rockHardnessMultiplier * rockHardnessMultiplier
        let rate = tuning.removalRate
        let strength = tool.strength
        let crackRate = tuning.crackRate
        let crackScale = tool.crackMultiplier * crackMultiplier
        // Two separate pressures on exposed bone, scaled differently on purpose.
        //
        // The baseline -- bone is a little fragile however carefully it is brushed -- is
        // scaled by the *tool* only. The over-speed term keeps the site and fossil twist as
        // well, which is where it has always lived.
        //
        // Folding the site twist into the baseline too looked obvious and inverted Green
        // River: its knightia and leaves are one cell wide, and `propagateCrack` walks
        // across adjacent bone, so a crack cannot travel far in a thin rib. Contact-driven
        // cracking therefore damages *chunky* fossils more, and the site whose whole twist
        // is fragility came out the safest. Keeping the twist on the speed term leaves it
        // measuring what it was written to measure.
        let overSpeed = max(0, speed - safeSpeed(for: tool))
        let baselinePressure = tuning.baselineFragility
            * tool.crackMultiplier * siteCrackMultiplier
        let walkMin = tuning.crackWalkMin
        let walkMax = tuning.crackWalkMax
        let boneFlag = SlabGrid.Flag.bone
        let crackedFlag = SlabGrid.Flag.cracked
        let rockFlag = SlabGrid.Flag.rock
        let gemFlag = SlabGrid.Flag.gem

        var rng = self.rng
        var dirty = self.dirty
        var exposedBone = self.exposedBone
        var crackedBone = self.crackedBone
        var exposedGemCells = self.exposedGemCells
        var rockCellsCleared = self.rockCellsCleared
        var gemCellsRevealed: [Int] = []

        let delta = to - from

        grid.cells.withUnsafeMutableBufferPointer { cells in
            for step in 1...steps {
                let t = Float(step) / Float(steps)
                let px = from.x + delta.x * t
                let py = from.y + delta.y * t
                let baseX = Int(px.rounded(.down))
                let baseY = Int(py.rounded(.down))

                for offset in offsets {
                    let x = baseX + Int(offset.dx)
                    let y = baseY + Int(offset.dy)
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let i = y * width + x
                    let falloff = offset.falloff

                    var cell = cells[i]

                    if cell.depth > 0 {
                        var layerHardness = hardness[Int(cell.depth)]
                        if cell.flags & rockFlag != 0 { layerHardness *= rockHardness }
                        cell.wear += strength * seg * falloff * rate / layerHardness
                        result.cellsWorn += 1

                        while cell.wear >= 1, cell.depth > 0 {
                            cell.wear -= 1
                            let removed = cell.depth
                            cell.depth -= 1
                            result.layersRemoved += 1
                            switch removed {
                            case 3: result.removedTopsoil += 1
                            case 2: result.removedClay += 1
                            default: result.removedSandstone += 1
                            }
                        }
                        if cell.depth == 0 {
                            // §3: carry overflow between layers, but reset at the
                            // floor — there is nothing below to wear into.
                            cell.wear = 0
                            if cell.flags & boneFlag != 0 {
                                exposedBone += 1
                                result.boneRevealed += 1
                            }
                            if cell.flags & gemFlag != 0 {
                                exposedGemCells += 1
                                result.gemCellsRevealed += 1
                                gemCellsRevealed.append(i)
                            }
                            if cell.flags & rockFlag != 0 {
                                rockCellsCleared += 1
                                result.rockCellsCleared += 1
                            }
                        }
                        cells[i] = cell
                        dirty.insert(x: x, y: y)
                    }

                    // Cracking is evaluated after removal, so the very stroke that
                    // uncovers bone can also break it. That is the whole tension of
                    // the air blower: it reveals and ruins in one pass.
                    // Flag checks first: two loads and a branch, and they reject the
                    // overwhelming majority of cells. `pressure` is never zero now, so it
                    // can no longer serve as the early-out it used to be.
                    let flags = cells[i].flags
                    guard cells[i].depth == 0,
                          flags & boneFlag != 0,
                          flags & crackedFlag == 0 else { continue }
                    let probability = (baselinePressure + overSpeed * crackScale)
                        * crackRate * falloff * seg
                    guard probability > 0, rng.nextUnit() < probability else { continue }

                    let length = rng.nextInt(walkMin, through: walkMax)
                    let marked = SlabSimulation.propagateCrack(
                        from: i, length: length, cells: cells, rng: &rng, dirty: &dirty
                    )
                    crackedBone += marked
                    result.cellsCracked += marked
                    result.cracksStarted += 1
                    if result.firstCrackCell == nil { result.firstCrackCell = i }
                }
            }
        }

        self.rng = rng
        self.dirty = dirty
        self.exposedBone = exposedBone
        self.crackedBone = crackedBone
        self.exposedGemCells = exposedGemCells
        self.rockCellsCleared = rockCellsCleared

        if !gemCellsRevealed.isEmpty {
            let before = wholeGems
            wholeGems = countWholeGems()
            result.gemsCompleted = max(0, wholeGems - before)
        }

        return result
    }

    // MARK: - Breath

    /// What one gust did, for haptics, audio and the hint system.
    public struct GustResult: Sendable, Equatable {
        public var patches = 0
        public var cellsLifted = 0
        public var boneRevealed = 0
        public var cracksStarted = 0
        public var crackedCells = 0
        /// True if the gust landed on bone that was already showing.
        public var hitExposedBone = false

        public init() {}
        public var didAnything: Bool { cellsLifted > 0 || cracksStarted > 0 }
    }

    /// Blows loose material off patches scattered across the whole slab.
    ///
    /// `strength` is 0 to 1. It scales how many patches land and how likely each exposed
    /// bone cell inside one is to crack.
    ///
    /// Three things make this a decision rather than a free win:
    ///
    /// **It stops at `gustFloorDepth`.** Breath moves overburden, never the last layer, so
    /// it cannot uncover a fossil for you. Brushing stays the verb the game is about.
    ///
    /// **It cracks bone that is already exposed.** Blowing across a slab you have opened up
    /// wrecks the specimen, exactly as the air blower does, which is why *when* you use it
    /// is the whole question. Early it is most of a dig; late it is vandalism.
    ///
    /// **Every draw comes from the gameplay PRNG**, the same one cracking uses, so the
    /// result is part of `randomState` and survives a save. Force-quitting to re-roll an
    /// unlucky gust does not work, for the same reason it does not work on a crack.
    @discardableResult
    public mutating func gust(strength: Float) -> GustResult {
        var result = GustResult()
        let strength = min(max(strength, 0), 1)
        guard strength > 0 else { return result }

        let patches = Int((Float(tuning.gustPatchesAtFullStrength) * strength).rounded())
        guard patches > 0 else { return result }

        let radius = tuning.gustRadius
        let reach = Int(radius.rounded(.up))
        let radiusSquared = radius * radius
        let floor = tuning.gustFloorDepth
        let crackChance = tuning.gustCrackRate * strength
        let boneFlag = SlabGrid.Flag.bone
        let crackedFlag = SlabGrid.Flag.cracked

        var dirty = self.dirty
        var rng = self.rng
        let boneCellsExposed = exposedBone
        var crackSeeds: [Int] = []

        grid.cells.withUnsafeMutableBufferPointer { cells in
            for _ in 0..<patches {
                // Centres are drawn across the whole slab, which is the point of it: the
                // brush is local and breath is not.
                let cx = rng.nextInt(0, through: SlabGrid.width - 1)
                let cy = rng.nextInt(0, through: SlabGrid.height - 1)
                result.patches += 1

                for y in max(0, cy - reach)...min(SlabGrid.height - 1, cy + reach) {
                    let dy = Float(y - cy)
                    for x in max(0, cx - reach)...min(SlabGrid.width - 1, cx + reach) {
                        let dx = Float(x - cx)
                        guard dx * dx + dy * dy <= radiusSquared else { continue }
                        let i = SlabGrid.index(x, y)
                        var cell = cells[i]

                        if cell.depth > floor {
                            cell.depth -= 1
                            cell.wear = 0
                            cells[i] = cell
                            result.cellsLifted += 1
                            dirty.insert(x: x, y: y)
                            continue
                        }

                        // Already open. Breath cannot help here, and on bone it hurts.
                        guard cell.depth == 0, cell.flags & boneFlag != 0,
                              cell.flags & crackedFlag == 0
                        else { continue }
                        result.hitExposedBone = true
                        guard rng.nextUnit() < crackChance else { continue }
                        crackSeeds.append(i)
                    }
                }
            }

            for origin in crackSeeds {
                guard cells[origin].flags & crackedFlag == 0 else { continue }
                let length = rng.nextInt(tuning.crackWalkMin, through: tuning.crackWalkMax)
                let marked = SlabSimulation.propagateCrack(
                    from: origin, length: length, cells: cells, rng: &rng, dirty: &dirty
                )
                result.crackedCells += marked
                result.cracksStarted += 1
            }
        }

        self.rng = rng
        self.dirty = dirty
        // Recomputed rather than adjusted. Lifting a layer can take a cell to depth 0 over
        // bone, and the loop cannot tell "was already open" from "just opened" without
        // checking twice -- and `recountMetrics` is the one authority on these counts
        // anyway, so tracking them in parallel here would be a second place to be wrong.
        recountMetrics()
        result.boneRevealed = max(0, exposedBone - boneCellsExposed)
        return result
    }

    /// A crack is a random walk across adjacent bone cells, marking each one.
    ///
    /// The walk is not restricted to *exposed* bone, per §3. That is deliberate:
    /// it means you can shatter bone you have not uncovered yet, which is what
    /// makes the depth-1 sandstone tint tell worth learning to read.
    private static func propagateCrack(
        from origin: Int,
        length: Int,
        cells: UnsafeMutableBufferPointer<SlabGrid.Cell>,
        rng: inout SplitMix64,
        dirty: inout DirtyRegion
    ) -> Int {
        let width = SlabGrid.width
        let height = SlabGrid.height
        let boneFlag = SlabGrid.Flag.bone
        let crackedFlag = SlabGrid.Flag.cracked

        var marked = 0
        var current = origin
        cells[current].flags |= crackedFlag
        marked += 1
        dirty.insert(x: current % width, y: current / width)

        var candidates: [Int] = []
        candidates.reserveCapacity(4)

        for _ in 1..<max(1, length) {
            candidates.removeAll(keepingCapacity: true)
            let x = current % width
            let y = current / width
            if x > 0 { candidates.append(current - 1) }
            if x < width - 1 { candidates.append(current + 1) }
            if y > 0 { candidates.append(current - width) }
            if y < height - 1 { candidates.append(current + width) }
            candidates.removeAll { i in
                cells[i].flags & boneFlag == 0 || cells[i].flags & crackedFlag != 0
            }
            guard !candidates.isEmpty else { break }
            let next = candidates[rng.nextInt(below: candidates.count)]
            cells[next].flags |= crackedFlag
            marked += 1
            dirty.insert(x: next % width, y: next / width)
            current = next
        }
        return marked
    }
}
