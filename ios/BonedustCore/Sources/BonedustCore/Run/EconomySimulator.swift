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
    /// Fraction of projected surplus cash the player is willing to spend in the tent.
    ///
    /// Zero models the M2 baseline, which is why the tier curve was flat: nothing made
    /// the player stronger. One models someone who spends everything they do not
    /// strictly need, which is how the game is meant to be played.
    public var spendingAggression: Float
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
        lookaheadSamples: Float = 3,
        spendingAggression: Float = 0.8
    ) {
        self.clearingSpeed = clearingSpeed
        self.cautionFactor = cautionFactor
        self.samplesPerSecond = samplesPerSecond
        self.bagAtExposure = bagAtExposure
        self.toolID = toolID
        self.passOverlap = passOverlap
        self.lookaheadSamples = lookaheadSamples
        self.spendingAggression = spendingAggression
    }

    /// The reference player the balance target is stated against: moderately quick,
    /// slows down when they see bone, uses the starting brush.
    public static let average = PlayerPolicy()

    /// Someone who has not learned to read the tell: fast, reacting only to bone
    /// already under the brush, and buying on impulse.
    public static let reckless = PlayerPolicy(
        clearingSpeed: 5.5, cautionFactor: 1.6, bagAtExposure: 0.9,
        lookaheadSamples: 0, spendingAggression: 1.0
    )

    /// Someone who has, and who looks well ahead.
    public static let careful = PlayerPolicy(
        clearingSpeed: 2.2, cautionFactor: 0.6, lookaheadSamples: 6,
        spendingAggression: 0.6
    )

    /// The M2 baseline: never visits the tent. Kept so the effect of the shop can be
    /// measured rather than asserted.
    public static let thrifty = PlayerPolicy(spendingAggression: 0)
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
        loadout: Loadout = Loadout(),
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard,
        extraModifiers: ModifierSet = ModifierSet()
    ) -> SlabRecord {
        // playSlab folds the loadout's own modifiers in. Taking a loadout for its
        // brushes but ignoring its ModifierSet made every passive tool silently inert —
        // a headlamp produced bit-identical results to no headlamp at all, which looked
        // like a balance finding and was a plumbing bug.
        var modifiers = ModifierSet.combining([
            site.modifiers.modifierSet,
            loadout.modifiers(context: CharmContext(day: day, siteID: site.id)),
            extraModifiers,
        ])
        let generated = SlabGenerator.generate(
            seed: seed, site: site, catalog: catalog, tuning: tuning
        )
        let fossil = catalog.fossil(generated.layout.fossilID) ?? catalog.fossils[0]
        modifiers.crackMultiplier *= fossil.crackMultiplier

        var sim = SlabSimulation(grid: generated.grid, layout: generated.layout, tuning: tuning)
        sim.crackMultiplier = modifiers.crackMultiplier
        // The site's share alone, which scales the baseline fragility. Easy to miss: this
        // path builds the simulation from a grid and sets the multipliers by hand rather
        // than going through the `seed:site:` initialiser that derives them, so a new one
        // added there is silently left at its default here.
        sim.siteCrackMultiplier = site.modifiers.crackMultiplier
        sim.safeSpeedMultiplier = modifiers.safeSpeedMultiplier
        sim.rockHardnessMultiplier = modifiers.rockHardnessMultiplier

        let daylight = max(5, tuning.daylightSeconds + modifiers.daylightDelta)
        let deltaMillis = 1_000 / policy.samplesPerSecond
        let maxSamples = Int(daylight * policy.samplesPerSecond)

        // Two phases, because that is how the slab is actually dug and because a
        // one-brush-per-slab model made buying tools look *harmful*: a fine brush
        // covers a quarter of the area per pass, so using it for the whole sweep
        // collapsed coverage, and a blower used near bone destroyed everything.
        //
        //   1. Survey — the widest brush, full speed, pass spacing from its diameter,
        //      sweeping the entire slab until the fossil has been found.
        //   2. Excavate — the gentlest brush, safe speed, tight passes over the bone's
        //      own bounding box.
        //
        // That is what makes the tool slots worth anything: the blower earns its keep
        // in phase one and would ruin the specimen in phase two.
        let available = loadout.tools.isEmpty
            ? [BrushTool.all.first { $0.id == policy.toolID } ?? .brush]
            : loadout.brushes
        let surveyBrush = available.max { $0.radius < $1.radius } ?? .brush
        let digBrush = available.min { $0.crackMultiplier < $1.crackMultiplier } ?? .brush

        let surveyPath = SerpentinePath(
            x0: 2, x1: Float(SlabGrid.width) - 2,
            y0: 2, y1: Float(SlabGrid.height) - 2,
            rowStep: max(1.5, surveyBrush.radius * 2 * policy.passOverlap)
        )
        let bounds = boneBounds(generated.grid, pad: digBrush.radius + 2)
        let digPath = SerpentinePath(
            x0: bounds.x0, x1: bounds.x1, y0: bounds.y0, y1: bounds.y1,
            rowStep: max(1.2, digBrush.radius * 2 * policy.passOverlap)
        )

        let framesPerSample = deltaMillis / tuning.referenceFrameMillis
        let clearingTravel = policy.clearingSpeed * framesPerSample
        let surveyLength = surveyPath.cycleLength

        var arcLength: Float = 0
        var samples = 0
        var excavating = false
        // Where bone has actually been *seen*. Using this rather than the real bone
        // mask keeps the model honest: it may only avoid damaging what it has already
        // uncovered, which is the information a player has too.
        var found: (x0: Float, x1: Float, y0: Float, y1: Float)?
        sim.beginStroke(at: surveyPath.point(at: 0), tool: surveyBrush)

        while samples < maxSamples {
            // One full sweep of the slab and the fossil has been found; switch to
            // working it. Switching on coverage rather than on exposure means the
            // player has actually looked before claiming to know where it is.
            if !excavating, arcLength >= surveyLength {
                excavating = true
                arcLength = 0
            }
            let path = excavating ? digPath : surveyPath
            let point = path.point(at: arcLength)

            // The gentle brush whenever bone is near, in either phase. At depth 3 bone
            // is invisible, so the depth-1 tell alone is not enough: a blower clears
            // three layers before the tell ever shows, which is exactly how it used to
            // shatter fossils it had never seen. Remembering where bone turned up fixes
            // that without letting the model peek at the mask.
            let reach = surveyBrush.radius + 1
            let lookahead = clearingTravel * policy.lookaheadSamples
            let boneNear = boneVisible(in: sim.grid, around: point, reach: reach)
                || (lookahead > 0 && boneVisible(
                    in: sim.grid, around: path.point(at: arcLength + lookahead), reach: reach
                ))
                || inside(found, point, margin: surveyBrush.radius + 2)

            let brush = boneNear ? digBrush : surveyBrush
            let safe = sim.safeSpeed(for: brush) * policy.cautionFactor * framesPerSample
            let requested = boneNear ? min(safe, clearingTravel) : clearingTravel
            arcLength += requested
            let next = path.point(at: arcLength)

            // Lift the finger rather than dragging it when the path jumps: a sweep that
            // wraps back to the top, or a switch from surveying to excavating, moves the
            // brush right across the slab. Treating that as one continuous stroke carved
            // a line through the slab *and* spiked the speed EMA, cracking bone that was
            // never brushed quickly. A hand lifts and comes back down.
            let result: StrokeResult
            // Scaled to the step actually asked for, not a constant: a fixed threshold
            // smaller than the normal per-sample travel turns every stroke into a dab.
            if (next - point).length > requested * 2.5 + 2 {
                sim.endStroke()
                result = sim.beginStroke(at: next, tool: brush)
            } else {
                result = sim.moveStroke(to: next, deltaMillis: deltaMillis, tool: brush)
            }
            if result.boneRevealed > 0 { extend(&found, with: point) }
            samples += 1
            if sim.exposure >= policy.bagAtExposure { break }
        }
        sim.endStroke()

        let elapsedSeconds = Float(samples) / policy.samplesPerSecond
        let daylightLeft = max(0, daylight - elapsedSeconds)
        let payout = Payout.evaluate(PayoutContext(
            baseValue: fossil.baseValue,
            instances: generated.layout.instances,
            exposure: sim.exposure,
            boneCells: sim.boneCells,
            crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems,
            clearedNodules: 0,
            daylightRemaining: daylightLeft,
            totalDaylight: daylight,
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

    private static func inside(
        _ box: (x0: Float, x1: Float, y0: Float, y1: Float)?, _ point: Vec2, margin: Float
    ) -> Bool {
        guard let box else { return false }
        return point.x >= box.x0 - margin && point.x <= box.x1 + margin
            && point.y >= box.y0 - margin && point.y <= box.y1 + margin
    }

    private static func extend(
        _ box: inout (x0: Float, x1: Float, y0: Float, y1: Float)?, with point: Vec2
    ) {
        guard var existing = box else {
            box = (point.x, point.x, point.y, point.y)
            return
        }
        existing.x0 = min(existing.x0, point.x)
        existing.x1 = max(existing.x1, point.x)
        existing.y0 = min(existing.y0, point.y)
        existing.y1 = max(existing.y1, point.y)
        box = existing
    }

    /// Does the player have a reason to slow down here?
    ///
    /// A nine-point probe rather than the whole brush footprint: this runs on every one
    /// of ninety million samples in a full sweep, and the answer barely changes. `reach`
    /// must be at least the brush's own radius, or the brush damages bone the probe
    /// never looked at.
    private static func boneVisible(
        in grid: SlabGrid, around point: Vec2, reach: Float
    ) -> Bool {
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
        extraModifiers: ModifierSet = ModifierSet(),
        toolIDs: [String] = [BrushTool.brush.id],
        charmIDs: [String] = []
    ) -> RunState {
        // A fixed start date, not Date(). A simulated run has no business carrying a
        // wall clock: it makes two sweeps of the same seed differ, which defeats the
        // point of a reproducible balance tool.
        var run = RunState(
            seed: seed, siteID: siteID, tier: tier,
            toolIDs: toolIDs, charmIDs: charmIDs,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        guard let site = catalog.site(siteID) else { return run }
        while !run.isOver {
            switch run.phase {
            case .digging(let day):
                // The site can be overridden for this day by a charm, and the loadout's
                // modifiers depend on the day, so both are resolved per slab.
                let slabSiteID = run.siteForSlab(onDay: day, catalog: catalog)
                let slabSite = catalog.site(slabSiteID) ?? site
                run.completeSlab(playSlab(
                    seed: run.slabSeed(forDay: day),
                    day: day,
                    site: slabSite,
                    policy: policy,
                    loadout: run.loadout(catalog: catalog),
                    catalog: catalog,
                    tuning: tuning,
                    // Only the outside extras: playSlab resolves the loadout itself, and
                    // passing it here as well would apply every charm twice.
                    extraModifiers: extraModifiers
                ))
            case .results:
                run.advance()
            case .supplyTent:
                shop(&run, policy: policy, catalog: catalog)
                run.leaveShop()
            case .succeeded, .failed:
                break
            }
        }
        return run
    }

    /// The scripted shopping trip.
    ///
    /// The model is "spend what I will not need": project the rest of the run from what
    /// slabs have paid so far, and treat anything above the installment as spendable.
    /// It is deliberately not optimal — a player cannot see the future either — but it
    /// does capture the real decision, which is how much of a cushion to give up.
    private static func shop(
        _ run: inout RunState, policy: PlayerPolicy, catalog: ContentCatalog
    ) {
        guard policy.spendingAggression > 0, case .supplyTent(let day) = run.phase else { return }
        run.openShop(reputation: 0, catalog: catalog)

        let perSlab = run.slabs.isEmpty ? 0 : run.totalEarned / run.slabs.count
        let expected = perSlab * max(0, run.totalDays - day)
        // Spend only what will still leave the installment covered, keeping a cushion
        // against a bad slab. Without the cushion the model earned $450 against $350
        // owed and still failed, because it bought itself below the line and the
        // remaining slabs had to be average or better just to recover.
        let reserve = Int(Float(run.installment) * 0.15)
        let spendable = run.cash + expected - run.installment - reserve
        var budget = min(run.cash, Int(Float(max(0, spendable)) * policy.spendingAggression))

        // Cheapest first, so a visit buys two useful things rather than one expensive
        // one. Tools before charms: a brush that stops the cracking is worth more than
        // a multiplier on a ruined fossil.
        let offeredTools = run.shop.toolIDs
            .compactMap { catalog.tool($0) }
            .sorted { $0.price < $1.price }
        for tool in offeredTools where run.hasToolSlot && tool.price <= budget {
            if (try? run.buyTool(tool.id, catalog: catalog)) != nil { budget -= tool.price }
        }
        let offeredCharms = run.shop.charmIDs
            .compactMap { catalog.charm($0) }
            .sorted { $0.price < $1.price }
        for charm in offeredCharms where run.hasCharmSlot && charm.price <= budget {
            if (try? run.buyCharm(charm.id, catalog: catalog)) != nil { budget -= charm.price }
        }
    }

    // MARK: The sweep

    /// Plays whole careers: tier 1 until a failure, carrying the kit forward.
    ///
    /// This replaces sweeping each tier independently, which measured something that
    /// cannot happen — a tier 5 run attempted with nothing but the starting brush. A
    /// player arrives at tier 5 having bought four runs' worth of kit, and the win rate
    /// per tier only means anything if the simulation arrives the same way.
    public static func careers(
        count: Int = 2_000,
        maxTier: Int = 8,
        siteID: String = "charmouth",
        policy: PlayerPolicy = .average,
        seed: UInt64 = 0x600D_5EED,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) -> [TierReport] {
        let tally = TierTally(tiers: maxTier)

        DispatchQueue.concurrentPerform(iterations: count) { career in
            var meta = MetaProgress()
            while meta.nextTier <= maxTier {
                let tier = meta.nextTier
                // A player digs the best site they have earned, not the first one. Held
                // fixed, the sweep measured a career that never progresses, which made the
                // installment ramp look unwinnable when it is the map that is meant to
                // keep up with it.
                let site = richestUnlockedSite(
                    reputation: meta.reputation, fallback: siteID, catalog: catalog
                )
                let runSeed = seed
                    ^ (UInt64(career) &* 0xBF58_476D_1CE4_E5B9)
                    ^ (UInt64(meta.runsCompleted + meta.runsFailed) &* 0x9E37_79B9_7F4A_7C15)
                let run = playRun(
                    seed: runSeed, siteID: site, tier: tier, policy: policy,
                    catalog: catalog, tuning: tuning,
                    toolIDs: meta.carriedToolIDs, charmIDs: meta.carriedCharmIDs
                )
                tally.record(tier: tier, run: run)
                meta.absorb(run)
                if case .succeeded = run.phase { continue }
                break
            }
        }

        return tally.reports(tiers: 1...maxTier)
    }

    /// Highest-paying site the given Reputation has unlocked.
    ///
    /// Ranked by base value per slab rather than by a hand-written order, so adding a
    /// site to content does not need this updated. Crew-milestone sites are excluded:
    /// they depend on the shared ledger, which a single career cannot move.
    static func richestUnlockedSite(
        reputation: Int, fallback: String, catalog: ContentCatalog
    ) -> String {
        let eligible = catalog.sites.filter { site in
            switch site.unlock {
            case .start: return true
            case .reputation(let needed): return reputation >= needed
            case .crewMilestone: return false
            }
        }
        func worth(_ site: Site) -> Double {
            let fossils = catalog.fossils(forSite: site.id)
            guard !fossils.isEmpty else { return 0 }
            let mean = fossils.reduce(0.0) { sum, fossil in
                let instances = Double(fossil.instancesMin + fossil.instancesMax) / 2
                    + Double(site.modifiers.extraInstances)
                return sum + Double(fossil.baseValue) * instances
            } / Double(fossils.count)
            return mean * Double(site.modifiers.payoutMultiplier)
        }
        return eligible.max { worth($0) < worth($1) }?.id ?? fallback
    }

    /// Runs `runsPerTier` independent runs at each tier and reports the win rate.
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
        let tally = TierTally(tiers: tiers.upperBound)

        for tier in tiers {
            DispatchQueue.concurrentPerform(iterations: runsPerTier) { index in
                let runSeed = seed
                    ^ (UInt64(tier) &* 0x9E37_79B9_7F4A_7C15)
                    ^ (UInt64(index) &* 0xBF58_476D_1CE4_E5B9)
                let run = playRun(
                    seed: runSeed, siteID: siteID, tier: tier,
                    policy: policy, catalog: catalog, tuning: tuning
                )
                tally.record(tier: tier, run: run)
            }
        }

        return tally.reports(tiers: tiers)
    }
}

/// Accumulates sweep results across threads.
///
/// A type that owns its lock, rather than a handful of `var`s captured by a concurrent
/// closure. The previous version was correct — every mutation sat between `lock.lock()` and
/// `lock.unlock()` — but the compiler could not see that, and Swift 6.2 says so. "Correct
/// but unprovable" is how a later edit adds a mutation outside the lock and nothing
/// notices. Here the state is private and the only way to touch it is a method that takes
/// the lock first, so the invariant is structural instead of remembered.
private final class TierTally: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [Int]
    private var wins: [Int]
    private var earned: [Int]
    private var exposure: [Double]
    private var intact: [Double]
    private var slabTotal: [Int]
    private var slabCount: [Int]

    init(tiers: Int) {
        let size = max(1, tiers + 1)
        runs = Array(repeating: 0, count: size)
        wins = Array(repeating: 0, count: size)
        earned = Array(repeating: 0, count: size)
        exposure = Array(repeating: 0, count: size)
        intact = Array(repeating: 0, count: size)
        slabTotal = Array(repeating: 0, count: size)
        slabCount = Array(repeating: 0, count: size)
    }

    /// Folds one finished run in.
    func record(tier: Int, run: RunState) {
        guard runs.indices.contains(tier) else { return }
        var won = false
        if case .succeeded = run.phase { won = true }
        let runExposure = run.slabs.reduce(0.0) { $0 + Double($1.payout.exposure) }
        let runIntact = run.slabs.reduce(0.0) { $0 + Double($1.payout.intact) }
        let runSlabTotal = run.slabs.reduce(0) { $0 + $1.payout.total }

        lock.withLock {
            runs[tier] += 1
            if won { wins[tier] += 1 }
            earned[tier] += run.totalEarned
            exposure[tier] += runExposure
            intact[tier] += runIntact
            slabTotal[tier] += runSlabTotal
            slabCount[tier] += run.slabs.count
        }
    }

    func reports(tiers: ClosedRange<Int>) -> [TierReport] {
        lock.withLock {
            tiers.compactMap { tier in
                guard runs.indices.contains(tier), runs[tier] > 0 else { return nil }
                return TierReport(
                    tier: tier,
                    installment: Installments.amount(tier: tier),
                    runs: runs[tier],
                    wins: wins[tier],
                    meanEarned: Double(earned[tier]) / Double(runs[tier]),
                    meanExposure: slabCount[tier] == 0 ? 0
                        : exposure[tier] / Double(slabCount[tier]),
                    meanIntact: slabCount[tier] == 0 ? 0
                        : intact[tier] / Double(slabCount[tier]),
                    meanSlabPayout: slabCount[tier] == 0 ? 0
                        : Double(slabTotal[tier]) / Double(slabCount[tier])
                )
            }
        }
    }
}

/// The rectangle the fossil occupies, padded so the brush can work its edges.
func boneBounds(
    _ grid: SlabGrid, pad: Float
) -> (x0: Float, x1: Float, y0: Float, y1: Float) {
    var minX = SlabGrid.width, maxX = 0, minY = SlabGrid.height, maxY = 0
    for y in 0..<SlabGrid.height {
        for x in 0..<SlabGrid.width where grid.isBone(SlabGrid.index(x, y)) {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard minX <= maxX, minY <= maxY else {
        return (2, Float(SlabGrid.width) - 2, 2, Float(SlabGrid.height) - 2)
    }
    return (
        max(1, Float(minX) - pad),
        min(Float(SlabGrid.width) - 2, Float(maxX) + pad),
        max(1, Float(minY) - pad),
        min(Float(SlabGrid.height) - 2, Float(maxY) + pad)
    )
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
    var cycleLength: Float {
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
