import Foundation

/// All game content, decoded once from `Resources/content.json`.
public struct ContentCatalog: Sendable, Codable {
    public var version: Int
    public var fossils: [Fossil]
    public var sites: [Site]
    public var sets: [SkeletonSet]

    /// Built once in `init`, because the dig loop looks fossils up by id on every
    /// slab and a linear scan over nineteen entries inside generation is waste.
    public let fossilsByID: [String: Fossil]
    public let sitesByID: [String: Site]
    public let setsByID: [String: SkeletonSet]

    private enum CodingKeys: String, CodingKey {
        case version, fossils, sites, sets
    }

    public init(version: Int, fossils: [Fossil], sites: [Site], sets: [SkeletonSet]) {
        self.version = version
        self.fossils = fossils
        self.sites = sites
        self.sets = sets
        self.fossilsByID = Dictionary(uniqueKeysWithValues: fossils.map { ($0.id, $0) })
        self.sitesByID = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        self.setsByID = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try c.decode(Int.self, forKey: .version),
            fossils: try c.decode([Fossil].self, forKey: .fossils),
            sites: try c.decode([Site].self, forKey: .sites),
            sets: try c.decode([SkeletonSet].self, forKey: .sets)
        )
    }

    public func fossil(_ id: String) -> Fossil? { fossilsByID[id] }
    public func site(_ id: String) -> Site? { sitesByID[id] }

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
        let unreachable = Set(fossils.map(\.id))
            .subtracting(sites.flatMap { $0.fossilWeights.keys })
        for id in unreachable.sorted() {
            problems.append("fossil \(id) appears in no site table")
        }
        return problems
    }
}
