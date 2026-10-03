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
        case "payoutPerBankedGem": self = .payoutPerBankedGem(value)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown charm scaling \(kind)"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .payoutPerCharm(let value):
            try container.encode("payoutPerCharm", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .payoutPerTool(let value):
            try container.encode("payoutPerTool", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .safeSpeedPerDay(let value):
            try container.encode("safeSpeedPerDay", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .payoutPerBankedGem(let value):
            try container.encode("payoutPerBankedGem", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
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

    public init(
        day: Int = 1, charmCount: Int = 0, toolCount: Int = 1,
        siteID: String = "", tier: Int = 1, bankedGems: Int = 0
    ) {
        self.day = day
        self.charmCount = charmCount
        self.toolCount = toolCount
        self.siteID = siteID
        self.tier = tier
        self.bankedGems = bankedGems
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
