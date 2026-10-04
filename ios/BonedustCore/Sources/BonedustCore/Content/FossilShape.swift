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
    /// Bulbous ends on a taper, as a fraction of its width. 0 leaves a plain cone.
    ///
    /// A tooth or a belemnite really is a smooth cone and should stay one. A rib, a jaw or
    /// a limb bone is not: it has epiphyses, and without them it rasterises to a featureless
    /// line -- reported from play as "just a single long thin bone, these fossils SUCK",
    /// which was a fair description of what the generator produced.
    public var knobEnds: Float = 0
    /// Discs: how much of a connected column they form. 0 scatters them, 1 stacks them.
    ///
    /// A crinoid stem, a vertebral column and a hadrosaur's tooth battery are *columns* —
    /// discs stacked touching, with an axis running through. Scattered, the same generator
    /// produces a handful of unconnected lumps that read as debris rather than a specimen,
    /// which is what "what is this supposed to be?" was looking at.
    ///
    /// Scattering is still right for some: ichthyosaur vertebrae really are found "like
    /// dropped coins", and fish scales really are strewn. So this is a knob rather than a
    /// fix applied everywhere.
    public var chain: Float = 0
    /// Taper: a flared root at the wide end, as a multiple of the shaft. 0 leaves a cone.
    ///
    /// A tooth is not a spike. It has a root that is wider than the crown and meets it at a
    /// shoulder, and that shoulder is the entire difference between "tooth" and "thorn" in
    /// a silhouette this small.
    public var root: Float = 0
    /// Discs: a process on each one, as a multiple of its radius. 0 leaves plain discs.
    ///
    /// Scattered discs read as spilled dots. A vertebra has a neural spine, and giving each
    /// disc one turns a scatter of coins into a scatter of recognisable *bones*.
    public var process: Float = 0

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
        // Silhouettes rather than primitives. See the Creatures section below.
        case skull           // theropod skull in profile
        case tail            // vertebrae, neural spines, chevrons
        case ribcage         // spine with ribs down both sides
        case wing            // pterosaur arm and membrane
        case foot            // three-toed foot with claws
        case vertebra        // one vertebra: centrum, arch, spine, processes
        case toothRow        // a jaw fragment with teeth still in it
        case skeleton        // part of an articulated animal
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
        case .skull: return Self.skull(params)
        case .tail: return Self.tail(params)
        case .ribcage: return Self.ribcage(params)
        case .wing: return Self.wing(params)
        case .foot: return Self.foot(params)
        case .vertebra: return Self.vertebra(params)
        case .toothRow: return Self.toothRow(params)
        case .skeleton: return Self.skeleton(params)
        }
    }

    // MARK: - Creatures
    //
    // Everything above this line is a parametric primitive -- a cone, a coil, a disc --
    // and none of them can ever read as an animal. Reported from play as "all i'm getting
    // are circles and rib bones and spirals", with a render of a Hell Creek slab that was
    // one curved stick to prove it.
    //
    // These are silhouettes instead: assembled from the same two primitives, but arranged
    // so the shape under the sandstone is recognisably a skull, a tail, a ribcage. At
    // 96x128 there is no room for detail, so each is built from a few bold masses and the
    // negative space between them does the work.

    /// A theropod skull in profile: cranium, snout, jaw, and a row of teeth.
    ///
    /// `ribs` is the tooth count, `aspect` the depth of the skull, `bend` how much the
    /// snout dips. The eye socket cannot be a hole -- the rasteriser only fills -- so it is
    /// implied by the notch between cranium and snout instead.
    private static func skull(_ p: ShapeParams) -> [ShapePrimitive] {
        // Grid y runs *down*, so negative y is toward the top of the slab. Getting this
        // backwards put the braincase under the jaw and the lower jaw above the upper one,
        // and the result read as a detached blob beside a comb.
        let depth = max(0.15, p.aspect)
        let bone = max(0.02, p.thickness)
        var out: [ShapePrimitive] = [
            // Braincase: one mass, small, entirely above the tooth row.
            .ellipse(center: Vec2(0.54, -depth * 0.95), radii: Vec2(0.26, depth * 0.55), rotation: 0),
            // The hinge, forward of the braincase so the two do not run together.
            .ellipse(center: Vec2(0.3, -depth * 0.1), radii: Vec2(0.07, depth * 0.3), rotation: 0),
        ]
        let steps = 22
        // Upper jaw: a bar running forward from the hinge, dipping by `bend`.
        var upper: [(Vec2, Float)] = []
        for i in 0...steps {
            let u = Float(i) / Float(steps)
            upper.append((
                Vec2(0.46 - 1.4 * u, -depth * 0.3 + p.bend * u * u),
                bone * (1.5 - 0.6 * u)
            ))
        }
        out.append(.stroke(vertices: upper))
        // Lower jaw, slung below it. The gap between the two is the only thing that says
        // "jaws" rather than "log", so it is widest at the hinge and closes toward the tip.
        var lower: [(Vec2, Float)] = []
        for i in 0...steps {
            let u = Float(i) / Float(steps)
            let gap = depth * 0.8 * (1 - 0.5 * u * u)
            lower.append((
                Vec2(0.34 - 1.24 * u, -depth * 0.3 + gap + p.bend * u * u * 0.7),
                bone * (1.1 - 0.45 * u)
            ))
        }
        out.append(.stroke(vertices: lower))
        // Teeth, hanging down into that gap from the upper jaw.
        let teeth = max(0, p.ribs)
        for i in 0..<teeth {
            let u = (Float(i) + 0.5) / Float(max(1, teeth))
            let x = 0.4 - 1.24 * u
            let y = -depth * 0.3 + p.bend * u * u + bone * (1.3 - 0.5 * u)
            out.append(.stroke(vertices: [
                (Vec2(x, y), bone * 0.55),
                (Vec2(x - 0.015, y + depth * 0.4 * (1 - 0.4 * u)), bone * 0.2),
            ]))
        }
        return out
    }

    /// A tail: vertebrae shrinking along a curve, with neural spines and chevrons.
    ///
    /// `count` is the vertebra count, `bend` the sweep. The spines are what stop it reading
    /// as a string of beads -- and they are thin, so a hurried brush shears them off and
    /// leaves exactly the string of beads it would have been.
    private static func tail(_ p: ShapeParams) -> [ShapePrimitive] {
        let n = max(4, p.count)
        var out: [ShapePrimitive] = []
        var spine: [(Vec2, Float)] = []
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let x = -1 + 2 * u
            let y = p.bend * (u * u - 0.25)
            let scale = 1 - 0.78 * u
            spine.append((Vec2(x, y), max(0.015, p.thickness * scale)))
            out.append(.ellipse(
                center: Vec2(x, y),
                radii: Vec2(p.thickness * 1.25 * scale, p.thickness * 1.6 * scale),
                rotation: 0
            ))
            // Neural spine up, chevron down. Both shrink toward the tip.
            let spineLength = p.aspect * scale
            out.append(.stroke(vertices: [
                (Vec2(x, y + p.thickness * scale), p.thickness * 0.42 * scale),
                (Vec2(x - 0.03, y + spineLength), p.thickness * 0.22 * scale),
            ]))
            if u < 0.75 {
                out.append(.stroke(vertices: [
                    (Vec2(x, y - p.thickness * scale), p.thickness * 0.34 * scale),
                    (Vec2(x - 0.02, y - spineLength * 0.62), p.thickness * 0.18 * scale),
                ]))
            }
        }
        out.insert(.stroke(vertices: spine), at: 0)
        return out
    }

    /// A ribcage: spine along the top with ribs hanging off both sides.
    ///
    /// The single most skeleton-looking thing available, and the ribs are thin enough that
    /// losing a few is the ordinary outcome of rushing.
    private static func ribcage(_ p: ShapeParams) -> [ShapePrimitive] {
        let n = max(4, p.ribs)
        var out: [ShapePrimitive] = [
            .stroke(vertices: [
                (Vec2(-1, p.aspect * 0.9), p.thickness * 1.1),
                (Vec2(0, p.aspect), p.thickness * 1.25),
                (Vec2(1, p.aspect * 0.82), p.thickness * 0.95),
            ])
        ]
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let x = -0.88 + 1.76 * u
            // Longest in the middle, like a chest.
            let length = p.aspect * (0.75 + 0.95 * sin(Float.pi * u))
            let top = p.aspect * (0.9 - 0.08 * u)
            for side in [Float(-1), 1] where side < 0 || p.bend > 0 {
                out.append(.stroke(vertices: [
                    (Vec2(x, top), p.thickness * 0.5),
                    (Vec2(x + side * 0.1, top - length * 0.55), p.thickness * 0.42),
                    (Vec2(x + side * 0.26, top - length), p.thickness * 0.3),
                ]))
            }
        }
        return out
    }

    /// A pterosaur wing: arm bones, then one enormous finger, with the membrane behind it.
    ///
    /// `ribs` is the number of membrane struts. The fourth finger being longer than the
    /// whole rest of the animal is the thing that makes a pterosaur read as a pterosaur.
    private static func wing(_ p: ShapeParams) -> [ShapePrimitive] {
        var out: [ShapePrimitive] = [
            .ellipse(center: Vec2(-0.86, -0.12), radii: Vec2(0.2, p.aspect * 0.7), rotation: 0)
        ]
        // Humerus, radius, metacarpal: three bones at angles, then the finger.
        let joints: [Vec2] = [
            Vec2(-0.78, -0.08), Vec2(-0.42, 0.16), Vec2(-0.02, 0.3), Vec2(0.52, 0.3),
            Vec2(0.98, 0.04),
        ]
        for i in 0..<(joints.count - 1) {
            let heft = p.thickness * (1.15 - 0.16 * Float(i))
            out.append(.stroke(vertices: [
                (joints[i], heft), (joints[i + 1], heft * 0.86),
            ]))
            if i < joints.count - 2 {
                out.append(.ellipse(
                    center: joints[i + 1],
                    radii: Vec2(heft * 1.5, heft * 1.5), rotation: 0
                ))
            }
        }
        // Trailing edge of the membrane, from the wingtip back to the body.
        out.append(.stroke(vertices: [
            (joints[joints.count - 1], p.thickness * 0.5),
            (Vec2(0.3, -0.52), p.thickness * 0.42),
            (Vec2(-0.5, -0.66), p.thickness * 0.42),
            (Vec2(-0.82, -0.3), p.thickness * 0.5),
        ]))
        // Struts across it, thin and the first thing to go.
        let struts = max(0, p.ribs)
        for i in 0..<struts {
            let u = (Float(i) + 0.5) / Float(max(1, struts))
            let a = Vec2(-0.5 + 1.4 * u, 0.3 - 0.24 * u * u)
            let b = Vec2(-0.6 + 1.1 * u, -0.6 + 0.2 * u)
            out.append(.stroke(vertices: [(a, p.thickness * 0.26), (b, p.thickness * 0.2)]))
        }
        return out
    }

    /// A three-toed foot with claws, pressed flat in the rock.
    private static func foot(_ p: ShapeParams) -> [ShapePrimitive] {
        var out: [ShapePrimitive] = [
            .ellipse(center: Vec2(0.52, 0), radii: Vec2(0.26, p.aspect * 0.9), rotation: 0)
        ]
        // Metatarsal going back out of frame.
        out.append(.stroke(vertices: [
            (Vec2(0.95, 0.04), p.thickness * 0.9), (Vec2(0.5, 0), p.thickness * 1.05),
        ]))
        let toes = max(2, min(4, p.count))
        for i in 0..<toes {
            let spread = (Float(i) / Float(toes - 1) - 0.5) * 2    // -1 to 1
            let tipY = spread * p.aspect * 1.9
            // Three phalanges and a claw, with a knuckle at each joint.
            let a = Vec2(0.42, spread * p.aspect * 0.4)
            let b = Vec2(0.02, tipY * 0.7)
            let c = Vec2(-0.44, tipY * 0.95)
            let claw = Vec2(-0.92, tipY * 1.05 - 0.12)
            out.append(.stroke(vertices: [
                (a, p.thickness * 0.78), (b, p.thickness * 0.66), (c, p.thickness * 0.5),
            ]))
            out.append(.ellipse(center: b, radii: Vec2(p.thickness * 0.9, p.thickness * 0.9), rotation: 0))
            out.append(.ellipse(center: c, radii: Vec2(p.thickness * 0.72, p.thickness * 0.72), rotation: 0))
            out.append(.stroke(vertices: [
                (c, p.thickness * 0.46), (claw, p.thickness * 0.16),
            ]))
        }
        return out
    }

    /// One vertebra, large: centrum, neural arch, spine, and transverse processes.
    ///
    /// A single vertebra drawn as a disc is a disc. Drawn with its processes it is
    /// unmistakable, and it is the one bone most people can name on sight.
    ///
    /// Grid y runs *down*, so negative y is toward the top of the slab.
    private static func vertebra(_ p: ShapeParams) -> [ShapePrimitive] {
        let body = max(0.1, p.thickness)
        let reach = max(0.2, p.aspect)
        var out: [ShapePrimitive] = [
            // Centrum: the spool the rest hangs off, dished at both ends.
            .ellipse(center: Vec2(0, 0.28), radii: Vec2(0.52, body * 1.5), rotation: 0),
            // Neural arch above it, with the canal implied by the waist between them.
            .ellipse(center: Vec2(0, -0.04), radii: Vec2(0.3, body * 0.9), rotation: 0),
        ]
        // Neural spine, tall and flat -- the part that makes it read as a vertebra and the
        // part a hurried brush takes off first.
        out.append(.stroke(vertices: [
            (Vec2(0, -0.06), body * 0.85),
            (Vec2(-0.04, -0.52 - reach * 0.4), body * 0.62),
            (Vec2(-0.06, -0.96), body * 0.34),
        ]))
        // Transverse processes, one each side, swept back.
        for side in [Float(-1), 1] {
            out.append(.stroke(vertices: [
                (Vec2(side * 0.16, -0.02), body * 0.6),
                (Vec2(side * 0.72, 0.1), body * 0.44),
                (Vec2(side * 1.0, 0.3), body * 0.24),
            ]))
        }
        // Zygapophyses: the little paired knuckles that join one vertebra to the next.
        for side in [Float(-1), 1] {
            out.append(.ellipse(
                center: Vec2(side * 0.3, -0.26), radii: Vec2(body * 0.5, body * 0.4),
                rotation: 0
            ))
        }
        return out
    }

    /// A chunk of jaw with the teeth still in it.
    ///
    /// A single tooth is a cone, and a cone drawn at 96x128 is a thorn. A jaw fragment is
    /// read instantly, and it gives the player several fragile things in one slab rather
    /// than one -- which is a better dig as well as a better silhouette.
    private static func toothRow(_ p: ShapeParams) -> [ShapePrimitive] {
        let bone = max(0.04, p.thickness)
        let n = max(2, p.ribs)
        // The jaw bone itself, slightly bowed.
        var jaw: [(Vec2, Float)] = []
        for i in 0...18 {
            let u = Float(i) / 18
            jaw.append((
                Vec2(-1 + 2 * u, -0.3 + p.bend * (u - 0.5) * (u - 0.5) * 4),
                bone * (1.7 - 0.3 * abs(u - 0.5) * 2)
            ))
        }
        var out: [ShapePrimitive] = [.stroke(vertices: jaw)]
        for i in 0..<n {
            let u = (Float(i) + 0.5) / Float(n)
            let x = -0.92 + 1.84 * u
            let top = -0.3 + p.bend * (u - 0.5) * (u - 0.5) * 4 + bone * 1.4
            // Crown down into the slab, with a visible gap to its neighbours. The gaps are
            // what make it a row of teeth instead of a saw blade.
            let length = p.aspect * (0.8 + 0.3 * sin(Float.pi * u))
            out.append(.stroke(vertices: [
                (Vec2(x, top), bone * 1.0),
                (Vec2(x + 0.02, top + length * 0.6), bone * 0.72),
                (Vec2(x + 0.04, top + length), bone * 0.16),
            ]))
        }
        return out
    }

    /// Part of an articulated animal: spine, ribs, a limb, and a stub of tail.
    ///
    /// The best thing a slab can hold. Everything about it is thin, so it is also the
    /// easiest to ruin -- which is the trade the whole game is about, made literal.
    private static func skeleton(_ p: ShapeParams) -> [ShapePrimitive] {
        let bone = max(0.03, p.thickness)
        let n = max(4, p.ribs)
        var out: [ShapePrimitive] = []
        // Spine, arcing across the slab.
        var spine: [(Vec2, Float)] = []
        for i in 0...24 {
            let u = Float(i) / 24
            spine.append((Vec2(-1 + 2 * u, -0.3 - p.bend * sin(Float.pi * u)), bone * 1.3))
        }
        out.append(.stroke(vertices: spine))
        // Ribs hanging off it, longest at the chest.
        for i in 0..<n {
            let u = (Float(i) + 0.5) / Float(n)
            let x = -0.75 + 1.3 * u
            let top = -0.3 - p.bend * sin(Float.pi * (0.125 + 0.65 * u))
            let length = p.aspect * (0.6 + sin(Float.pi * u))
            out.append(.stroke(vertices: [
                (Vec2(x, top), bone * 0.8),
                (Vec2(x + 0.06, top + length * 0.55), bone * 0.6),
                (Vec2(x + 0.16, top + length), bone * 0.36),
            ]))
        }
        // A limb, folded, off the shoulder.
        let shoulder = Vec2(-0.66, -0.26)
        let elbow = Vec2(-0.86, 0.26)
        let wrist = Vec2(-0.5, 0.52)
        out.append(.stroke(vertices: [(shoulder, bone * 1.2), (elbow, bone * 0.95)]))
        out.append(.stroke(vertices: [(elbow, bone * 0.95), (wrist, bone * 0.7)]))
        out.append(.ellipse(center: elbow, radii: Vec2(bone * 1.5, bone * 1.5), rotation: 0))
        for toe in 0..<3 {
            let spread = (Float(toe) - 1) * 0.22
            out.append(.stroke(vertices: [
                (wrist, bone * 0.55),
                (wrist + Vec2(0.16 + spread * 0.3, 0.22 + spread), bone * 0.2),
            ]))
        }
        // Skull at the far end, so there is no doubt what it was.
        out.append(.ellipse(center: Vec2(0.92, -0.28), radii: Vec2(0.16, bone * 2.6), rotation: 0))
        out.append(.stroke(vertices: [
            (Vec2(1.0, -0.24), bone * 1.5), (Vec2(0.62, -0.18), bone * 0.9),
        ]))
        return out
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
        if p.root > 0 {
            // Root flare at the wide end, set slightly behind the shaft so it reads as a
            // shoulder rather than a bulge, plus the hollow root cavity's outline.
            let r = max(0.02, p.taperFrom)
            return [
                .stroke(vertices: vertices),
                .ellipse(
                    center: Vec2(-0.86, p.bend * 0.06),
                    radii: Vec2(r * p.root * 0.9, r * p.root),
                    rotation: 0
                ),
                .ellipse(
                    center: Vec2(-0.99, p.bend * 0.02),
                    radii: Vec2(r * p.root * 0.55, r * p.root * 0.78),
                    rotation: 0
                ),
            ]
        }
        guard p.knobEnds > 0 else { return [.stroke(vertices: vertices)] }

        // Epiphyses. Sized off the shaft at each end rather than a constant, so a slender
        // rib gets slender knuckles and a femur gets heavy ones from the same number.
        let base = max(0.012, p.taperFrom)
        let tip = max(0.012, p.taperTo)
        return [
            .stroke(vertices: vertices),
            .ellipse(
                center: Vec2(-1, p.bend * 0),
                radii: Vec2(base * p.knobEnds * 1.1, base * p.knobEnds),
                rotation: 0
            ),
            .ellipse(
                center: Vec2(1, p.bend * 0),
                radii: Vec2(tip * p.knobEnds * 1.3, tip * p.knobEnds * 1.15),
                rotation: 0
            ),
        ]
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
        let chain = min(max(p.chain, 0), 1)
        var out: [ShapePrimitive] = []
        out.reserveCapacity(n)

        guard chain > 0 else {
            // Scattered: ichthyosaur vertebrae really are found like dropped coins, and
            // fish scales really are strewn.
            for i in 0..<n {
                let u = Float(i) / Float(n - 1)
                let wobble = sin(Float(i) * 2.399_963)   // golden-angle-ish, no PRNG
                let drift = sin(Float(i) * 1.713 + 0.6)
                let center = Vec2(-1 + 2 * u + p.jitter * wobble * 0.3, p.jitter * drift * 1.6)
                let r = p.thickness * (1 + p.jitter * wobble * 0.5)
                out.append(.ellipse(
                    center: center, radii: Vec2(r, r * 0.86), rotation: drift * 0.4
                ))
                guard p.process > 0 else { continue }
                // A neural spine, angled differently on each so they do not line up and
                // read as a comb. This is what makes scattered discs read as vertebrae
                // rather than as spilled coins.
                let angle = drift * 0.9 - 1.5
                out.append(.stroke(vertices: [
                    (center, r * 0.5),
                    (
                        center + Vec2(cos(angle), sin(angle)) * (r * p.process),
                        r * 0.22
                    ),
                ]))
            }
            return out
        }

        // A column: ossicles stacked along an axis, seen edge-on, with a groove between
        // each one. The grooves are the whole point -- every bone cell renders the same
        // colour, so segmentation has to be an absence of bone, exactly as it is for the
        // trilobite thorax below.
        //
        // The first attempt drew overlapping discs on a connecting stroke, which filled
        // every groove and produced one flat bar. Spacing is derived from the count so a
        // stem of 14 segments and one of 5 both read as segmented.
        let spacing = 2 / Float(n)
        let halfWidth = spacing * 0.36        // the rest of the spacing is the groove
        for i in 0..<n {
            let u = (Float(i) + 0.5) / Float(n)
            let wobble = sin(Float(i) * 2.399_963)
            let x = -1 + 2 * u
            let y = p.jitter * (1 - chain) * wobble * 1.2
            // Taper slightly toward one end, because a stem is not a cylinder.
            let height = p.thickness * (1 - 0.22 * u)
            out.append(.ellipse(
                center: Vec2(x, y), radii: Vec2(halfWidth, height), rotation: 0
            ))
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
