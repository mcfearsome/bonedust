import Foundation

/// A scripted player, for §9's balance target: "10,000 simulated runs with a scripted
/// average player, reporting win rate per installment tier. Target: about 70% at tier
/// 1 falling to about 30% by tier 5."
///
/// This drives the real simulation rather than sampling from a distribution. It is
/// slower, but a model of the economy that does not actually brush would not notice
/// that, say, raising rock hardness makes Hell Creek unplayable — which is the exact
/// class of problem the sweep exists to catch.
public struct PlayerPolicy: Sendable {

    /// Cells per 60 Hz frame while clearing overburden — the same units as the speed
    /// meter and a tool's `safeSpeed`, *not* cells per input sample. `playSlab`
    /// converts. Mixing the two silently halves the player's speed, which is how this
    /// first read 0% win rate at every tier.
    public var clearingSpeed: Float
    /// Fraction of the tool's safe speed to use once bone is visible under the brush.
    /// Below 1 because a real player undershoots the limit rather than riding it.
    public var cautionFactor: Float
    /// How often the player's finger is sampled. Thirty a second is a fair model of
    /// a thumb; sixty would be a machine.
    public var samplesPerSecond: Float
    /// Bag once this much of the fossil is showing.
    public var bagAtExposure: Float
    public var toolID: String
    /// Spacing between passes, as a fraction of the brush diameter. Slightly under 1
    /// so passes overlap, as a careful player's would.
    public var passOverlap: Float
    /// How far ahead along the path the player notices bone, in input samples.
    ///
    /// This matters more than it looks. The speed EMA smooths at 0.25, so coming down
    /// from a clearing sweep to a safe speed takes about six samples — a fifth of a
    /// second. A player who only reacts once bone is already under the brush cracks it
    /// every time, which is what the depth-1 tell exists to prevent: you see bone
    /// coming and slow *before* you reach it. Zero lookahead models someone who has
    /// not learned to read the slab.
    public var lookaheadSamples: Float

    public init(
        clearingSpeed: Float = 3.2,
        cautionFactor: Float = 0.85,
        samplesPerSecond: Float = 30,
        bagAtExposure: Float = 0.97,
        toolID: String = BrushTool.brush.id,
        passOverlap: Float = 0.8,
        lookaheadSamples: Float = 3
    ) {
        self.clearingSpeed = clearingSpeed
        self.cautionFactor = cautionFactor
        self.samplesPerSecond = samplesPerSecond
        self.bagAtExposure = bagAtExposure
        self.toolID = toolID
        self.passOverlap = passOverlap
        self.lookaheadSamples = lookaheadSamples
    }

    /// The reference player the balance target is stated against: moderately quick,
    /// slows down when they see bone, uses the starting brush.
    public static let average = PlayerPolicy()

    /// Someone who has not learned to read the tell: fast, and reacting only to bone
    /// already under the brush.
    public static let reckless = PlayerPolicy(
        clearingSpeed: 5.5, cautionFactor: 1.6, bagAtExposure: 0.9, lookaheadSamples: 0
    )

    /// Someone who has, and who looks well ahead.
    public static let careful = PlayerPolicy(
        clearingSpeed: 2.2, cautionFactor: 0.6, lookaheadSamples: 6
    )
}

public struct TierReport: Sendable {
    public var tier: Int
    public var installment: Int
    public var runs: Int
    public var wins: Int
    public var meanEarned: Double
    public var meanExposure: Double
    public var meanIntact: Double
    public var meanSlabPayout: Double

    public var winRate: Double { runs == 0 ? 0 : Double(wins) / Double(runs) }
}

public enum EconomySimulator {

    // MARK: One slab

    /// Plays one slab to completion and returns what it would have banked.
    public static func playSlab(
        seed: UInt64,
        day: Int,
        site: Site,
        policy: PlayerPolicy = .average,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard,
        extraModifiers: ModifierSet = ModifierSet()
    ) -> SlabRecord {
        var modifiers = ModifierSet.combining([site.modifiers.modifierSet, extraModifiers])
        let generated = SlabGenerator.generate(
            seed: seed, site: site, catalog: catalog, tuning: tuning
        )
        let fossil = catalog.fossil(generated.layout.fossilID) ?? catalog.fossils[0]
        modifiers.crackMultiplier *= fossil.crackMultiplier

        var sim = SlabSimulation(grid: generated.grid, layout: generated.layout, tuning: tuning)
        sim.crackMultiplier = modifiers.crackMultiplier
        sim.safeSpeedMultiplier = modifiers.safeSpeedMultiplier

        let tool = BrushTool.all.first { $0.id == policy.toolID } ?? .brush
        let daylight = max(5, tuning.daylightSeconds + modifiers.daylightDelta)
        let deltaMillis = 1_000 / policy.samplesPerSecond
        let maxSamples = Int(daylight * policy.samplesPerSecond)
        let safeSpeed = sim.safeSpeed(for: tool)

        // Pass spacing from the brush diameter, so a wide tool covers the slab in
        // fewer passes — which is exactly why the air blower is tempting.
        let rowStep = max(1.5, tool.radius * 2 * policy.passOverlap)
        let path = SerpentinePath(
            x0: 2, x1: Float(SlabGrid.width) - 2,
            y0: 2, y1: Float(SlabGrid.height) - 2,
            rowStep: rowStep
        )

        // Policy speeds are cells per 60 Hz frame; the loop moves the finger once per
        // input sample. At 30 samples a second each sample covers two frames' worth of
        // distance, so the conversion is not optional.
        let framesPerSample = deltaMillis / tuning.referenceFrameMillis
        let clearingTravel = policy.clearingSpeed * framesPerSample
        let cautiousTravel = safeSpeed * policy.cautionFactor * framesPerSample

        var arcLength: Float = 0
        var samples = 0
        sim.beginStroke(at: path.point(at: 0), tool: tool)

        while samples < maxSamples {
            // Look at where the brush is and where it is about to be. Checking only
            // the current position means reacting too late to matter, because the
            // speed EMA takes about six samples to fall from a clearing sweep to a
            // safe speed.
            let lookahead = clearingTravel * policy.lookaheadSamples
            let sees = boneVisible(in: sim.grid, around: path.point(at: arcLength),
                                   radius: tool.radius)
                || (lookahead > 0 && boneVisible(
                    in: sim.grid,
                    around: path.point(at: arcLength + lookahead),
                    radius: tool.radius
                ))
            arcLength += sees ? cautiousTravel : clearingTravel
            sim.moveStroke(to: path.point(at: arcLength), deltaMillis: deltaMillis, tool: tool)
            samples += 1
            if sim.exposure >= policy.bagAtExposure { break }
        }
        sim.endStroke()

        let elapsedSeconds = Float(samples) / policy.samplesPerSecond
        let daylightLeft = max(0, daylight - elapsedSeconds)
        let payout = Payout.evaluate(PayoutContext(
            baseValue: fossil.baseValue,
            exposure: sim.exposure,
            boneCells: sim.boneCells,
            crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems,
            clearedNodules: 0,
            daylightRemaining: daylightLeft,
            modifiers: modifiers,
            tuning: tuning
        ))

        return SlabRecord(
            day: day,
            seed: seed,
            siteID: site.id,
            fossilID: fossil.id,
            payout: payout,
            durationMillis: Int(elapsedSeconds * 1_000),
            bagged: sim.exposure >= policy.bagAtExposure,
            wholeGems: sim.wholeGems,
            daylightLeft: daylightLeft
        )
    }

    /// Does the player have a reason to slow down here?
    ///
    /// A nine-point probe rather than the whole brush footprint: this runs on every
    /// one of ninety million samples in a full sweep, and the answer barely changes.
    private static func boneVisible(
        in grid: SlabGrid, around point: Vec2, radius: Float
    ) -> Bool {
        let reach = radius * 0.75
        for index in 0..<9 {
            let offset: Vec2
            if index == 0 {
                offset = .zero
            } else {
                let angle = Float(index - 1) * (.pi / 4)
                offset = Vec2(cos(angle) * reach, sin(angle) * reach)
            }
            let x = Int(point.x + offset.x)
            let y = Int(point.y + offset.y)
            guard SlabGrid.contains(x, y) else { continue }
            let cell = grid.cells[SlabGrid.index(x, y)]
            guard cell.flags & SlabGrid.Flag.bone != 0 else { continue }
            // Exposed bone, or the sandstone tell showing it through one layer.
            if cell.depth <= 1 { return true }
        }
        return false
    }

    // MARK: One run

    public static func playRun(
        seed: UInt64,
        siteID: String,
        tier: Int,
        policy: PlayerPolicy = .average,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard,
        extraModifiers: ModifierSet = ModifierSet()
    ) -> RunState {
        // A fixed start date, not Date(). A simulated run has no business carrying a
        // wall clock: it makes two sweeps of the same seed differ, which defeats the
        // point of a reproducible balance tool.
        var run = RunState(
            seed: seed, siteID: siteID, tier: tier,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        guard let site = catalog.site(siteID) else { return run }
        while !run.isOver {
            switch run.phase {
            case .digging(let day):
                run.completeSlab(playSlab(
                    seed: run.slabSeed(forDay: day),
                    day: day,
                    site: site,
                    policy: policy,
                    catalog: catalog,
                    tuning: tuning,
                    extraModifiers: extraModifiers
                ))
            case .results:
                run.advance()
            case .succeeded, .failed:
                break
            }
        }
        return run
    }

    // MARK: The sweep

    /// Runs `runsPerTier` runs at each tier and reports the win rate.
    ///
    /// Parallel across runs because a serious sweep is ninety million brush
    /// applications and the runs are completely independent.
    public static func sweep(
        tiers: ClosedRange<Int> = 1...5,
        runsPerTier: Int = 2_000,
        siteID: String = "charmouth",
        policy: PlayerPolicy = .average,
        seed: UInt64 = 0x600D_5EED,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) -> [TierReport] {
        tiers.map { tier in
            let lock = NSLock()
            var wins = 0
            var earned = 0
            var exposure = 0.0
            var intact = 0.0
            var slabTotal = 0
            var slabCount = 0

            DispatchQueue.concurrentPerform(iterations: runsPerTier) { index in
                let runSeed = seed
                    ^ (UInt64(tier) &* 0x9E37_79B9_7F4A_7C15)
                    ^ (UInt64(index) &* 0xBF58_476D_1CE4_E5B9)
                let run = playRun(
                    seed: runSeed, siteID: siteID, tier: tier,
                    policy: policy, catalog: catalog, tuning: tuning
                )
                var won = false
                if case .succeeded = run.phase { won = true }
                let localExposure = run.slabs.reduce(0.0) { $0 + Double($1.payout.exposure) }
                let localIntact = run.slabs.reduce(0.0) { $0 + Double($1.payout.intact) }
                let localTotal = run.slabs.reduce(0) { $0 + $1.payout.total }

                lock.lock()
                if won { wins += 1 }
                earned += run.totalEarned
                exposure += localExposure
                intact += localIntact
                slabTotal += localTotal
                slabCount += run.slabs.count
                lock.unlock()
            }

            return TierReport(
                tier: tier,
                installment: Installments.amount(tier: tier),
                runs: runsPerTier,
                wins: wins,
                meanEarned: Double(earned) / Double(runsPerTier),
                meanExposure: slabCount == 0 ? 0 : exposure / Double(slabCount),
                meanIntact: slabCount == 0 ? 0 : intact / Double(slabCount),
                meanSlabPayout: slabCount == 0 ? 0 : Double(slabTotal) / Double(slabCount)
            )
        }
    }
}

/// A boustrophedon sweep over a rectangle, parametrised by distance travelled.
///
/// Parametrising by arc length rather than stepping a cursor matters: stepping would
/// make the move to the next pass a single jump of a whole row, which the speed EMA
/// reads as a flick and which would crack bone that a real player never touched
/// quickly. Here a turn costs the same distance as any other movement.
struct SerpentinePath {
    let x0: Float
    let x1: Float
    let y0: Float
    let y1: Float
    let rowStep: Float

    private var rowWidth: Float { max(0.001, x1 - x0) }
    private var rowCount: Int { max(1, Int((y1 - y0) / rowStep) + 1) }
    /// One full top-to-bottom sweep, including the drops between passes.
    private var cycleLength: Float {
        Float(rowCount) * rowWidth + Float(rowCount - 1) * rowStep
    }

    func point(at distance: Float) -> Vec2 {
        var remaining = distance.truncatingRemainder(dividingBy: cycleLength)
        if remaining < 0 { remaining += cycleLength }

        var row = 0
        while row < rowCount {
            if remaining <= rowWidth {
                let y = y0 + Float(row) * rowStep
                let x = row % 2 == 0 ? x0 + remaining : x1 - remaining
                return Vec2(x, min(y, y1))
            }
            remaining -= rowWidth
            if row == rowCount - 1 { break }
            if remaining <= rowStep {
                // On the drop between two passes.
                let y = y0 + Float(row) * rowStep + remaining
                let x = row % 2 == 0 ? x1 : x0
                return Vec2(x, min(y, y1))
            }
            remaining -= rowStep
            row += 1
        }
        let y = min(y0 + Float(rowCount - 1) * rowStep, y1)
        return Vec2((rowCount - 1) % 2 == 0 ? x1 : x0, y)
    }
}
