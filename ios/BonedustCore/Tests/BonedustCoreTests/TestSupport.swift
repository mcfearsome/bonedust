import Foundation
@testable import BonedustCore

/// Builders for slabs with known contents, so a test can assert on removal or
/// cracking without first having to reason about what the generator produced.
enum TestSlab {

    /// A slab of plain matrix at uniform depth, no bone, no rock, no gems.
    static func blank(depth: UInt8 = 3, seed: UInt64 = 1) -> (SlabGrid, SlabLayout) {
        var grid = SlabGrid()
        for i in 0..<SlabGrid.cellCount {
            grid.cells[i].depth = depth
        }
        let layout = SlabLayout(
            seed: seed, siteID: "test", fossilID: "test", instances: 1,
            boneCells: 0, rockCells: 0, gemClusters: [], maxDepth: depth
        )
        return (grid, layout)
    }

    /// A solid rectangle of bone. Big enough that a crack walk never runs out of
    /// neighbours, which is what lets the walk-length invariant be asserted.
    static func boneBlock(
        origin: (x: Int, y: Int) = (28, 44),
        size: (w: Int, h: Int) = (40, 40),
        depth: UInt8 = 3,
        exposed: Bool = false,
        seed: UInt64 = 7
    ) -> (SlabGrid, SlabLayout) {
        var (grid, _) = blank(depth: depth)
        var boneCells = 0
        for y in origin.y..<(origin.y + size.h) {
            for x in origin.x..<(origin.x + size.w) {
                let i = SlabGrid.index(x, y)
                grid.cells[i].flags |= SlabGrid.Flag.bone
                if exposed { grid.cells[i].depth = 0 }
                boneCells += 1
            }
        }
        let layout = SlabLayout(
            seed: seed, siteID: "test", fossilID: "test", instances: 1,
            boneCells: boneCells, rockCells: 0, gemClusters: [], maxDepth: depth
        )
        return (grid, layout)
    }

    static func simulation(
        _ built: (SlabGrid, SlabLayout), tuning: SimTuning = .standard
    ) -> SlabSimulation {
        SlabSimulation(grid: built.0, layout: built.1, tuning: tuning)
    }
}

extension SlabGrid {
    /// FNV-1a over every field of every cell. Two grids with the same hash are the
    /// same grid; used by the determinism and replay tests.
    var contentHash: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        for cell in cells {
            mix(cell.depth)
            mix(cell.flags)
            withUnsafeBytes(of: cell.wear) { for b in $0 { mix(b) } }
            withUnsafeBytes(of: cell.noise) { for b in $0 { mix(b) } }
        }
        return hash
    }
}

/// One recorded touch sample. §9 requires that replaying a trace reproduces the
/// result exactly, so the trace carries its own timing instead of reading a clock.
struct TraceSample {
    var point: Vec2
    var deltaMillis: Float
}

enum Trace {
    /// A deterministic, scripted scrub: back and forth across the slab, speeding up
    /// as it goes, so it covers both sides of every tool's safe speed.
    static func scrub(samples: Int = 240, seed: UInt64 = 0xBEEF) -> [TraceSample] {
        var rng = SplitMix64(seed: seed)
        var out: [TraceSample] = []
        out.reserveCapacity(samples)
        for i in 0..<samples {
            let t = Float(i)
            let speed = 0.5 + 6 * Float(i) / Float(samples)
            let x = 48 + sin(t * 0.21) * 30 * (speed / 3)
            let y = 64 + cos(t * 0.13) * 40
            out.append(TraceSample(
                point: Vec2(
                    min(max(x + rng.nextFloat(-1, 1), 1), Float(SlabGrid.width - 2)),
                    min(max(y + rng.nextFloat(-1, 1), 1), Float(SlabGrid.height - 2))
                ),
                deltaMillis: rng.nextFloat(14, 20)
            ))
        }
        return out
    }

    static func replay(
        _ trace: [TraceSample], on sim: inout SlabSimulation, tool: BrushTool
    ) {
        guard let first = trace.first else { return }
        sim.beginStroke(at: first.point, tool: tool)
        for sample in trace.dropFirst() {
            sim.moveStroke(to: sample.point, deltaMillis: sample.deltaMillis, tool: tool)
        }
        sim.endStroke()
    }
}
