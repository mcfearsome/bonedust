import Foundation

/// Precomputed disc of cell offsets and falloff weights for one brush radius.
///
/// `f = 1 - d²/r²` is recomputed for every cell under the brush on every step, and
/// the air blower covers ~177 cells per step with up to a dozen steps per touch
/// event. Caching the disc turns that from a few thousand square roots per frame
/// into a flat array walk.
public struct BrushKernel: Sendable {
    public struct Offset: Sendable {
        public let dx: Int32
        public let dy: Int32
        public let falloff: Float
    }

    public let radius: Float
    public let offsets: [Offset]

    public init(radius: Float) {
        self.radius = radius
        let r = max(0.5, radius)
        let r2 = r * r
        let extent = Int(r.rounded(.up))
        var built: [Offset] = []
        built.reserveCapacity((2 * extent + 1) * (2 * extent + 1))
        for dy in -extent...extent {
            for dx in -extent...extent {
                let d2 = Float(dx * dx + dy * dy)
                guard d2 < r2 else { continue }
                built.append(Offset(dx: Int32(dx), dy: Int32(dy), falloff: 1 - d2 / r2))
            }
        }
        // Strongest cells first: unimportant for correctness, but it means the
        // centre of the brush is written while the cache line is hottest.
        self.offsets = built.sorted { $0.falloff > $1.falloff }
    }
}
