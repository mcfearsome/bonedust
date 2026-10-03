import Foundation

/// Anything that takes up one of the three tool slots (§4).
///
/// Brushes and passives share those slots on purpose. Carrying a Sieve means not
/// carrying the Air blower, which is the decision that makes the slots interesting —
/// if passives had their own slots they would just be free money.
public struct Tool: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var blurb: String
    public var price: Int
    /// Non-nil for a tool you can select in the tray and brush with.
    public var brush: BrushTool?
    /// Always-on contribution while the tool is owned.
    public var modifiers: ModifierSet
    /// Reputation needed before it appears in the supply tent.
    public var reputationRequired: Int

    public var isBrush: Bool { brush != nil }

    public init(
        id: String, name: String, blurb: String, price: Int,
        brush: BrushTool? = nil, modifiers: ModifierSet = ModifierSet(),
        reputationRequired: Int = 0
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.price = price
        self.brush = brush
        self.modifiers = modifiers
        self.reputationRequired = reputationRequired
    }

    /// What selling it back returns (§4: half price).
    public var resaleValue: Int { price / 2 }
}

// MARK: - Coding

extension Tool {
    public enum CodingKeys: String, CodingKey {
        case id, name, blurb, price, brush, modifiers, reputationRequired
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            blurb: try c.decodeIfPresent(String.self, forKey: .blurb) ?? "",
            price: try c.decode(Int.self, forKey: .price),
            brush: try c.decodeIfPresent(BrushTool.self, forKey: .brush),
            modifiers: try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers)
                ?? ModifierSet(),
            reputationRequired: try c.decodeIfPresent(Int.self, forKey: .reputationRequired) ?? 0
        )
    }
}

extension BrushTool {
    public enum CodingKeys: String, CodingKey {
        case id, name, radius, strength, crackMultiplier, safeSpeed, price
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            radius: try c.decode(Float.self, forKey: .radius),
            strength: try c.decode(Float.self, forKey: .strength),
            crackMultiplier: try c.decode(Float.self, forKey: .crackMultiplier),
            safeSpeed: try c.decode(Float.self, forKey: .safeSpeed),
            price: try c.decodeIfPresent(Int.self, forKey: .price) ?? 0
        )
    }
}
