import Foundation

/// What the supply tent is offering (§4: three tools and three charms, plus one
/// restock for $10).
public struct ShopStock: Sendable, Codable, Equatable {
    public var toolIDs: [String]
    public var charmIDs: [String]
    /// How many restocks have been bought on this visit.
    public var restocks: Int

    public init(toolIDs: [String] = [], charmIDs: [String] = [], restocks: Int = 0) {
        self.toolIDs = toolIDs
        self.charmIDs = charmIDs
        self.restocks = restocks
    }

    public var isEmpty: Bool { toolIDs.isEmpty && charmIDs.isEmpty }
}

public enum Shop {

    public static let restockPrice = 10
    public static let toolsOffered = 3
    public static let charmsOffered = 3

    /// Rolls the stock for one visit.
    ///
    /// Seeded from the run, the day and the restock count, so the same visit always
    /// offers the same things. That matters for more than tidiness: the stock is part
    /// of the autosave, and a shop that re-rolled on relaunch would be a free reroll
    /// for anyone who did not like what they saw.
    public static func stock(
        runSeed: UInt64,
        day: Int,
        restocks: Int,
        ownedToolIDs: [String],
        ownedCharmIDs: [String],
        reputation: Int,
        pools: Set<ItemPool> = [.shop],
        catalog: ContentCatalog = .shared
    ) -> ShopStock {
        var rng = SplitMix64(
            seed: runSeed
                ^ (UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15)
                ^ (UInt64(bitPattern: Int64(restocks + 1)) &* 0xBF58_476D_1CE4_E5B9)
        )
        let owned = Set(ownedToolIDs)
        let ownedCharms = Set(ownedCharmIDs)

        // Sorted before drawing: the catalog arrays come from JSON, and relying on
        // their order would make a content reorder change every historical shop roll.
        let tools = catalog
            .purchasableTools(reputation: reputation, pools: pools)
            .filter { !owned.contains($0.id) }
            .sorted { $0.id < $1.id }
        let charms = catalog
            .purchasableCharms(reputation: reputation, pools: pools)
            .filter { !ownedCharms.contains($0.id) }
            .sorted { $0.id < $1.id }

        return ShopStock(
            toolIDs: draw(toolsOffered, from: tools.map(\.id), &rng),
            charmIDs: draw(charmsOffered, from: charms.map(\.id), &rng),
            restocks: restocks
        )
    }

    /// Partial Fisher-Yates, so an item cannot be offered twice in one roll.
    private static func draw(
        _ count: Int, from pool: [String], _ rng: inout SplitMix64
    ) -> [String] {
        guard !pool.isEmpty else { return [] }
        var remaining = pool
        var drawn: [String] = []
        for _ in 0..<min(count, remaining.count) {
            let index = rng.nextInt(below: remaining.count)
            drawn.append(remaining.remove(at: index))
        }
        return drawn
    }
}
