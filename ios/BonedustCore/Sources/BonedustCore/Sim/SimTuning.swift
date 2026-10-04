/// Every magic number in the simulation, in one place.
///
/// This exists as a value type rather than a pile of `static let`s for two
/// reasons: the M1 debug overlay needs to bind sliders to each constant live, and
/// the server needs the same numbers (§6), which `bonedust-tool dump-constants`
/// writes out as JSON from `SimTuning.standard`.
public struct SimTuning: Sendable, Codable, Equatable {

    // MARK: Removal

    /// Scales `wear` gained per cell per unit of brush travel.
    /// Was 0.24, which made the game unwinnable by hand.
    ///
    /// Measured, not guessed: a flawless serpentine at exactly the brush's safe speed, for
    /// the whole sixty seconds, reached **0.538** exposure. Payout scales as
    /// `exposure^1.5`, so that is 39% of a slab's value — about $43 a day against a $350
    /// first installment. No amount of skill closed that gap, because the limit was the
    /// clock and not the player.
    ///
    /// `EconomySimulator` never saw it. Its model sweeps non-bone ground at
    /// `clearingSpeed: 3.2`, more than twice the brush's safe speed of 1.4, which is legal
    /// — cracking only applies to bone that is already exposed — and reaches 0.948. The
    /// balance targets were being met by a player that ignores the speed meter, while
    /// anyone who trusts it got nothing. See `HumanCeilingTests`.
    ///
    /// 0.48 puts a careful safe-speed sweep at 0.92, just under the model's 0.948, which is
    /// the right order: a methodical human should land a little below a machine, not at
    /// zero.
    public var removalRate: Float = 0.48
    /// Indexed by `depth`. Slot 0 is unused (depth 0 is already exposed).
    public var layerHardness: [Float] = [1.0, 1.0, 1.35, 1.7]
    public var rockHardnessMultiplier: Float = 3.2
    /// A touch-move of length `d` is split into `ceil(d / (radius * stepFactor))`
    /// brush applications so that a fast flick does not tunnel through the slab.
    public var stepFactor: Float = 0.35

    // MARK: Speed

    /// Weight of the newest sample in the speed EMA: `ema = ema*(1-a) + v*a`.
    public var emaAlpha: Float = 0.25
    /// Per-frame multiplier applied to the EMA while no finger is down.
    public var emaIdleDecay: Float = 0.85
    /// Speed is expressed in cells per this many milliseconds, i.e. per 60 Hz frame.
    public var referenceFrameMillis: Float = 16.666_667
    /// Upper bound on a single sample, so a dropped frame cannot spike the EMA
    /// into a crack storm. Generous: 40 cells/frame is faster than a real swipe.
    public var maxSampleSpeed: Float = 40

    // MARK: Cracking

    public var crackRate: Float = 0.0011
    /// How fragile exposed bone is even when brushed perfectly carefully.
    ///
    /// Added to whatever the brush is over the safe speed by, so cracking is possible at
    /// any speed while going fast still makes it far likelier.
    ///
    /// Zero for six milestones, which quietly killed half the shop. Cracking keyed only on
    /// `speed - safeSpeed`, so a player who obeyed the speed meter never cracked anything,
    /// so every anti-crack tool and charm defended against something that was not
    /// happening -- the fine brush bought `crackMultiplier: 0.35` with 57% of the brush's
    /// radius and earned a seventh as much, and the air blower's 2.6 never bit at all.
    ///
    /// It also makes 100% intact an achievement rather than the default, which is what the
    /// grade and "Not a mark on it" were both written as though it already was.
    public var baselineFragility: Float = 0.30
    public var crackWalkMin: Int = 3
    public var crackWalkMax: Int = 8

    // MARK: Payout

    public var exposureExponent: Float = 1.5
    /// Each cracked cell costs this many cells' worth of `intact`.
    ///
    /// Raised from the prototype's 3.0 after the M3 economy sweep. At 3.0 the payout
    /// formula made care worthless: exposure is raised to 1.5 while intact stays
    /// linear, so "clear fast and accept cracks" beat "go slow and stay whole" at every
    /// site, and no brush was worth buying. At 5.0 a fifth of the fossil cracked makes
    /// it worthless, the fine brush pays for itself, and §4's second pillar is a real
    /// decision rather than a described one. See DECISIONS.md.
    public var intactCrackWeight: Float = 5.0
    public var gemValue: Int = 20
    /// Exposure at which the specimen stops reading "Unidentified".
    public var identifyExposure: Float = 0.25

    // MARK: Daylight

    public var daylightSeconds: Float = 60

    // MARK: Generation

    public var rockNodulesMin: Int = 2
    public var rockNodulesMax: Int = 4
    public var rockRadiusMin: Float = 4
    public var rockRadiusMax: Float = 10
    public var gemsMin: Int = 1
    public var gemsMax: Int = 4
    /// Fossil placement jitter, from §3.
    public var fossilRotation: Float = 0.7
    public var fossilScaleMin: Float = 0.95
    public var fossilScaleMax: Float = 1.15
    public var fossilOffsetX: Int = 7
    public var fossilOffsetY: Int = 13
    // MARK: Grade

    /// Weights for the finished-slab grade. They sum to 1.
    ///
    /// Care outweighs speed on purpose: a grade that paid mostly for finishing early would
    /// argue against the thing the game is about. The clock still carries 20% because it is
    /// the only term that moves -- a competent dig lands near 0.97 exposure and 0.99 intact
    /// whatever else happened, so those two cannot separate good play from great.
    public var gradeExposureWeight: Float = 0.4
    public var gradeIntactWeight: Float = 0.4
    public var gradeSpeedWeight: Float = 0.2

    public var gradeThresholdS: Float = 0.95
    public var gradeThresholdA: Float = 0.85
    public var gradeThresholdB: Float = 0.70
    public var gradeThresholdC: Float = 0.50

    /// What each grade multiplies fossil and gem money by, as a rate above 1.
    ///
    /// Small, and small on purpose. These compound: a bonus that makes money easier pays
    /// the debt faster, which reaches the next reward sooner. B is the ordinary case, so
    /// its 5% is close to being the baseline -- the real reward is the 25% at S, which
    /// needs a slab cleared, unbroken, and finished with daylight to spare.
    public var gradeBonusS: Float = 0.25
    public var gradeBonusA: Float = 0.12
    public var gradeBonusB: Float = 0.05

    // MARK: Breath

    /// Patches a full-strength breath lifts, scattered over the whole slab.
    public var gustPatchesAtFullStrength: Int = 16
    /// Radius of one patch, in cells.
    public var gustRadius: Float = 7
    /// The depth a gust will not take a cell below.
    ///
    /// 1, not 0. Breath moves loose overburden; it never uncovers the fossil for you, so
    /// the last layer is always brushed by hand and the verb the game is about stays the
    /// verb the game is about.
    public var gustFloorDepth: UInt8 = 1
    /// Chance per exposed bone cell inside a patch that a full-strength gust cracks it.
    ///
    /// Breath is indiscriminate. Blowing across a slab you have already opened up is how
    /// you wreck a specimen, which is what stops this being a free win and makes *when* to
    /// use it the whole decision.
    public var gustCrackRate: Float = 0.5
    /// Seconds before another gust can land.
    public var gustCooldownSeconds: Float = 2.5

    /// Side of a gem cluster, in cells.
    ///
    /// Was 2. At 96x128 scaled to a phone a 2x2 gem is four pixels, which is smaller than
    /// the matrix noise around it -- not a thing you spot and decide to go carefully around,
    /// which is the whole point of a gem. 3x3 reads as an object.
    ///
    /// It is also its own counterweight: a gem only pays when every one of its cells is
    /// cleared, so 9 cells is more than twice the daylight of 4. More gems, bigger, each
    /// harder to actually free.
    public var gemSize: Int = 3
    /// Tries to find a clear cluster before giving up on a gem.
    public var gemPlacementAttempts: Int = 24

    // MARK: Presentation (read by the renderer, kept here so sliders reach it)

    /// How far a worn cell lerps toward the next layer down, at `wear == 1`.
    public var wearColorBlend: Float = 0.55
    /// Tint of depth-1 sandstone toward bone when bone sits underneath — the tell.
    public var boneTellTint: Float = 0.20
    /// Per-cell brightness jitter, ±this fraction.
    public var cellNoise: Float = 0.07

    public init() {}

    public static let standard = SimTuning()
}
