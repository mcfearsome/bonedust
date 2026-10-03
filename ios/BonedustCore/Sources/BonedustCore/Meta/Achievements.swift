import Foundation

/// What has to be true to earn an achievement.
///
/// A closed enum rather than a predicate closure, so achievements stay content data and
/// so the whole set can be evaluated in a test without Game Center, a signed-in account,
/// or a network.
public enum AchievementRule: Sendable, Codable, Equatable {
    /// Any skeleton set finished.
    case firstSetCompleted
    /// A slab bagged fully exposed with nothing cracked.
    case flawlessSlab
    case slabPayoutAtLeast(Int)
    case runStreakAtLeast(Int)
    case speciesDiscovered(Int)
    case lifetimeContributionAtLeast(Int)
    /// Every species in a site's table catalogued.
    case siteCleared(String)
    case installmentTierReached(Int)

    private enum Keys: String, CodingKey { case kind, value, site }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "firstSetCompleted": self = .firstSetCompleted
        case "flawlessSlab": self = .flawlessSlab
        case "slabPayoutAtLeast":
            self = .slabPayoutAtLeast(try c.decode(Int.self, forKey: .value))
        case "runStreakAtLeast":
            self = .runStreakAtLeast(try c.decode(Int.self, forKey: .value))
        case "speciesDiscovered":
            self = .speciesDiscovered(try c.decode(Int.self, forKey: .value))
        case "lifetimeContributionAtLeast":
            self = .lifetimeContributionAtLeast(try c.decode(Int.self, forKey: .value))
        case "siteCleared":
            self = .siteCleared(try c.decode(String.self, forKey: .site))
        case "installmentTierReached":
            self = .installmentTierReached(try c.decode(Int.self, forKey: .value))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown achievement rule \(kind)"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .firstSetCompleted: try c.encode("firstSetCompleted", forKey: .kind)
        case .flawlessSlab: try c.encode("flawlessSlab", forKey: .kind)
        case .slabPayoutAtLeast(let v):
            try c.encode("slabPayoutAtLeast", forKey: .kind); try c.encode(v, forKey: .value)
        case .runStreakAtLeast(let v):
            try c.encode("runStreakAtLeast", forKey: .kind); try c.encode(v, forKey: .value)
        case .speciesDiscovered(let v):
            try c.encode("speciesDiscovered", forKey: .kind); try c.encode(v, forKey: .value)
        case .lifetimeContributionAtLeast(let v):
            try c.encode("lifetimeContributionAtLeast", forKey: .kind)
            try c.encode(v, forKey: .value)
        case .siteCleared(let site):
            try c.encode("siteCleared", forKey: .kind); try c.encode(site, forKey: .site)
        case .installmentTierReached(let v):
            try c.encode("installmentTierReached", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
}

public struct Achievement: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var blurb: String
    public var rule: AchievementRule
    /// Game Center's identifier. Kept in content so it can be corrected without a code
    /// change if the App Store Connect entry is named differently.
    public var gameCenterID: String

    public init(
        id: String, name: String, blurb: String, rule: AchievementRule,
        gameCenterID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.rule = rule
        self.gameCenterID = gameCenterID ?? "bonedust.achievement.\(id)"
    }

    private enum CodingKeys: String, CodingKey { case id, name, blurb, rule, gameCenterID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            blurb: try c.decodeIfPresent(String.self, forKey: .blurb) ?? "",
            rule: try c.decode(AchievementRule.self, forKey: .rule),
            gameCenterID: try c.decodeIfPresent(String.self, forKey: .gameCenterID)
        )
    }
}

/// Game Center leaderboard identifiers (§5).
public enum Leaderboard {
    public static let runStreak = "bonedust.leaderboard.streak"
    public static let bestSlab = "bonedust.leaderboard.best_slab"
    public static let crewContribution = "bonedust.leaderboard.contribution"

    public static let all = [runStreak, bestSlab, crewContribution]
}

public enum Achievements {

    /// Which achievements the player now qualifies for.
    ///
    /// Recomputed from scratch against the whole of `MetaProgress` rather than fired as
    /// events. That means a rule added in a later version is awarded retroactively for
    /// play that already happened, and an achievement can never be missed because the
    /// app was killed at the wrong moment.
    public static func earned(
        by meta: MetaProgress, catalog: ContentCatalog = .shared
    ) -> Set<String> {
        var out = Set<String>()
        for achievement in catalog.achievements where satisfies(achievement.rule, meta, catalog) {
            out.insert(achievement.id)
        }
        return out
    }

    private static func satisfies(
        _ rule: AchievementRule, _ meta: MetaProgress, _ catalog: ContentCatalog
    ) -> Bool {
        switch rule {
        case .firstSetCompleted:
            return !meta.completedSetIDs.isEmpty
        case .flawlessSlab:
            return meta.hasFlawlessSlab
        case .slabPayoutAtLeast(let amount):
            return meta.bestSlabPayout >= amount
        case .runStreakAtLeast(let streak):
            return meta.longestStreak >= streak
        case .speciesDiscovered(let count):
            return meta.collection.discoveredCount >= count
        case .lifetimeContributionAtLeast(let amount):
            return meta.lifetimeContribution >= amount
        case .siteCleared(let siteID):
            let species = catalog.site(siteID)?.fossilWeights.keys ?? [:].keys
            let ids = Array(species)
            return !ids.isEmpty && ids.allSatisfy { meta.collection.has($0) }
        case .installmentTierReached(let tier):
            return meta.highestTierCleared >= tier
        }
    }
}
