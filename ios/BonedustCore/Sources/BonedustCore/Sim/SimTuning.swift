/// Every magic number in the simulation, in one place.
///
/// This exists as a value type rather than a pile of `static let`s for two
/// reasons: the M1 debug overlay needs to bind sliders to each constant live, and
/// the server needs the same numbers (§6), which `bonedust-tool dump-constants`
/// writes out as JSON from `SimTuning.standard`.
public struct SimTuning: Sendable, Codable, Equatable {

    // MARK: Removal

    /// Scales `wear` gained per cell per unit of brush travel.
    public var removalRate: Float = 0.24
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
    public var crackWalkMin: Int = 3
    public var crackWalkMax: Int = 8

    // MARK: Payout

    public var exposureExponent: Float = 1.5
    /// Each cracked cell costs this many cells' worth of `intact`.
    public var intactCrackWeight: Float = 3.0
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
    public var gemsMin: Int = 0
    public var gemsMax: Int = 2
    /// Fossil placement jitter, from §3.
    public var fossilRotation: Float = 0.7
    public var fossilScaleMin: Float = 0.95
    public var fossilScaleMax: Float = 1.15
    public var fossilOffsetX: Int = 7
    public var fossilOffsetY: Int = 13
    /// Tries to find a clear 2x2 before giving up on a gem.
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
