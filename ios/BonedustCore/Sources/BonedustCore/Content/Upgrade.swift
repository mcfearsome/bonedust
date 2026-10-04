import Foundation

/// Something bought once with Reputation and kept forever.
///
/// This is where progression lives now. Tools and charms used to carry between runs, which
/// meant a brush bought in week one was still doing its job in week nine — reported from
/// play as "once i made my purchases i never really looked at the store again". The tent
/// had nothing left to offer and the middle of the game had no decisions left in it.
///
/// Kit is now run-scoped and the permanent track is this, which matters for two reasons:
///
/// **Reputation survives a failed week.** Tools never did — §4 has the Collector take them
/// as interest — so tying progression to kit meant one bad run undid a career, while tying
/// it to Reputation means a bad run costs a week.
///
/// **It is earned, not bought.** Reputation comes from leftover cash and from clearing a
/// tier, so it accrues from *surviving* rather than from income. That stops the upgrade
/// track compounding the way a cash-priced permanent upgrade would, where more money buys
/// more income buys more money.
public struct Upgrade: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var blurb: String
    /// What it costs in Reputation.
    public var reputation: Int
    /// Folded into every run's modifiers once owned.
    public var modifiers: ModifierSet
    /// Carries one more charm than the base two.
    public var extraCharmSlot: Bool
    /// Adds a day to every week.
    public var extraDays: Int

    public init(
        id: String,
        name: String,
        blurb: String = "",
        reputation: Int,
        modifiers: ModifierSet = ModifierSet(),
        extraCharmSlot: Bool = false,
        extraDays: Int = 0
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.reputation = reputation
        self.modifiers = modifiers
        self.extraCharmSlot = extraCharmSlot
        self.extraDays = extraDays
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, blurb, reputation, modifiers, extraCharmSlot, extraDays
    }

    /// Hand-written so every field but `id`, `name` and `reputation` is optional in the
    /// data. Most upgrades are one modifier, and making the rest required would mean six
    /// entries carrying four empty keys each.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        reputation = try c.decode(Int.self, forKey: .reputation)
        modifiers = try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? ModifierSet()
        extraCharmSlot = try c.decodeIfPresent(Bool.self, forKey: .extraCharmSlot) ?? false
        extraDays = try c.decodeIfPresent(Int.self, forKey: .extraDays) ?? 0
    }
}

extension Upgrade {
    /// Everything owned, composed into one modifier set.
    ///
    /// Order-independent, exactly as charms are: multipliers multiply and deltas add, and
    /// both commute, so what a player ends up with never depends on what they bought first.
    public static func combined(
        _ ids: [String], catalog: ContentCatalog = .shared
    ) -> ModifierSet {
        ModifierSet.combining(ids.compactMap { catalog.upgrade($0)?.modifiers })
    }

    public static func extraCharmSlots(
        _ ids: [String], catalog: ContentCatalog = .shared
    ) -> Int {
        ids.compactMap { catalog.upgrade($0) }.filter(\.extraCharmSlot).count
    }

    public static func extraDays(
        _ ids: [String], catalog: ContentCatalog = .shared
    ) -> Int {
        ids.compactMap { catalog.upgrade($0) }.reduce(0) { $0 + $1.extraDays }
    }
}
