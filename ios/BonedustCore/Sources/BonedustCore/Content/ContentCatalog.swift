import Foundation

/// All game content, decoded once from `Resources/content.json`.
public struct ContentCatalog: Sendable, Codable {
    public var version: Int
    public var fossils: [Fossil]
    public var sites: [Site]
    public var sets: [SkeletonSet]
    public var tools: [Tool]
    public var charms: [Charm]
    public var achievements: [Achievement]
    public var trails: [BrushTrail]
    /// Awarded from the player's own lifetime total, so they ship with the app and
    /// work with no network. Outfit and crew ladders come over the wire instead.
    public var personalMilestones: [ContributionMilestone]
    /// Permanent, Reputation-priced. See `Upgrade`.
    public var upgrades: [Upgrade]

    /// Built once in `init`, because the dig loop looks fossils up by id on every
    /// slab and a linear scan over nineteen entries inside generation is waste.
    public let fossilsByID: [String: Fossil]
    public let sitesByID: [String: Site]
    public let setsByID: [String: SkeletonSet]
    public let toolsByID: [String: Tool]
    public let charmsByID: [String: Charm]
    public let upgradesByID: [String: Upgrade]

    private enum CodingKeys: String, CodingKey {
        case version, fossils, sites, sets, tools, charms, achievements, trails
        case personalMilestones, upgrades
    }

    public init(
        version: Int,
        fossils: [Fossil],
        sites: [Site],
        sets: [SkeletonSet],
        tools: [Tool] = [],
        charms: [Charm] = [],
        achievements: [Achievement] = [],
        trails: [BrushTrail] = [],
        personalMilestones: [ContributionMilestone] = [],
        upgrades: [Upgrade] = []
    ) {
        self.version = version
        self.fossils = fossils
        self.sites = sites
        self.sets = sets
        self.tools = tools
        self.charms = charms
        self.achievements = achievements
        self.trails = trails
        self.personalMilestones = personalMilestones.sorted { $0.amount < $1.amount }
        // Sorted by price so the camp screen reads as a ladder without the view sorting it.
        self.upgrades = upgrades.sorted { $0.reputation < $1.reputation }
        self.upgradesByID = Dictionary(uniqueKeysWithValues: upgrades.map { ($0.id, $0) })
        self.fossilsByID = Dictionary(uniqueKeysWithValues: fossils.map { ($0.id, $0) })
        self.sitesByID = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        self.setsByID = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
        self.toolsByID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        self.charmsByID = Dictionary(uniqueKeysWithValues: charms.map { ($0.id, $0) })
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try c.decode(Int.self, forKey: .version),
            fossils: try c.decode([Fossil].self, forKey: .fossils),
            sites: try c.decode([Site].self, forKey: .sites),
            sets: try c.decode([SkeletonSet].self, forKey: .sets),
            tools: try c.decodeIfPresent([Tool].self, forKey: .tools) ?? [],
            charms: try c.decodeIfPresent([Charm].self, forKey: .charms) ?? [],
            achievements: try c.decodeIfPresent([Achievement].self, forKey: .achievements) ?? [],
            trails: try c.decodeIfPresent([BrushTrail].self, forKey: .trails) ?? [],
            personalMilestones: try c.decodeIfPresent(
                [ContributionMilestone].self, forKey: .personalMilestones
            ) ?? [],
            upgrades: try c.decodeIfPresent([Upgrade].self, forKey: .upgrades) ?? []
        )
    }

    public func fossil(_ id: String) -> Fossil? { fossilsByID[id] }
    public func site(_ id: String) -> Site? { sitesByID[id] }
    public func tool(_ id: String) -> Tool? { toolsByID[id] }
    public func achievement(_ id: String) -> Achievement? {
        achievements.first { $0.id == id }
    }
    public func trail(_ id: String) -> BrushTrail? { trails.first { $0.id == id } }

    /// Cosmetic trails the given Reputation has unlocked (§5).
    public func unlockedTrails(reputation: Int) -> [BrushTrail] {
        trails.filter { $0.reputationRequired <= reputation }
            .sorted { $0.reputationRequired < $1.reputationRequired }
    }
    public func charm(_ id: String) -> Charm? { charmsByID[id] }
    public func upgrade(_ id: String) -> Upgrade? { upgradesByID[id] }

    /// The tool every run starts with.
    public var startingTool: Tool {
        toolsByID[BrushTool.brush.id]
            ?? Tool(
                id: BrushTool.brush.id, name: BrushTool.brush.name,
                blurb: "", price: 0, brush: .brush
            )
    }

    /// Items the supply tent may offer, given progress.
    public func purchasableTools(reputation: Int, pools: Set<ItemPool>) -> [Tool] {
        tools.filter { $0.price > 0 && $0.reputationRequired <= reputation }
    }

    public func purchasableCharms(reputation: Int, pools: Set<ItemPool>) -> [Charm] {
        charms.filter { pools.contains($0.pool) && $0.reputationRequired <= reputation }
    }

    public func fossils(forSite siteID: String) -> [Fossil] {
        guard let site = sitesByID[siteID] else { return [] }
        return site.weightedTable.compactMap { fossilsByID[$0.fossilID] }
    }

    /// Fails loudly. Malformed bundled content is a build error, not a runtime
    /// condition worth recovering from — there is nothing sensible to fall back to.
    public static func load(from data: Data) throws -> ContentCatalog {
        try JSONDecoder().decode(ContentCatalog.self, from: data)
    }

    public static let shared: ContentCatalog = {
        guard let url = Bundle.module.url(forResource: "content", withExtension: "json") else {
            fatalError("content.json missing from BonedustCore resources")
        }
        do {
            return try load(from: try Data(contentsOf: url))
        } catch {
            fatalError("content.json is malformed: \(error)")
        }
    }()

    /// Content problems that should fail a test rather than ship.
    public func validate() -> [String] {
        var problems: [String] = []
        for site in sites {
            if site.fossilWeights.isEmpty { problems.append("site \(site.id) has no fossils") }
            for (fossilID, weight) in site.fossilWeights {
                if fossilsByID[fossilID] == nil {
                    problems.append("site \(site.id) references unknown fossil \(fossilID)")
                }
                if weight <= 0 {
                    problems.append("site \(site.id) gives \(fossilID) a non-positive weight")
                }
            }
        }
        for fossil in fossils {
            if fossil.instancesMin < 1 || fossil.instancesMax < fossil.instancesMin {
                problems.append("fossil \(fossil.id) has a broken instance range")
            }
            if fossil.baseValue <= 0 { problems.append("fossil \(fossil.id) is worthless") }
            if let setID = fossil.setID, setsByID[setID] == nil {
                problems.append("fossil \(fossil.id) belongs to unknown set \(setID)")
            }
        }
        for set in sets {
            for piece in set.pieces where fossilsByID[piece] == nil {
                problems.append("set \(set.id) references unknown fossil \(piece)")
            }
            if let siteID = set.perk.siteID, sitesByID[siteID] == nil {
                problems.append("set \(set.id) perk references unknown site \(siteID)")
            }
        }
        if toolsByID[BrushTool.brush.id] == nil {
            problems.append("the starting brush is missing from the tool list")
        }
        for tool in tools {
            if tool.isBrush, tool.brush?.id != tool.id {
                problems.append("tool \(tool.id) wraps a brush with a different id")
            }
            if !tool.isBrush, tool.modifiers == ModifierSet() {
                problems.append("passive tool \(tool.id) does nothing")
            }
        }
        for charm in charms {
            if charm.price <= 0 { problems.append("charm \(charm.id) is free") }
            if charm.modifiers == ModifierSet(), charm.scaling == nil, charm.slabRule == nil {
                problems.append("charm \(charm.id) does nothing")
            }
            if let rule = charm.slabRule, sitesByID[rule.siteID] == nil {
                problems.append("charm \(charm.id) points at unknown site \(rule.siteID)")
            }
        }
        for achievement in achievements {
            switch achievement.rule {
            case .siteCleared(let siteID) where sitesByID[siteID] == nil:
                problems.append("achievement \(achievement.id) references unknown site \(siteID)")
            case .speciesDiscovered(let count) where count > fossils.count:
                // A "catalogue everything" achievement that asks for more species than
                // exist is unearnable, and adding a fossil silently breaks it.
                problems.append(
                    "achievement \(achievement.id) needs \(count) species but only "
                        + "\(fossils.count) exist"
                )
            default:
                break
            }
        }
        if Set(achievements.map(\.id)).count != achievements.count {
            problems.append("duplicate achievement id")
        }
        if Set(trails.map(\.id)).count != trails.count { problems.append("duplicate trail id") }
        if Set(personalMilestones.map(\.id)).count != personalMilestones.count {
            problems.append("duplicate personal milestone id")
        }
        for milestone in personalMilestones where milestone.amount <= 0 {
            problems.append("personal milestone \(milestone.id) has a non-positive amount")
        }
        for milestone in personalMilestones
        where milestone.unlocks.isEmpty && milestone.cosmetics.isEmpty {
            problems.append("personal milestone \(milestone.id) rewards nothing")
        }
        if !trails.isEmpty, !trails.contains(where: { $0.reputationRequired == 0 }) {
            problems.append("no brush trail is available at zero Reputation")
        }
        if Set(tools.map(\.id)).count != tools.count { problems.append("duplicate tool id") }
        if Set(charms.map(\.id)).count != charms.count { problems.append("duplicate charm id") }

        let unreachable = Set(fossils.map(\.id))
            .subtracting(sites.flatMap { $0.fossilWeights.keys })
        for id in unreachable.sorted() {
            problems.append("fossil \(id) appears in no site table")
        }
        return problems
    }
}
