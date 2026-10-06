import Foundation

/// Which pool an item is drawn from.
public enum ItemPool: String, Sendable, Codable {
    /// In the supply tent from the start.
    case shop
    /// The Collector's vault, opened by a crew milestone (docs/CREW_LEDGER.md).
    case vault
}

/// A charm effect that cannot be a constant, because it depends on the loadout or the
/// day.
///
/// Kept as a closed enum rather than a closure so charms stay Codable content data.
/// Every case still *resolves into a `ModifierSet`* — the §4 rule that charms are
/// modifier functions over a context, not special cases in the payout formula.
public enum CharmScaling: Sendable, Codable, Equatable {
    /// "Compound interest": +value payout multiplier per charm owned.
    case payoutPerCharm(Float)
    /// +value payout multiplier per tool owned.
    case payoutPerTool(Float)
    /// +value safe-speed multiplier for each day survived this run.
    case safeSpeedPerDay(Float)
    /// +value payout multiplier per whole gem already banked this run.
    case payoutPerBankedGem(Float)
    /// +value payout per slab bagged unbroken this run. Care that compounds.
    case payoutPerFlawless(Float)
    /// +value payout per consecutive unbroken slab. Compounds harder and breaks harder.
    case payoutPerIntactStreak(Float)
    /// +value payout per distinct species this run. Pays for digging widely.
    case payoutPerSpecies(Float)
    /// +value payout per bone cell cracked this run. Pays for the damage, not despite it.
    case payoutPerCrackedCell(Float)
    /// +value payout per point of heat carried. The reward for selling badly.
    case payoutPerHeat(Float)
    /// +value payout per specimen sold quietly.
    case payoutPerQuietSale(Float)
    /// +value gem multiplier per gem already banked. Gems that feed gems.
    case gemsPerBankedGem(Float)
    /// +value seconds of daylight per slab bagged unbroken this run.
    case daylightPerFlawless(Float)
    /// +value safe speed per day still to come. Fast early, careful late.
    case safeSpeedPerDayRemaining(Float)
    /// x(1 + value) crack chance per charm carried. A cost that scales with the build,
    /// for charms strong enough to want one.
    case crackPerCharm(Float)

    /// Every rule a charm can carry.
    ///
    /// Hand-kept beside the decoder, and checked against it both ways by
    /// `CharmEngineTests`: every name here must decode, and every name here must be used
    /// by at least one charm. A rule the content never names is a rule that does not
    /// exist, and it reads as a shipped feature from the code alone — `payoutPerTool` and
    /// `daylightPerFlawless` sat here fully plumbed through both payout ceilings, in Swift
    /// and in Ruby, with no charm in the game able to produce either one.
    public static let allKinds = [
        "payoutPerCharm", "payoutPerTool", "payoutPerBankedGem", "payoutPerFlawless",
        "payoutPerIntactStreak", "payoutPerSpecies", "payoutPerCrackedCell",
        "payoutPerHeat", "payoutPerQuietSale", "gemsPerBankedGem", "daylightPerFlawless",
        "safeSpeedPerDay", "safeSpeedPerDayRemaining", "crackPerCharm",
    ]

    // Written as {"kind": "payoutPerCharm", "value": 0.02}. The synthesized form for
    // an enum with associated values nests under "_0", which is not something to ask a
    // content author to type.
    private enum Keys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(Float.self, forKey: .value)
        switch kind {
        case "payoutPerCharm": self = .payoutPerCharm(value)
        case "payoutPerTool": self = .payoutPerTool(value)
        case "safeSpeedPerDay": self = .safeSpeedPerDay(value)
        case "payoutPerFlawless": self = .payoutPerFlawless(value)
        case "payoutPerIntactStreak": self = .payoutPerIntactStreak(value)
        case "payoutPerSpecies": self = .payoutPerSpecies(value)
        case "payoutPerCrackedCell": self = .payoutPerCrackedCell(value)
        case "payoutPerHeat": self = .payoutPerHeat(value)
        case "payoutPerQuietSale": self = .payoutPerQuietSale(value)
        case "gemsPerBankedGem": self = .gemsPerBankedGem(value)
        case "daylightPerFlawless": self = .daylightPerFlawless(value)
        case "safeSpeedPerDayRemaining": self = .safeSpeedPerDayRemaining(value)
        case "crackPerCharm": self = .crackPerCharm(value)
        case "payoutPerBankedGem": self = .payoutPerBankedGem(value)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown charm scaling \(kind)"
            ))
        }
    }

    /// The name the content uses for this rule, and the only place that string is written.
    ///
    /// The encoder used to repeat it beside every case, forty lines in which a case could
    /// quietly write its neighbour's name and nothing would notice until a charm loaded
    /// back as the wrong rule.
    public var kindName: String {
        switch self {
        case .payoutPerCharm: "payoutPerCharm"
        case .payoutPerTool: "payoutPerTool"
        case .payoutPerBankedGem: "payoutPerBankedGem"
        case .payoutPerFlawless: "payoutPerFlawless"
        case .payoutPerIntactStreak: "payoutPerIntactStreak"
        case .payoutPerSpecies: "payoutPerSpecies"
        case .payoutPerCrackedCell: "payoutPerCrackedCell"
        case .payoutPerHeat: "payoutPerHeat"
        case .payoutPerQuietSale: "payoutPerQuietSale"
        case .gemsPerBankedGem: "gemsPerBankedGem"
        case .daylightPerFlawless: "daylightPerFlawless"
        case .safeSpeedPerDay: "safeSpeedPerDay"
        case .safeSpeedPerDayRemaining: "safeSpeedPerDayRemaining"
        case .crackPerCharm: "crackPerCharm"
        }
    }

    /// How much the rule pays per unit of whatever it counts.
    public var step: Float {
        switch self {
        case .payoutPerCharm(let v), .payoutPerTool(let v), .payoutPerBankedGem(let v),
            .payoutPerFlawless(let v), .payoutPerIntactStreak(let v),
            .payoutPerSpecies(let v), .payoutPerCrackedCell(let v), .payoutPerHeat(let v),
            .payoutPerQuietSale(let v), .gemsPerBankedGem(let v),
            .daylightPerFlawless(let v), .safeSpeedPerDay(let v),
            .safeSpeedPerDayRemaining(let v), .crackPerCharm(let v):
            v
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kindName, forKey: .kind)
        try container.encode(step, forKey: .value)
    }

    func apply(to set: inout ModifierSet, context: CharmContext) {
        switch self {
        case .payoutPerCharm(let step):
            set.payoutMultiplier *= 1 + step * Float(context.charmCount)
        case .payoutPerTool(let step):
            set.payoutMultiplier *= 1 + step * Float(context.toolCount)
        case .safeSpeedPerDay(let step):
            set.safeSpeedMultiplier *= 1 + step * Float(max(0, context.day - 1))
        case .payoutPerBankedGem(let step):
            set.payoutMultiplier *= 1 + step * Float(context.bankedGems)
        case .payoutPerFlawless(let step):
            set.payoutMultiplier *= 1 + step * Float(context.flawlessSlabs)
        case .payoutPerIntactStreak(let step):
            set.payoutMultiplier *= 1 + step * Float(context.intactStreak)
        case .payoutPerSpecies(let step):
            set.payoutMultiplier *= 1 + step * Float(context.speciesThisRun)
        case .payoutPerCrackedCell(let step):
            set.payoutMultiplier *= 1 + step * Float(context.crackedCells)
        case .payoutPerHeat(let step):
            set.payoutMultiplier *= 1 + step * Float(context.heat)
        case .payoutPerQuietSale(let step):
            set.payoutMultiplier *= 1 + step * Float(context.quietSales)
        case .gemsPerBankedGem(let step):
            set.gemMultiplier *= 1 + step * Float(context.bankedGems)
        case .daylightPerFlawless(let step):
            set.daylightDelta += step * Float(context.flawlessSlabs)
        case .safeSpeedPerDayRemaining(let step):
            set.safeSpeedMultiplier *= 1 + step * Float(max(0, context.daysRemaining))
        case .crackPerCharm(let step):
            set.crackMultiplier *= 1 + step * Float(context.charmCount)
        }
    }
}

/// A charm that changes which slab gets generated, rather than how it is dug.
///
/// Separate from `ModifierSet` because generation happens before any modifier is
/// consulted, and pretending otherwise would mean a multiplier that silently did
/// nothing.
public struct SlabRule: Sendable, Codable, Equatable {
    /// Applies on every day divisible by this. "Cretaceous permit" uses 3.
    public var everyNthDay: Int
    /// The site the slab is drawn from instead.
    public var siteID: String

    public init(everyNthDay: Int, siteID: String) {
        self.everyNthDay = everyNthDay
        self.siteID = siteID
    }

    public func applies(onDay day: Int) -> Bool {
        everyNthDay > 0 && day % everyNthDay == 0
    }
}

/// Everything the charm layer knows when it resolves.
public struct CharmContext: Sendable, Equatable {
    public var day: Int
    public var charmCount: Int
    public var toolCount: Int
    public var siteID: String
    public var tier: Int
    public var bankedGems: Int

    // What follows is the difference between a modifier and a build. A charm that reads
    // only its own value is a percentage; a charm that reads the *run* can be set up for,
    // played around, and combined -- and two charms reading the same counter stack into
    // something neither does alone.
    //
    /// Slabs bagged this run with nothing cracked.
    public var flawlessSlabs: Int = 0
    /// Bone cells cracked this run. The thing most charms want less of, and a few want more.
    public var crackedCells: Int = 0
    /// Distinct species bagged this run.
    public var speciesThisRun: Int = 0
    /// Attention carried. Pays for charms that like trouble.
    public var heat: Int = 0
    /// Specimens sold to someone who does not report the sale.
    public var quietSales: Int = 0
    /// Days still to come, including today.
    public var daysRemaining: Int = 1
    /// Consecutive unbroken slabs ending with the last one bagged.
    public var intactStreak: Int = 0

    public init(
        day: Int = 1, charmCount: Int = 0, toolCount: Int = 1,
        siteID: String = "", tier: Int = 1, bankedGems: Int = 0,
        flawlessSlabs: Int = 0, crackedCells: Int = 0, speciesThisRun: Int = 0,
        heat: Int = 0, quietSales: Int = 0, daysRemaining: Int = 1, intactStreak: Int = 0
    ) {
        self.day = day
        self.charmCount = charmCount
        self.toolCount = toolCount
        self.siteID = siteID
        self.tier = tier
        self.bankedGems = bankedGems
        self.flawlessSlabs = flawlessSlabs
        self.crackedCells = crackedCells
        self.speciesThisRun = speciesThisRun
        self.heat = heat
        self.quietSales = quietSales
        self.daysRemaining = daysRemaining
        self.intactStreak = intactStreak
    }
}

/// The Balatro layer. Stackable, order-independent, and almost entirely data.
public struct Charm: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var blurb: String
    public var price: Int
    public var pool: ItemPool
    /// The constant part. Most charms are only this.
    public var modifiers: ModifierSet
    /// The part that depends on context, for the few charms that need it.
    public var scaling: CharmScaling?
    /// Generation-time override, for the few that need that instead.
    public var slabRule: SlabRule?
    public var reputationRequired: Int

    public init(
        id: String, name: String, blurb: String, price: Int,
        pool: ItemPool = .shop, modifiers: ModifierSet = ModifierSet(),
        scaling: CharmScaling? = nil, slabRule: SlabRule? = nil,
        reputationRequired: Int = 0
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.price = price
        self.pool = pool
        self.modifiers = modifiers
        self.scaling = scaling
        self.slabRule = slabRule
        self.reputationRequired = reputationRequired
    }

    public var resaleValue: Int { price / 2 }

    /// This charm's contribution, given the context.
    public func resolve(_ context: CharmContext) -> ModifierSet {
        var set = modifiers
        scaling?.apply(to: &set, context: context)
        return set
    }
}

/// What the player is carrying. The single place tools, charms and the site twist get
/// folded into one `ModifierSet`.
public struct Loadout: Sendable, Equatable {
    public var tools: [Tool]
    public var charms: [Charm]

    public init(tools: [Tool] = [], charms: [Charm] = []) {
        self.tools = tools
        self.charms = charms
    }

    public static func resolve(
        toolIDs: [String], charmIDs: [String], catalog: ContentCatalog = .shared
    ) -> Loadout {
        Loadout(
            tools: toolIDs.compactMap { catalog.tool($0) },
            charms: charmIDs.compactMap { catalog.charm($0) }
        )
    }

    /// Brushes you can select in the tray, in a stable order. Never empty: a loadout
    /// with no brush would be a dig you cannot dig.
    public var brushes: [BrushTool] {
        let owned = tools.compactMap(\.brush)
        return owned.isEmpty ? [BrushTool.brush] : owned
    }

    public var passives: [Tool] { tools.filter { !$0.isBrush } }

    /// Everything the loadout contributes, before the site twist.
    ///
    /// Multipliers multiply and deltas add, both commutative, so the order of this
    /// array can never change the result — which is the §4 guarantee that twenty
    /// charms in any order behave the same.
    public func modifiers(context: CharmContext) -> ModifierSet {
        var resolved = context
        resolved.charmCount = charms.count
        resolved.toolCount = tools.count
        return ModifierSet.combining(
            tools.map(\.modifiers) + charms.map { $0.resolve(resolved) }
        )
    }

    /// Which site this day's slab is drawn from, if a charm overrides it.
    public func siteOverride(onDay day: Int) -> String? {
        // Lowest id wins when two rules fire, so the result cannot depend on the order
        // the charms were bought in.
        charms
            .compactMap { $0.slabRule }
            .filter { $0.applies(onDay: day) }
            .map(\.siteID)
            .min()
    }

    public func has(toolID: String) -> Bool { tools.contains { $0.id == toolID } }
    public func has(charmID: String) -> Bool { charms.contains { $0.id == charmID } }
}

// MARK: - Coding

extension Charm {
    public enum CodingKeys: String, CodingKey {
        case id, name, blurb, price, pool, modifiers, scaling, slabRule, reputationRequired
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            blurb: try c.decodeIfPresent(String.self, forKey: .blurb) ?? "",
            price: try c.decode(Int.self, forKey: .price),
            pool: try c.decodeIfPresent(ItemPool.self, forKey: .pool) ?? .shop,
            modifiers: try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers)
                ?? ModifierSet(),
            scaling: try c.decodeIfPresent(CharmScaling.self, forKey: .scaling),
            slabRule: try c.decodeIfPresent(SlabRule.self, forKey: .slabRule),
            reputationRequired: try c.decodeIfPresent(Int.self, forKey: .reputationRequired) ?? 0
        )
    }
}
