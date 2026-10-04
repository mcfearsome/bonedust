import Foundation

/// Everything the payout formula needs, and nothing else.
public struct PayoutContext: Sendable, Equatable {
    public var baseValue: Int
    /// How many copies of the fossil are on the slab.
    ///
    /// This multiplies the base value, and it has to: `exposure` is measured over the
    /// union of every instance, so three brachiopods mean three times the bone to clear
    /// in the same sixty seconds. Paying once for all of them made Wheeler Shale —
    /// whose entire twist is "several specimens per slab" — strictly worse than every
    /// other site.
    public var instances: Int
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
    /// Daylight the slab started with, which charms and the night-dig twist both move.
    /// Grading against a fixed sixty seconds would mark down every night dig.
    public var totalDaylight: Float
    public var modifiers: ModifierSet
    public var tuning: SimTuning

    public init(
        baseValue: Int,
        instances: Int = 1,
        exposure: Float,
        boneCells: Int,
        crackedCells: Int,
        wholeGems: Int,
        clearedNodules: Int = 0,
        daylightRemaining: Float = 0,
        totalDaylight: Float = SimTuning.standard.daylightSeconds,
        modifiers: ModifierSet = ModifierSet(),
        tuning: SimTuning = .standard
    ) {
        self.baseValue = baseValue
        self.instances = max(1, instances)
        self.exposure = exposure
        self.boneCells = boneCells
        self.crackedCells = crackedCells
        self.wholeGems = wholeGems
        self.clearedNodules = clearedNodules
        self.daylightRemaining = daylightRemaining
        self.totalDaylight = totalDaylight
        self.modifiers = modifiers
        self.tuning = tuning
    }
}

extension PayoutContext {
    /// The base value actually used, after the instance count.
    public var effectiveBaseValue: Int { baseValue * max(1, instances) }
}

/// What the results screen prints, line for line.
public struct PayoutBreakdown: Sendable, Codable, Equatable {
    /// The base the fossil money was computed against, after the instance count. The
    /// results card shows "$84 of $120" against this, not against the species' value.
    public var baseValue: Int
    public var exposure: Float
    public var intact: Float
    public var fossil: Int
    public var gems: Int
    /// Rock hound and other flat money, after multipliers.
    public var bonuses: Int
    /// The multiplier that was actually applied, for the "x1.5 night dig" line.
    public var multiplier: Float
    public var rushApplied: Bool
    /// The grade's letter, and what it added. Optional on the wire so a slab record written
    /// before grading existed still decodes -- `RunStore` discards anything the decoder
    /// throws on, so a new non-optional field is indistinguishable from a corrupt save.
    private var gradeRaw: String?
    public var grade: SlabGrade.Letter {
        get { SlabGrade.Letter(rawValue: gradeRaw ?? "") ?? .c }
        set { gradeRaw = newValue.rawValue }
    }
    private var gradeBonusRaw: Int?
    /// Dollars the grade added, for the results card to show on its own line.
    public var gradeBonus: Int {
        get { gradeBonusRaw ?? 0 }
        set { gradeBonusRaw = newValue }
    }
    public var total: Int

    public init(
        baseValue: Int = 0,
        exposure: Float, intact: Float, fossil: Int, gems: Int,
        bonuses: Int, multiplier: Float, rushApplied: Bool,
        grade: SlabGrade.Letter = .c, gradeBonus: Int = 0, total: Int
    ) {
        self.baseValue = baseValue
        self.exposure = exposure
        self.intact = intact
        self.fossil = fossil
        self.gems = gems
        self.bonuses = bonuses
        self.multiplier = multiplier
        self.rushApplied = rushApplied
        self.gradeRaw = grade.rawValue
        self.gradeBonusRaw = gradeBonus
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

        let fossilRaw = Float(context.effectiveBaseValue)
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

        // Graded on what the slab came out like, then paid on it. Kept out of
        // `multiplier` so the results card can still print "x1.5 night dig" as the site's
        // own number rather than a figure with the grade silently folded into it.
        let grade = SlabGrade.of(
            exposure: exposure,
            intact: intact,
            daylightRemaining: context.daylightRemaining,
            totalDaylight: context.totalDaylight,
            tuning: tuning
        )
        let ungraded = Int((Float(fossilPay + gemPay) * multiplier).rounded())
        let scaled = Int(
            (Float(fossilPay + gemPay) * multiplier * grade.bonusMultiplier).rounded()
        )
        let bonuses = context.clearedNodules * mods.rockNodulePayout + mods.flatBonus

        return PayoutBreakdown(
            baseValue: context.effectiveBaseValue,
            exposure: exposure,
            intact: intact,
            fossil: fossilPay,
            gems: gemPay,
            bonuses: bonuses,
            multiplier: multiplier,
            rushApplied: rushApplied,
            grade: grade.letter,
            gradeBonus: scaled - ungraded,
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
        instances: Int = 1,
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
            instances: instances,
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
