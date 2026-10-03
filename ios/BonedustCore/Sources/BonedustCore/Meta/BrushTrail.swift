import Foundation

/// A cosmetic brush trail, unlocked by Reputation (§5).
///
/// Carries only colour and geometry, no behaviour: a trail must never change how a slab
/// digs, or Reputation would be buying power rather than decoration and the meta layer
/// would start competing with the charms.
public struct BrushTrail: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var colour: RGB8
    /// Particle lifetime in seconds.
    public var lifetime: Float
    /// Particle size as a fraction of a cell.
    public var scale: Float
    public var reputationRequired: Int

    public init(
        id: String, name: String, colour: RGB8,
        lifetime: Float = 0.42, scale: Float = 0.09, reputationRequired: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colour = colour
        self.lifetime = lifetime
        self.scale = scale
        self.reputationRequired = reputationRequired
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colour, lifetime, scale, reputationRequired
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            colour: try c.decode(RGB8.self, forKey: .colour),
            lifetime: try c.decodeIfPresent(Float.self, forKey: .lifetime) ?? 0.42,
            scale: try c.decodeIfPresent(Float.self, forKey: .scale) ?? 0.09,
            reputationRequired: try c.decodeIfPresent(Int.self, forKey: .reputationRequired) ?? 0
        )
    }

    /// The default: dust the colour of whatever layer is coming off.
    public static let natural = BrushTrail(
        id: "natural", name: "Plain dust", colour: RGB8(214, 198, 168)
    )
}
