import Foundation

/// A rung on a contribution ladder — personal, outfit, or crew.
///
/// One shape for all three, because they differ only in what is being counted and who
/// gets the reward. The rewards themselves use the same `kind:id` identifiers the crew
/// ladder already uses (docs/CREW_LEDGER.md), so a client that meets one it does not
/// recognise ignores it and still shows the rung as reached.
public struct ContributionMilestone: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var amount: Int
    public var name: String
    public var beat: String?
    public var unlocks: [String]
    public var cosmetics: [String]

    public init(
        id: String, amount: Int, name: String, beat: String? = nil,
        unlocks: [String] = [], cosmetics: [String] = []
    ) {
        self.id = id
        self.amount = amount
        self.name = name
        self.beat = beat
        self.unlocks = unlocks
        self.cosmetics = cosmetics
    }

    private enum CodingKeys: String, CodingKey {
        case id, amount, name, beat, unlocks, cosmetics
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            amount: try c.decode(Int.self, forKey: .amount),
            name: try c.decode(String.self, forKey: .name),
            beat: try c.decodeIfPresent(String.self, forKey: .beat),
            unlocks: try c.decodeIfPresent([String].self, forKey: .unlocks) ?? [],
            cosmetics: try c.decodeIfPresent([String].self, forKey: .cosmetics) ?? []
        )
    }

    public func reached(by amount: Int) -> Bool { amount >= self.amount }
}

/// Turns reward identifiers into the modifiers the dig already understands.
///
/// Every perk a ladder can grant resolves here, in one place, so that a milestone cannot
/// invent a mechanic. If an identifier is not listed it contributes nothing — which is
/// what lets the server add a rung that older clients simply display without applying.
public enum ContributionPerks {

    /// Kept deliberately small. M3's lesson was that a reward making money easier
    /// compounds: more income pays the debt faster, which reaches the next rung sooner,
    /// which grants more income. These are a few seconds and a couple of percent, and
    /// nothing here touches the crack rate or the payout exponent.
    public static func modifiers(for unlocks: [String]) -> ModifierSet {
        var set = ModifierSet()
        for unlock in unlocks {
            switch unlock {
            case "perk:personal_daylight_3": set.daylightDelta += 3
            case "perk:outfit_daylight_5": set.daylightDelta += 5
            case "perk:outfit_payout_1_02": set.payoutMultiplier *= 1.02
            case "perk:crew_stake_50", "perk:installment_growth_1_28":
                // Economy-level crew perks, applied by the run layer rather than here.
                break
            case "perk:seal_payout_1_05": set.payoutMultiplier *= 1.05
            default: break
            }
        }
        return set
    }

    /// Item pools a set of unlock identifiers opens.
    public static func pools(for unlocks: [String]) -> Set<ItemPool> {
        var pools: Set<ItemPool> = [.shop]
        for unlock in unlocks where unlock.hasPrefix("charmpool:") {
            if unlock == "charmpool:vault" || unlock == "charmpool:outfit" {
                pools.insert(.vault)
            }
        }
        return pools
    }

    /// Rungs newly passed moving from `previous` to `current`.
    public static func newlyReached(
        _ ladder: [ContributionMilestone], previous: Int, current: Int
    ) -> [ContributionMilestone] {
        ladder
            .filter { $0.amount > previous && $0.amount <= current }
            .sorted { $0.amount < $1.amount }
    }
}
