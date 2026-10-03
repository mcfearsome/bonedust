import Foundation

/// Places a shape in grid space: unit coords -> scaled -> rotated -> translated.
public struct ShapeTransform: Sendable, Equatable {
    /// Unit-space 1.0 becomes this many cells.
    public var scale: Float
    public var rotation: Float
    /// Where unit-space origin lands, in cells.
    public var center: Vec2

    public init(scale: Float, rotation: Float, center: Vec2) {
        self.scale = scale
        self.rotation = rotation
        self.center = center
    }

    @inline(__always)
    public func apply(_ p: Vec2) -> Vec2 {
        let s = sin(rotation), c = cos(rotation)
        let scaled = p * scale
        return Vec2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c) + center
    }
}

public enum ShapeRasterizer {

    /// Burns `primitives` into the grid as `flag`. Returns how many cells newly
    /// gained the flag, so generation can reject a fossil that landed mostly
    /// off-slab without counting cells twice.
    @discardableResult
    public static func rasterize(
        _ primitives: [ShapePrimitive],
        transform: ShapeTransform,
        flag: UInt8,
        into grid: inout SlabGrid
    ) -> Int {
        var newCells = 0
        for primitive in primitives {
            switch primitive {
            case .stroke(let vertices):
                stroke(vertices, transform, flag, &grid, &newCells)
            case .ellipse(let center, let radii, let rotation):
                ellipse(center, radii, rotation, transform, flag, &grid, &newCells)
            }
        }
        return newCells
    }

    private static func stroke(
        _ vertices: [(point: Vec2, halfWidth: Float)],
        _ transform: ShapeTransform,
        _ flag: UInt8,
        _ grid: inout SlabGrid,
        _ newCells: inout Int
    ) {
        guard !vertices.isEmpty else { return }
        guard vertices.count > 1 else {
            disc(transform.apply(vertices[0].point),
                 vertices[0].halfWidth * transform.scale, flag, &grid, &newCells)
            return
        }
        for i in 0..<(vertices.count - 1) {
            let a = transform.apply(vertices[i].point)
            let b = transform.apply(vertices[i + 1].point)
            let ra = vertices[i].halfWidth * transform.scale
            let rb = vertices[i + 1].halfWidth * transform.scale
            let length = (b - a).length
            // Half-cell steps: fine enough that consecutive discs always overlap,
            // even at the 0.55-cell minimum radius.
            let steps = max(1, Int((length / 0.5).rounded(.up)))
            for s in 0...steps {
                let t = Float(s) / Float(steps)
                disc(a + (b - a) * t, ra + (rb - ra) * t, flag, &grid, &newCells)
            }
        }
    }

    private static func ellipse(
        _ center: Vec2,
        _ radii: Vec2,
        _ rotation: Float,
        _ transform: ShapeTransform,
        _ flag: UInt8,
        _ grid: inout SlabGrid,
        _ newCells: inout Int
    ) {
        let c = transform.apply(center)
        let r = radii * transform.scale
        guard r.x > 0, r.y > 0 else { return }
        let theta = rotation + transform.rotation
        let st = sin(theta), ct = cos(theta)
        let extent = max(r.x, r.y) + 1
        // Clamp first, then bail. A shape whose bounding box is entirely off-slab
        // used to build an inverted range like `200...127` and trap — reachable with
        // a long fossil (the 112-cell Triceratops horn) rotated near a corner.
        let x0 = max(0, Int((c.x - extent).rounded(.down)))
        let x1 = min(SlabGrid.width - 1, Int((c.x + extent).rounded(.up)))
        let y0 = max(0, Int((c.y - extent).rounded(.down)))
        let y1 = min(SlabGrid.height - 1, Int((c.y + extent).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let d = Vec2(Float(x) + 0.5 - c.x, Float(y) + 0.5 - c.y)
                // Rotate the sample into the ellipse's own frame.
                let local = Vec2(d.x * ct + d.y * st, -d.x * st + d.y * ct)
                let q = (local.x * local.x) / (r.x * r.x) + (local.y * local.y) / (r.y * r.y)
                if q <= 1 { set(x, y, flag, &grid, &newCells) }
            }
        }
    }

    /// A filled disc. The cell containing the centre is always set, so a hairline
    /// stroke still produces a connected one-cell-wide line instead of dropouts.
    private static func disc(
        _ center: Vec2,
        _ radius: Float,
        _ flag: UInt8,
        _ grid: inout SlabGrid,
        _ newCells: inout Int
    ) {
        let r = max(0.55, radius)
        let cx = Int(center.x.rounded(.down)), cy = Int(center.y.rounded(.down))
        if SlabGrid.contains(cx, cy) { set(cx, cy, flag, &grid, &newCells) }
        let x0 = Int((center.x - r).rounded(.down)), x1 = Int((center.x + r).rounded(.up))
        let y0 = Int((center.y - r).rounded(.down)), y1 = Int((center.y + r).rounded(.up))
        let r2 = r * r
        var y = y0
        while y <= y1 {
            if y >= 0, y < SlabGrid.height {
                var x = x0
                while x <= x1 {
                    if x >= 0, x < SlabGrid.width {
                        let dx = Float(x) + 0.5 - center.x
                        let dy = Float(y) + 0.5 - center.y
                        if dx * dx + dy * dy <= r2 { set(x, y, flag, &grid, &newCells) }
                    }
                    x += 1
                }
            }
            y += 1
        }
    }

    @inline(__always)
    private static func set(
        _ x: Int, _ y: Int, _ flag: UInt8, _ grid: inout SlabGrid, _ newCells: inout Int
    ) {
        let i = SlabGrid.index(x, y)
        if grid.cells[i].flags & flag == 0 {
            grid.cells[i].flags |= flag
            newCells += 1
        }
    }
}

extension Vec2 {
    @inline(__always)
    var length: Float { (x * x + y * y).squareRoot() }
}
