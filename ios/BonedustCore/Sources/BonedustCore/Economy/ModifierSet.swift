/// Everything a site twist, charm, tool or set perk can change, as one flat bag of
/// multipliers and deltas.
///
/// This is the §4 requirement that charms be "stackable and order-independent"
/// made structural. A charm does not get to run code inside the brush loop or the
/// payout formula; it gets to fold values into this struct. Multipliers multiply,
/// deltas add, and both of those are commutative, so twenty charms in any order
/// produce the same number. Anything that cannot be expressed here is a charm that
/// needs redesigning, not a special case.
public struct ModifierSet: Sendable, Codable, Equatable {

    // MARK: Brushing

    /// Multiplies every tool's crack multiplier.
    public var crackMultiplier: Float = 1
    /// Multiplies every tool's safe speed. "Steady hands" contributes 1.25.
    public var safeSpeedMultiplier: Float = 1
    /// Multiplies rock hardness. "Dental pick" contributes 0.33.
    public var rockHardnessMultiplier: Float = 1

    // MARK: Daylight

    /// Seconds added to the 60 s base. Headlamp +10, Night owl +15, night dig -12.
    public var daylightDelta: Float = 0

    // MARK: Reading the slab

    /// Exposure needed before the specimen is identified. Lower is better.
    /// "Collector's eye" drops it to 0.10.
    public var identifyExposure: Float = 0.25
    /// Seconds of fossil-outline reveal at the start of a slab. X-ray goggles: 3.
    public var revealSeconds: Float = 0

    // MARK: Payout

    /// Multiplies fossil + gem money.
    public var payoutMultiplier: Float = 1
    /// Multiplies gem money only. Sieve contributes 2.
    public var gemMultiplier: Float = 1
    /// Fraction of `intact` that cracked bone still earns. "Authentic damage"
    /// contributes 0.5, so a cracked cell costs half as much.
    public var crackedIntactCredit: Float = 0
    /// Paid per fully-cleared rock nodule. "Rock hound" contributes 8.
    public var rockNodulePayout: Int = 0
    /// Added after all multipliers.
    public var flatBonus: Int = 0
    /// Payout multiplier applied only when the slab is bagged with at least
    /// `rushThreshold` seconds of daylight left. "Rush job" contributes 1.4 / 20 s.
    public var rushMultiplier: Float = 1
    public var rushThreshold: Float = 20

    public init() {}

    /// Folds another set in. Multipliers multiply, deltas add, and the two
    /// "lowest wins" fields take the minimum.
    public mutating func combine(_ other: ModifierSet) {
        crackMultiplier *= other.crackMultiplier
        safeSpeedMultiplier *= other.safeSpeedMultiplier
        rockHardnessMultiplier *= other.rockHardnessMultiplier
        daylightDelta += other.daylightDelta
        identifyExposure = min(identifyExposure, other.identifyExposure)
        revealSeconds += other.revealSeconds
        payoutMultiplier *= other.payoutMultiplier
        gemMultiplier *= other.gemMultiplier
        // Credits stack toward 1.0 but never past it: two "authentic damage"-style
        // charms must not make cracking pay *more* than intact bone.
        crackedIntactCredit = min(1, crackedIntactCredit + other.crackedIntactCredit)
        rockNodulePayout += other.rockNodulePayout
        flatBonus += other.flatBonus
        rushMultiplier *= other.rushMultiplier
        rushThreshold = min(rushThreshold, other.rushThreshold)
    }

    public static func combining(_ sets: [ModifierSet]) -> ModifierSet {
        var out = ModifierSet()
        for set in sets { out.combine(set) }
        return out
    }
}

// MARK: - Coding

extension ModifierSet {
    public enum CodingKeys: String, CodingKey {
        case crackMultiplier, safeSpeedMultiplier, rockHardnessMultiplier
        case daylightDelta, identifyExposure, revealSeconds
        case payoutMultiplier, gemMultiplier, crackedIntactCredit
        case rockNodulePayout, flatBonus, rushMultiplier, rushThreshold
    }

    /// Absent keys fall back to the neutral default, so a charm's JSON names only what
    /// it actually changes. A charm that had to spell out all thirteen fields would be
    /// unreadable, and every unstated field would be a chance to typo a 1 into a 0.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = ModifierSet()
        self.init()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        crackMultiplier = try value(.crackMultiplier, base.crackMultiplier)
        safeSpeedMultiplier = try value(.safeSpeedMultiplier, base.safeSpeedMultiplier)
        rockHardnessMultiplier = try value(.rockHardnessMultiplier, base.rockHardnessMultiplier)
        daylightDelta = try value(.daylightDelta, base.daylightDelta)
        identifyExposure = try value(.identifyExposure, base.identifyExposure)
        revealSeconds = try value(.revealSeconds, base.revealSeconds)
        payoutMultiplier = try value(.payoutMultiplier, base.payoutMultiplier)
        gemMultiplier = try value(.gemMultiplier, base.gemMultiplier)
        crackedIntactCredit = try value(.crackedIntactCredit, base.crackedIntactCredit)
        rockNodulePayout = try value(.rockNodulePayout, base.rockNodulePayout)
        flatBonus = try value(.flatBonus, base.flatBonus)
        rushMultiplier = try value(.rushMultiplier, base.rushMultiplier)
        rushThreshold = try value(.rushThreshold, base.rushThreshold)
    }
}
