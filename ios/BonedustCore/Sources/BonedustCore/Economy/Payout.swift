import Foundation

/// Everything the payout formula needs, and nothing else.
public struct PayoutContext: Sendable, Equatable {
    public var baseValue: Int
    /// `exposedBoneCells / boneCells`.
    public var exposure: Float
    public var boneCells: Int
    public var crackedCells: Int
    /// Gem clusters with all four cells exposed.
    public var wholeGems: Int
    /// Rock nodules fully cleared, for the "Rock hound" charm.
    public var clearedNodules: Int
    /// Daylight left when the slab was bagged.
    public var daylightRemaining: Float
    public var modifiers: ModifierSet
    public var tuning: SimTuning

    public init(
        baseValue: Int,
        exposure: Float,
        boneCells: Int,
        crackedCells: Int,
        wholeGems: Int,
        clearedNodules: Int = 0,
        daylightRemaining: Float = 0,
        modifiers: ModifierSet = ModifierSet(),
        tuning: SimTuning = .standard
    ) {
        self.baseValue = baseValue
        self.exposure = exposure
        self.boneCells = boneCells
        self.crackedCells = crackedCells
        self.wholeGems = wholeGems
        self.clearedNodules = clearedNodules
        self.daylightRemaining = daylightRemaining
        self.modifiers = modifiers
        self.tuning = tuning
    }
}

/// What the results screen prints, line for line.
public struct PayoutBreakdown: Sendable, Equatable {
    public var exposure: Float
    public var intact: Float
    public var fossil: Int
    public var gems: Int
    /// Rock hound and other flat money, after multipliers.
    public var bonuses: Int
    /// The multiplier that was actually applied, for the "x1.5 night dig" line.
    public var multiplier: Float
    public var rushApplied: Bool
    public var total: Int

    public init(
        exposure: Float, intact: Float, fossil: Int, gems: Int,
        bonuses: Int, multiplier: Float, rushApplied: Bool, total: Int
    ) {
        self.exposure = exposure
        self.intact = intact
        self.fossil = fossil
        self.gems = gems
        self.bonuses = bonuses
        self.multiplier = multiplier
        self.rushApplied = rushApplied
        self.total = total
    }
}

public enum Payout {

    /// `intact = max(0, 1 - (cracked / bone) * 3)`, with the "Authentic damage"
    /// credit discounting each cracked cell before the ratio is taken.
    public static func intact(
        crackedCells: Int, boneCells: Int, modifiers: ModifierSet, tuning: SimTuning = .standard
    ) -> Float {
        guard boneCells > 0 else { return 1 }
        let effective = Float(crackedCells) * (1 - modifiers.crackedIntactCredit)
        return max(0, 1 - effective / Float(boneCells) * tuning.intactCrackWeight)
    }

    /// `fossilPay = round(base * exposure^1.5 * intact)`, plus gems, then every
    /// multiplier, then flat bonuses. One order, applied the same way every time.
    public static func evaluate(_ context: PayoutContext) -> PayoutBreakdown {
        let tuning = context.tuning
        let mods = context.modifiers
        let exposure = min(max(context.exposure, 0), 1)
        let intact = intact(
            crackedCells: context.crackedCells,
            boneCells: context.boneCells,
            modifiers: mods,
            tuning: tuning
        )

        let fossilRaw = Float(context.baseValue)
            * pow(exposure, tuning.exposureExponent)
            * intact
        let fossilPay = Int(fossilRaw.rounded())

        let gemPay = Int(
            (Float(context.wholeGems * tuning.gemValue) * mods.gemMultiplier).rounded()
        )

        let rushApplied = context.daylightRemaining >= mods.rushThreshold
            && mods.rushMultiplier != 1
        var multiplier = mods.payoutMultiplier
        if rushApplied { multiplier *= mods.rushMultiplier }

        let scaled = Int((Float(fossilPay + gemPay) * multiplier).rounded())
        let bonuses = context.clearedNodules * mods.rockNodulePayout + mods.flatBonus

        return PayoutBreakdown(
            exposure: exposure,
            intact: intact,
            fossil: fossilPay,
            gems: gemPay,
            bonuses: bonuses,
            multiplier: multiplier,
            rushApplied: rushApplied,
            total: max(0, scaled + bonuses)
        )
    }

    /// The most a slab could possibly pay: perfect exposure, nothing cracked, every
    /// gem whole, bagged early enough for any rush bonus.
    ///
    /// This is the server's anti-cheat ceiling from §6. It is deliberately generous
    /// — it assumes a flawless dig — so a legitimate player can never trip it, and a
    /// client claiming more than this is lying about something.
    public static func maxPayout(
        baseValue: Int,
        gemCount: Int,
        clearedNodules: Int = 0,
        modifiers: ModifierSet = ModifierSet(),
        tuning: SimTuning = .standard
    ) -> Int {
        var mods = modifiers
        // Assume the rush bonus landed.
        mods.rushThreshold = 0
        let context = PayoutContext(
            baseValue: baseValue,
            exposure: 1,
            boneCells: max(1, 1),
            crackedCells: 0,
            wholeGems: gemCount,
            clearedNodules: clearedNodules,
            daylightRemaining: tuning.daylightSeconds + max(0, modifiers.daylightDelta),
            modifiers: mods,
            tuning: tuning
        )
        return evaluate(context).total
    }
}
