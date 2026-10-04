import Foundation

/// Everything about a slab that never changes once it is generated.
public struct SlabLayout: Sendable, Equatable {
    public var seed: UInt64
    public var siteID: String
    public var fossilID: String
    public var instances: Int
    public var boneCells: Int
    public var rockCells: Int
    /// Top-left cell index of each gem cluster, which is `tuning.gemSize` cells a side.
    public var gemClusters: [Int]
    public var maxDepth: UInt8

    public var gemCount: Int { gemClusters.count }
}

public enum SlabGenerator {

    /// Builds a slab from a seed. Deterministic: same seed, site and tuning always
    /// produce a byte-identical grid.
    ///
    /// The order of PRNG draws is part of the contract, because §6 requires Ruby to
    /// reproduce the bone, rock and gem counts from the same seed. The cosmetic
    /// noise field is drawn **last**, so the server can stop after gems and skip
    /// 12,288 draws it has no use for.
    public static func generate(
        seed: UInt64,
        site: Site,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) -> (grid: SlabGrid, layout: SlabLayout) {
        var rng = SplitMix64(seed: seed)
        var grid = SlabGrid()

        let maxDepth = min(3, max(1, site.modifiers.maxDepth))
        for i in 0..<SlabGrid.cellCount {
            grid.cells[i].depth = maxDepth
        }

        // 1. Fossil.
        let fossilID = pickFossil(&rng, site: site)
        let fossil = catalog.fossil(fossilID) ?? catalog.fossils[0]
        let instanceCount = rng.nextInt(
            fossil.instancesMin,
            through: max(fossil.instancesMin, fossil.instancesMax + site.modifiers.extraInstances)
        )
        let primitives = fossil.shape.expand()
        var boneCells = 0
        for _ in 0..<instanceCount {
            let transform = fossilTransform(&rng, fossil: fossil, tuning: tuning)
            boneCells += ShapeRasterizer.rasterize(
                primitives, transform: transform, flag: SlabGrid.Flag.bone, into: &grid
            )
        }
        // A fossil that clipped entirely off the slab would divide by zero in the
        // metrics. Cannot happen with the current spans and offsets, but one new
        // content entry with a big span and the guard earns its keep.
        if boneCells == 0 {
            let centered = ShapeTransform(
                scale: fossil.shape.spanCells / 2,
                rotation: 0,
                center: Vec2(Float(SlabGrid.width) / 2, Float(SlabGrid.height) / 2)
            )
            boneCells = ShapeRasterizer.rasterize(
                primitives, transform: centered, flag: SlabGrid.Flag.bone, into: &grid
            )
        }

        // 2. Rock nodules — only on non-bone cells.
        let nodules = rng.nextInt(
            tuning.rockNodulesMin,
            through: tuning.rockNodulesMax + site.modifiers.extraRockNodules
        )
        var rockCells = 0
        for _ in 0..<nodules {
            rockCells += placeNodule(&rng, tuning: tuning, into: &grid)
        }

        // 3. Gems — square clusters, clear of bone and rock.
        let gemCount = rng.nextInt(tuning.gemsMin, through: tuning.gemsMax)
        var gemClusters: [Int] = []
        for _ in 0..<gemCount {
            if let origin = placeGem(&rng, tuning: tuning, into: &grid) {
                gemClusters.append(origin)
            }
        }

        // 4. Cosmetic noise, last.
        for i in 0..<SlabGrid.cellCount {
            grid.cells[i].noise = rng.nextUnit() * 2 - 1
        }

        let layout = SlabLayout(
            seed: seed,
            siteID: site.id,
            fossilID: fossil.id,
            instances: instanceCount,
            boneCells: boneCells,
            rockCells: rockCells,
            gemClusters: gemClusters,
            maxDepth: maxDepth
        )
        return (grid, layout)
    }

    // MARK: - Steps

    private static func pickFossil(_ rng: inout SplitMix64, site: Site) -> String {
        let table = site.weightedTable
        guard !table.isEmpty else { return "" }
        let total = table.reduce(0) { $0 + $1.weight }
        var roll = rng.nextInt(below: total)
        for entry in table {
            roll -= entry.weight
            if roll < 0 { return entry.fossilID }
        }
        return table[table.count - 1].fossilID
    }

    private static func fossilTransform(
        _ rng: inout SplitMix64, fossil: Fossil, tuning: SimTuning
    ) -> ShapeTransform {
        let rotation = rng.nextFloat(-tuning.fossilRotation, tuning.fossilRotation)
        let scale = rng.nextFloat(tuning.fossilScaleMin, tuning.fossilScaleMax)
        let dx = rng.nextInt(-tuning.fossilOffsetX, through: tuning.fossilOffsetX)
        let dy = rng.nextInt(-tuning.fossilOffsetY, through: tuning.fossilOffsetY)
        return ShapeTransform(
            scale: fossil.shape.spanCells / 2 * scale,
            rotation: rotation,
            center: Vec2(
                Float(SlabGrid.width) / 2 + Float(dx),
                Float(SlabGrid.height) / 2 + Float(dy)
            )
        )
    }

    /// A noisy circle. Two sine harmonics with seeded phases give it a lumpy
    /// ironstone edge without needing a noise field.
    private static func placeNodule(
        _ rng: inout SplitMix64, tuning: SimTuning, into grid: inout SlabGrid
    ) -> Int {
        let radius = rng.nextFloat(tuning.rockRadiusMin, tuning.rockRadiusMax)
        let cx = rng.nextFloat(radius * 0.5, Float(SlabGrid.width) - radius * 0.5)
        let cy = rng.nextFloat(radius * 0.5, Float(SlabGrid.height) - radius * 0.5)
        let phase1 = rng.nextFloat(0, 2 * .pi)
        let phase2 = rng.nextFloat(0, 2 * .pi)

        var placed = 0
        let extent = Int((radius * 1.4).rounded(.up)) + 1
        let x0 = max(0, Int(cx) - extent), x1 = min(SlabGrid.width - 1, Int(cx) + extent)
        let y0 = max(0, Int(cy) - extent), y1 = min(SlabGrid.height - 1, Int(cy) + extent)
        guard x0 <= x1, y0 <= y1 else { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Float(x) + 0.5 - cx
                let dy = Float(y) + 0.5 - cy
                let dist = (dx * dx + dy * dy).squareRoot()
                guard dist > 0.0001 else {
                    let i = SlabGrid.index(x, y)
                    if grid.cells[i].flags & SlabGrid.Flag.bone == 0,
                       grid.cells[i].flags & SlabGrid.Flag.rock == 0 {
                        grid.cells[i].flags |= SlabGrid.Flag.rock
                        placed += 1
                    }
                    continue
                }
                let angle = atan2(dy, dx)
                let threshold = radius
                    * (1 + 0.22 * sin(3 * angle + phase1) + 0.13 * sin(5 * angle + phase2))
                guard dist <= threshold else { continue }
                let i = SlabGrid.index(x, y)
                guard grid.cells[i].flags & SlabGrid.Flag.bone == 0 else { continue }
                guard grid.cells[i].flags & SlabGrid.Flag.rock == 0 else { continue }
                grid.cells[i].flags |= SlabGrid.Flag.rock
                placed += 1
            }
        }
        return placed
    }

    /// A gem is a square cluster on clear ground, `tuning.gemSize` a side. Rock is excluded
    /// as well as bone: a gem buried under 3.2x hardness would cost more daylight than its
    /// $20 is worth, which makes it a trap rather than a reward.
    ///
    /// Two draws per attempt regardless of size, so the PRNG consumes the same amount
    /// whatever `gemSize` is and the draw order documented at the top of this file holds.
    private static func placeGem(
        _ rng: inout SplitMix64, tuning: SimTuning, into grid: inout SlabGrid
    ) -> Int? {
        let blocked = SlabGrid.Flag.bone | SlabGrid.Flag.rock | SlabGrid.Flag.gem
        let side = max(1, tuning.gemSize)
        for _ in 0..<tuning.gemPlacementAttempts {
            let x = rng.nextInt(1, through: SlabGrid.width - side - 1)
            let y = rng.nextInt(1, through: SlabGrid.height - side - 1)
            var indices: [Int] = []
            indices.reserveCapacity(side * side)
            for dy in 0..<side {
                for dx in 0..<side { indices.append(SlabGrid.index(x + dx, y + dy)) }
            }
            guard indices.allSatisfy({ grid.cells[$0].flags & blocked == 0 }) else { continue }
            for i in indices { grid.cells[i].flags |= SlabGrid.Flag.gem }
            return indices[0]
        }
        return nil
    }
}
