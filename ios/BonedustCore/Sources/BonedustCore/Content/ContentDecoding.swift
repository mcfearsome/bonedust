import Foundation

// Swift's synthesized `init(from:)` ignores property default values and demands
// every key, which would force the content JSON to spell out all eleven shape
// params for all nineteen fossils. These hand-written decoders make absent keys
// fall back to the defaults, so content files only state what differs.
//
// Encoding stays synthesized — `bonedust-tool dump-constants` and the golden tests
// want the full, explicit form.

// MARK: - Explicit coding keys
//
// Swift synthesizes `CodingKeys` only for code in the same file as the type
// declaration, and these decoders live here rather than next to the models. Naming
// the keys explicitly is better anyway: the content JSON's key names are a contract
// with `content.json` and with the Ruby port, not an accident of property naming.

extension RGB8 {
    public enum CodingKeys: String, CodingKey { case r, g, b }
}

extension SlabPalette {
    public enum CodingKeys: String, CodingKey {
        case topsoil, clay, sandstone, matrix, rock, bone, crackedBone, gem
    }
}

extension ShapeParams {
    public enum CodingKeys: String, CodingKey {
        case turns, growth, thickness, taperFrom, taperTo, bend, count, jitter, ribs, aspect
        case knobEnds
    }
}

extension FossilShapeSpec {
    public enum CodingKeys: String, CodingKey { case kind, spanCells, params }
}

extension Fossil {
    public enum CodingKeys: String, CodingKey {
        case id, name, period, formation, baseValue, shape
        case instancesMin, instancesMax, crackMultiplier, setID, note
    }
}

extension SiteModifiers {
    public enum CodingKeys: String, CodingKey {
        case maxDepth, extraRockNodules, crackMultiplier, daylightDelta
        case payoutMultiplier, extraInstances, lightLevel
    }
}

extension Site {
    public enum CodingKeys: String, CodingKey {
        case id, name, period, twist, unlock, fossilWeights, modifiers, palette
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension RGB8 {
    /// Accepts `[74, 52, 40]` as well as `{"r":74,"g":52,"b":40}`.
    public init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            let r = try array.decode(UInt8.self)
            let g = try array.decode(UInt8.self)
            let b = try array.decode(UInt8.self)
            self.init(r, g, b)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try c.decode(UInt8.self, forKey: .r),
            try c.decode(UInt8.self, forKey: .g),
            try c.decode(UInt8.self, forKey: .b)
        )
    }
}

extension SlabPalette {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SlabPalette()
        self.init()
        topsoil = try c.value(.topsoil, base.topsoil)
        clay = try c.value(.clay, base.clay)
        sandstone = try c.value(.sandstone, base.sandstone)
        matrix = try c.value(.matrix, base.matrix)
        rock = try c.value(.rock, base.rock)
        bone = try c.value(.bone, base.bone)
        crackedBone = try c.value(.crackedBone, base.crackedBone)
        gem = try c.value(.gem, base.gem)
    }
}

extension ShapeParams {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ShapeParams()
        self.init()
        turns = try c.value(.turns, base.turns)
        growth = try c.value(.growth, base.growth)
        thickness = try c.value(.thickness, base.thickness)
        taperFrom = try c.value(.taperFrom, base.taperFrom)
        knobEnds = try c.value(.knobEnds, base.knobEnds)
        taperTo = try c.value(.taperTo, base.taperTo)
        bend = try c.value(.bend, base.bend)
        count = try c.value(.count, base.count)
        jitter = try c.value(.jitter, base.jitter)
        ribs = try c.value(.ribs, base.ribs)
        aspect = try c.value(.aspect, base.aspect)
    }
}

extension FossilShapeSpec {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(Kind.self, forKey: .kind),
            spanCells: try c.decode(Float.self, forKey: .spanCells),
            params: try c.value(.params, ShapeParams())
        )
    }
}

extension Fossil {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            period: try c.decode(String.self, forKey: .period),
            formation: try c.decode(String.self, forKey: .formation),
            baseValue: try c.decode(Int.self, forKey: .baseValue),
            shape: try c.decode(FossilShapeSpec.self, forKey: .shape),
            instancesMin: try c.value(.instancesMin, 1),
            instancesMax: try c.value(.instancesMax, 1),
            crackMultiplier: try c.value(.crackMultiplier, 1),
            setID: try c.decodeIfPresent(String.self, forKey: .setID),
            note: try c.value(.note, "")
        )
    }
}

extension SiteModifiers {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SiteModifiers()
        self.init()
        maxDepth = try c.value(.maxDepth, base.maxDepth)
        extraRockNodules = try c.value(.extraRockNodules, base.extraRockNodules)
        crackMultiplier = try c.value(.crackMultiplier, base.crackMultiplier)
        daylightDelta = try c.value(.daylightDelta, base.daylightDelta)
        payoutMultiplier = try c.value(.payoutMultiplier, base.payoutMultiplier)
        extraInstances = try c.value(.extraInstances, base.extraInstances)
        lightLevel = try c.value(.lightLevel, base.lightLevel)
    }
}

extension SiteUnlock {
    /// `"start"`, `{"reputation": 200}`, or `{"crewMilestone": 250000}`.
    public init(from decoder: any Decoder) throws {
        if let flat = try? decoder.singleValueContainer().decode(String.self) {
            guard flat == "start" else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown unlock \(flat)"
                ))
            }
            self = .start
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        if let n = try c.decodeIfPresent(Int.self, forKey: .reputation) {
            self = .reputation(n)
        } else if let n = try c.decodeIfPresent(Int.self, forKey: .crewMilestone) {
            self = .crewMilestone(n)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "empty unlock"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .start:
            var c = encoder.singleValueContainer()
            try c.encode("start")
        case .reputation(let n):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(n, forKey: .reputation)
        case .crewMilestone(let n):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(n, forKey: .crewMilestone)
        }
    }

    private enum Keys: String, CodingKey {
        case reputation, crewMilestone
    }
}

extension Site {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            period: try c.decode(String.self, forKey: .period),
            twist: try c.value(.twist, ""),
            unlock: try c.decode(SiteUnlock.self, forKey: .unlock),
            fossilWeights: try c.decode([String: Int].self, forKey: .fossilWeights),
            modifiers: try c.value(.modifiers, SiteModifiers()),
            palette: try c.value(.palette, SlabPalette.standard)
        )
    }
}
