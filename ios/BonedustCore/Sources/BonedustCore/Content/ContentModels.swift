import Foundation

// MARK: - Colour

/// 8-bit RGB. Lives in Core, not the app, because §3 specifies the slab palette as
/// part of the simulation's visual contract — the renderer should be a dumb
/// consumer of these numbers, not a place where colour decisions get made.
public struct RGB8: Sendable, Codable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Linear interpolation in 8-bit space. Good enough at this chunk size, and it
    /// is what the prototype did; gamma-correct blending reads muddier here.
    public func lerp(to other: RGB8, _ t: Float) -> RGB8 {
        let k = min(max(t, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Float(a) + (Float(b) - Float(a)) * k).rounded())))
        }
        return RGB8(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }

    public func scaled(_ factor: Float) -> RGB8 {
        func s(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Float(v) * factor).rounded()))) }
        return RGB8(s(r), s(g), s(b))
    }
}

/// The slab's layer colours, from §3 Rendering.
public struct SlabPalette: Sendable, Codable, Equatable {
    public var topsoil = RGB8(74, 52, 40)
    public var clay = RGB8(136, 88, 57)
    public var sandstone = RGB8(196, 152, 104)
    public var matrix = RGB8(224, 203, 166)
    public var rock = RGB8(110, 106, 102)
    public var bone = RGB8(242, 233, 214)
    public var crackedBone = RGB8(112, 92, 74)
    public var gem = RGB8(70, 168, 190)

    public init() {}

    public static let standard = SlabPalette()

    /// Colour of a fully-cleared cell at the given depth, ignoring wear.
    public func layerColor(depth: UInt8) -> RGB8 {
        switch depth {
        case 3: return topsoil
        case 2: return clay
        case 1: return sandstone
        default: return matrix
        }
    }
}

// MARK: - Fossils

public struct Fossil: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var period: String
    public var formation: String
    public var baseValue: Int
    public var shape: FossilShapeSpec
    /// How many copies of this fossil can land on one slab.
    public var instancesMin: Int
    public var instancesMax: Int
    /// Multiplies the tool's crack multiplier. Thin, brittle species raise it.
    public var crackMultiplier: Float
    /// Which skeleton set this is a piece of, if any.
    public var setID: String?
    /// Flavour line for the specimen card.
    public var note: String

    public init(
        id: String, name: String, period: String, formation: String, baseValue: Int,
        shape: FossilShapeSpec, instancesMin: Int = 1, instancesMax: Int = 1,
        crackMultiplier: Float = 1, setID: String? = nil, note: String = ""
    ) {
        self.id = id
        self.name = name
        self.period = period
        self.formation = formation
        self.baseValue = baseValue
        self.shape = shape
        self.instancesMin = instancesMin
        self.instancesMax = instancesMax
        self.crackMultiplier = crackMultiplier
        self.setID = setID
        self.note = note
    }
}

// MARK: - Sites

public enum SiteUnlock: Sendable, Codable, Equatable {
    case start
    case reputation(Int)
    case crewMilestone(Int)

    public var label: String {
        switch self {
        case .start: return "Available"
        case .reputation(let n): return "Reputation \(n)"
        case .crewMilestone(let n): return "Crew debt $\(n / 1000)k"
        }
    }
}

/// A site's one twist, expressed as numbers the simulation already understands.
/// Everything here is a multiplier or a delta so that sites, charms and set perks
/// all compose through the same path instead of each becoming a special case.
public struct SiteModifiers: Sendable, Codable, Equatable {
    /// Wheeler's thin layers: the slab starts at depth 2 instead of 3.
    public var maxDepth: UInt8 = 3
    public var extraRockNodules: Int = 0
    public var crackMultiplier: Float = 1
    public var daylightDelta: Float = 0
    public var payoutMultiplier: Float = 1
    /// Added to a fossil's instance range, for "many small fossils per slab".
    public var extraInstances: Int = 0
    /// Night digs: the renderer dims everything by this much.
    public var lightLevel: Float = 1

    public init() {}

    /// The part of a site twist that behaves like a charm.
    ///
    /// `maxDepth`, `extraRockNodules` and `extraInstances` are generation-time inputs
    /// and stay out of this; everything else is a multiplier or a delta, so a site
    /// twist composes through exactly the same path as a charm or a set perk. That is
    /// what keeps "night dig + night owl + rush job" from needing a special case.
    public var modifierSet: ModifierSet {
        var set = ModifierSet()
        set.crackMultiplier = crackMultiplier
        set.daylightDelta = daylightDelta
        set.payoutMultiplier = payoutMultiplier
        return set
    }
}

public struct Site: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var period: String
    public var twist: String
    public var unlock: SiteUnlock
    /// Fossil id -> draw weight.
    public var fossilWeights: [String: Int]
    public var modifiers: SiteModifiers
    public var palette: SlabPalette

    public init(
        id: String, name: String, period: String, twist: String, unlock: SiteUnlock,
        fossilWeights: [String: Int], modifiers: SiteModifiers = SiteModifiers(),
        palette: SlabPalette = .standard
    ) {
        self.id = id
        self.name = name
        self.period = period
        self.twist = twist
        self.unlock = unlock
        self.fossilWeights = fossilWeights
        self.modifiers = modifiers
        self.palette = palette
    }

    /// Weights in a stable order. A dictionary has no defined iteration order, and
    /// generation must be reproducible, so the table is always sorted by fossil id
    /// before the seeded draw.
    public var weightedTable: [(fossilID: String, weight: Int)] {
        fossilWeights.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

// MARK: - Skeleton sets

public struct SetPerk: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case sitePayoutBonus
        case extraDaylight
        case crackReduction
        case gemBonus
    }

    public var label: String
    public var kind: Kind
    public var value: Float
    public var siteID: String?

    public init(label: String, kind: Kind, value: Float, siteID: String? = nil) {
        self.label = label
        self.kind = kind
        self.value = value
        self.siteID = siteID
    }
}

public struct SkeletonSet: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pieces: [String]
    public var perk: SetPerk
    public var reputationBonus: Int

    public init(id: String, name: String, pieces: [String], perk: SetPerk, reputationBonus: Int) {
        self.id = id
        self.name = name
        self.pieces = pieces
        self.perk = perk
        self.reputationBonus = reputationBonus
    }
}
