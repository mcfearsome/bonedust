import Foundation

/// One species' line in the museum drawer (§5).
public struct SpecimenRecord: Sendable, Codable, Equatable {
    public var fossilID: String
    public var timesFound: Int
    /// Best exposure ever achieved on this species.
    public var bestExposure: Float
    public var bestIntact: Float
    public var bestPayout: Int
    /// Which run first turned one up, for the drawer's ordering.
    public var firstFoundRun: Int

    public init(
        fossilID: String, timesFound: Int = 0, bestExposure: Float = 0,
        bestIntact: Float = 0, bestPayout: Int = 0, firstFoundRun: Int = 0
    ) {
        self.fossilID = fossilID
        self.timesFound = timesFound
        self.bestExposure = bestExposure
        self.bestIntact = bestIntact
        self.bestPayout = bestPayout
        self.firstFoundRun = firstFoundRun
    }

    /// A specimen the Collector could not fault: fully exposed, nothing cracked.
    public var isPerfect: Bool { bestExposure >= 0.999 && bestIntact >= 0.999 }
}

/// Everything the player has dug up, ever.
public struct Collection: Sendable, Codable, Equatable {

    public static let currentSchema = 1

    public var schema: Int
    public var records: [String: SpecimenRecord]

    public init() {
        self.schema = Collection.currentSchema
        self.records = [:]
    }

    // MARK: Recording

    /// Files a finished slab.
    ///
    /// Only identified specimens are catalogued. A slab abandoned at 4% exposure was a
    /// hole in the ground, not a find, and letting it fill the drawer would make the
    /// Collection a log of attempts rather than a record of what you have actually
    /// pulled out of the rock.
    @discardableResult
    public mutating func record(_ slab: SlabRecord, runIndex: Int = 0) -> Bool {
        guard slab.identified else { return false }
        var entry = records[slab.fossilID]
            ?? SpecimenRecord(fossilID: slab.fossilID, firstFoundRun: runIndex)
        let isNew = records[slab.fossilID] == nil
        entry.timesFound += 1
        entry.bestExposure = max(entry.bestExposure, slab.payout.exposure)
        entry.bestIntact = max(entry.bestIntact, slab.payout.intact)
        entry.bestPayout = max(entry.bestPayout, slab.payout.total)
        records[slab.fossilID] = entry
        return isNew
    }

    // MARK: Reading

    public func has(_ fossilID: String) -> Bool { records[fossilID] != nil }
    public func record(for fossilID: String) -> SpecimenRecord? { records[fossilID] }
    public var discoveredCount: Int { records.count }
    public var perfectCount: Int { records.values.filter(\.isPerfect).count }

    public func completionFraction(catalog: ContentCatalog = .shared) -> Float {
        guard !catalog.fossils.isEmpty else { return 0 }
        return Float(discoveredCount) / Float(catalog.fossils.count)
    }

    // MARK: Skeleton sets

    public func progress(for set: SkeletonSet) -> (found: Int, total: Int) {
        (set.pieces.filter { has($0) }.count, set.pieces.count)
    }

    public func isComplete(_ set: SkeletonSet) -> Bool {
        !set.pieces.isEmpty && set.pieces.allSatisfy { has($0) }
    }

    /// Sets finished, in a stable order so a reward is never awarded twice in a
    /// different sequence.
    public func completedSets(catalog: ContentCatalog = .shared) -> [SkeletonSet] {
        catalog.sets.filter { isComplete($0) }.sorted { $0.id < $1.id }
    }
}

public extension SetPerk {
    /// The perk as a `ModifierSet`, for a given site.
    ///
    /// Returns neutral when the perk is site-specific and this is the wrong site, so a
    /// completed set folds into the same composition path as a charm or a site twist
    /// rather than being checked for at the point of payout.
    func modifiers(forSite siteID: String) -> ModifierSet {
        var set = ModifierSet()
        if let required = self.siteID, required != siteID { return set }
        switch kind {
        case .sitePayoutBonus: set.payoutMultiplier = 1 + value
        case .extraDaylight: set.daylightDelta = value
        case .crackReduction: set.crackMultiplier = max(0, 1 - value)
        case .gemBonus: set.gemMultiplier = 1 + value
        }
        return set
    }
}
