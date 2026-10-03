/// A thing you drag across the slab. Starting values from §3.
public struct BrushTool: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Brush radius in cells.
    public var radius: Float
    /// Removal strength.
    public var strength: Float
    /// Multiplies the crack probability.
    public var crackMultiplier: Float
    /// Cells per frame you can move before bone starts breaking.
    public var safeSpeed: Float
    /// Shop price. Zero means it is the one you start with.
    public var price: Int

    public init(
        id: String, name: String, radius: Float, strength: Float,
        crackMultiplier: Float, safeSpeed: Float, price: Int = 0
    ) {
        self.id = id
        self.name = name
        self.radius = radius
        self.strength = strength
        self.crackMultiplier = crackMultiplier
        self.safeSpeed = safeSpeed
        self.price = price
    }

    public static let fineBrush = BrushTool(
        id: "fine_brush", name: "Fine brush",
        radius: 2.4, strength: 1.2, crackMultiplier: 0.35, safeSpeed: 2.2, price: 95
    )

    public static let brush = BrushTool(
        id: "brush", name: "Brush",
        radius: 4.2, strength: 1.4, crackMultiplier: 1.0, safeSpeed: 1.4, price: 0
    )

    public static let airBlower = BrushTool(
        id: "air_blower", name: "Air blower",
        radius: 7.5, strength: 1.8, crackMultiplier: 2.6, safeSpeed: 0.75, price: 140
    )

    public static let all: [BrushTool] = [fineBrush, brush, airBlower]
}
