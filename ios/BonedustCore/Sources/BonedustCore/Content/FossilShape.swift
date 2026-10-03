import Foundation

public typealias Vec2 = SIMD2<Float>

/// What a shape spec expands into. Only two primitives, because both rasterise in
/// a handful of lines and both port to Ruby without a geometry library.
public enum ShapePrimitive: Sendable {
    /// A variable-width polyline. `vertices` pairs each point with the stroke
    /// half-width at that point; half-widths are interpolated along each segment.
    case stroke(vertices: [(point: Vec2, halfWidth: Float)])
    /// An axis-aligned-then-rotated filled ellipse.
    case ellipse(center: Vec2, radii: Vec2, rotation: Float)
}

/// Knobs a shape spec can set. Everything has a default, so the content JSON only
/// names what actually differs for that fossil.
public struct ShapeParams: Sendable, Codable, Equatable {
    /// Spiral: how many full turns the coil makes.
    public var turns: Float = 2.6
    /// Spiral: radius of the innermost whorl, as a fraction of the outer radius.
    public var growth: Float = 0.085
    /// General stroke heft, in unit-space half-widths.
    public var thickness: Float = 0.1
    /// Taper/crescent: half-width at the wide end.
    public var taperFrom: Float = 0.16
    /// Taper/crescent: half-width at the point.
    public var taperTo: Float = 0.015
    /// Taper: lateral bow. Crescent: arc sweep in radians.
    public var bend: Float = 0.22
    /// Discs/fan: how many repeats.
    public var count: Int = 7
    /// Discs: deterministic scatter amount. Not random — derived from the index so
    /// the shape is the same every time; the *placement* is what the seed varies.
    public var jitter: Float = 0.1
    /// Segmented bodies, fish, leaves: how many ribs or segments.
    public var ribs: Int = 9
    /// Height as a fraction of length, for spindle and blade bodies.
    public var aspect: Float = 0.34

    public init() {}
}

/// A fossil's outline, as data. Expands deterministically — no PRNG — so the Ruby
/// port in §6 can reproduce the identical bone mask from the same spec.
public struct FossilShapeSpec: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case spiral          // ammonite
        case taper           // belemnite, tooth, horn
        case crescent        // raptor claw
        case discs           // ichthyosaur vertebrae
        case segmentedBody   // trilobite
        case fan             // brachiopod
        case fish            // Knightia
        case leaf            // fossil leaf
    }

    public var kind: Kind
    /// How many cells 2.0 units of unit space maps to — the fossil's nominal
    /// long-axis extent before the per-slab scale jitter.
    public var spanCells: Float
    public var params: ShapeParams

    public init(kind: Kind, spanCells: Float, params: ShapeParams = ShapeParams()) {
        self.kind = kind
        self.spanCells = spanCells
        self.params = params
    }

    public func expand() -> [ShapePrimitive] {
        switch kind {
        case .spiral: return Self.spiral(params)
        case .taper: return Self.taper(params)
        case .crescent: return Self.crescent(params)
        case .discs: return Self.discs(params)
        case .segmentedBody: return Self.segmentedBody(params)
        case .fan: return Self.fan(params)
        case .fish: return Self.fish(params)
        case .leaf: return Self.leaf(params)
        }
    }

    // MARK: - Generators

    /// Logarithmic spiral ribbon. Half-width grows with radius so successive whorls
    /// almost touch, leaving a one-or-two-cell groove of matrix between them —
    /// which is what makes an ammonite read as an ammonite at 96x128.
    private static func spiral(_ p: ShapeParams) -> [ShapePrimitive] {
        let tMax = p.turns * 2 * .pi
        let r0 = max(0.02, p.growth)
        let steps = max(48, Int(p.turns * 48))
        var vertices: [(point: Vec2, halfWidth: Float)] = []
        vertices.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = tMax * Float(i) / Float(steps)
            let r = r0 * pow(1 / r0, t / tMax)
            let halfWidth = min(p.thickness, r * 0.3)
            vertices.append((Vec2(r * cos(t), r * sin(t)), max(0.012, halfWidth)))
        }
        return [
            .ellipse(center: .zero, radii: Vec2(repeating: r0 * 1.1), rotation: 0),
            .stroke(vertices: vertices),
        ]
    }

    /// A bowed cone: belemnite, tooth, horn. `bend` bows it sideways so a horn
    /// curves instead of reading as a traffic cone.
    private static func taper(_ p: ShapeParams) -> [ShapePrimitive] {
        let steps = 40
        var vertices: [(point: Vec2, halfWidth: Float)] = []
        vertices.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Float(i) / Float(steps)          // 0 at the base, 1 at the tip
            let x = -1 + 2 * u
            let y = p.bend * (1 - x * x)
            let halfWidth = p.taperFrom + (p.taperTo - p.taperFrom) * pow(u, 0.75)
            vertices.append((Vec2(x, y), max(0.012, halfWidth)))
        }
        return [.stroke(vertices: vertices)]
    }

    /// Circular arc with a taper: a claw. `bend` is the sweep in radians.
    private static func crescent(_ p: ShapeParams) -> [ShapePrimitive] {
        let steps = 36
        let sweep = max(0.4, p.bend)
        var vertices: [(point: Vec2, halfWidth: Float)] = []
        vertices.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Float(i) / Float(steps)
            let a = -sweep / 2 + sweep * u
            let point = Vec2(sin(a) * 1.15, cos(a) * 1.15 - 0.72)
            let halfWidth = p.taperFrom + (p.taperTo - p.taperFrom) * pow(u, 0.8)
            vertices.append((point, max(0.012, halfWidth)))
        }
        return [.stroke(vertices: vertices)]
    }

    /// A broken string of vertebrae. The scatter is a fixed function of the index,
    /// not a PRNG draw, so the species silhouette is stable and only the slab
    /// transform varies.
    private static func discs(_ p: ShapeParams) -> [ShapePrimitive] {
        let n = max(2, p.count)
        var out: [ShapePrimitive] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let wobble = sin(Float(i) * 2.399_963)      // golden-angle-ish, no PRNG
            let drift = sin(Float(i) * 1.713 + 0.6)
            let center = Vec2(-1 + 2 * u + p.jitter * wobble * 0.3, p.jitter * drift * 1.6)
            let r = p.thickness * (1 + p.jitter * wobble * 0.5)
            out.append(.ellipse(center: center, radii: Vec2(r, r * 0.86), rotation: drift * 0.4))
        }
        return out
    }

    /// Trilobite: cephalon, a ribbed thorax, and a pygidium. The thorax is separate
    /// transverse strokes with matrix gaps between them, because every bone cell
    /// renders the same colour — segmentation has to be an absence of bone.
    private static func segmentedBody(_ p: ShapeParams) -> [ShapePrimitive] {
        var out: [ShapePrimitive] = [
            .ellipse(center: Vec2(-0.72, 0), radii: Vec2(0.3, p.aspect * 1.25), rotation: 0),
            .ellipse(center: Vec2(0.8, 0), radii: Vec2(0.22, p.aspect * 0.78), rotation: 0),
        ]
        let n = max(3, p.ribs)
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let x = -0.4 + 1.02 * u
            let halfHeight = p.aspect * (1.15 - 0.45 * u)
            out.append(.stroke(vertices: [
                (Vec2(x, -halfHeight), p.thickness),
                (Vec2(x, halfHeight), p.thickness),
            ]))
        }
        return out
    }

    /// Brachiopod: a ribbed shell fanning out from a hinge.
    private static func fan(_ p: ShapeParams) -> [ShapePrimitive] {
        let hinge = Vec2(0, -0.85)
        var out: [ShapePrimitive] = []
        let n = max(3, p.ribs)
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let a = -0.85 + 1.7 * u
            let tip = hinge + Vec2(sin(a) * 1.5, cos(a) * 1.6)
            out.append(.stroke(vertices: [(hinge, p.thickness * 0.8), (tip, p.thickness)]))
        }
        // Outer margin, so the shell has an edge rather than looking like a comb.
        var margin: [(point: Vec2, halfWidth: Float)] = []
        for i in 0...24 {
            let a = -0.85 + 1.7 * Float(i) / 24
            margin.append((hinge + Vec2(sin(a) * 1.5, cos(a) * 1.6), p.thickness))
        }
        out.append(.stroke(vertices: margin))
        return out
    }

    /// Knightia: spindle body, forked tail, and fine ribs. The ribs are one cell
    /// wide, which is exactly why this fossil is crack-prone — few bone cells, so
    /// each cracked cell costs a lot of `intact`.
    private static func fish(_ p: ShapeParams) -> [ShapePrimitive] {
        var out: [ShapePrimitive] = [
            .ellipse(center: Vec2(-0.1, 0), radii: Vec2(0.78, p.aspect), rotation: 0)
        ]
        // Forked tail.
        out.append(.stroke(vertices: [
            (Vec2(0.62, 0), p.thickness * 0.7),
            (Vec2(1.0, p.aspect * 1.5), p.thickness * 0.6),
        ]))
        out.append(.stroke(vertices: [
            (Vec2(0.62, 0), p.thickness * 0.7),
            (Vec2(1.0, -p.aspect * 1.5), p.thickness * 0.6),
        ]))
        let n = max(3, p.ribs)
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let x = -0.78 + 1.3 * u
            let bodyHalf = p.aspect * sqrt(max(0, 1 - pow((x + 0.1) / 0.78, 2)))
            guard bodyHalf > 0.02 else { continue }
            out.append(.stroke(vertices: [
                (Vec2(x, -bodyHalf * 1.25), p.thickness * 0.4),
                (Vec2(x, bodyHalf * 1.25), p.thickness * 0.4),
            ]))
        }
        return out
    }

    /// Leaf blade with a midrib and angled veins. Deliberately the thinnest shape
    /// in the game.
    private static func leaf(_ p: ShapeParams) -> [ShapePrimitive] {
        var out: [ShapePrimitive] = [
            .ellipse(center: .zero, radii: Vec2(0.92, p.aspect), rotation: 0)
        ]
        out.append(.stroke(vertices: [
            (Vec2(-1, 0), p.thickness * 0.5),
            (Vec2(1, 0), p.thickness * 0.35),
        ]))
        let n = max(2, p.ribs)
        for i in 0..<n {
            let u = (Float(i) + 0.5) / Float(n)
            let x = -0.85 + 1.6 * u
            let half = p.aspect * sqrt(max(0, 1 - x * x / 0.92 / 0.92))
            for sign in [Float(-1), Float(1)] {
                out.append(.stroke(vertices: [
                    (Vec2(x, 0), p.thickness * 0.3),
                    (Vec2(x + 0.16, sign * half * 0.92), p.thickness * 0.25),
                ]))
            }
        }
        return out
    }
}
