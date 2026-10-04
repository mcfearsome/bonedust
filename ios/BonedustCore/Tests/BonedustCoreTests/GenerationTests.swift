import XCTest
@testable import BonedustCore

final class GenerationTests: XCTestCase {

    private var sites: [Site] { ContentCatalog.shared.sites }

    func testSameSeedProducesIdenticalSlab() {
        for site in sites {
            let seeds: [UInt64] = [1, 42, 999_999, UInt64.max / 3]
            for seed in seeds {
                let a = SlabGenerator.generate(seed: seed, site: site)
                let b = SlabGenerator.generate(seed: seed, site: site)
                XCTAssertEqual(a.grid.contentHash, b.grid.contentHash,
                               "\(site.id) seed \(seed) grid differed")
                XCTAssertEqual(a.layout, b.layout)
            }
        }
    }

    func testDifferentSeedsProduceDifferentSlabs() {
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        var hashes = Set<UInt64>()
        for seed in UInt64(0)..<60 {
            hashes.insert(SlabGenerator.generate(seed: seed, site: site).grid.contentHash)
        }
        XCTAssertEqual(hashes.count, 60, "seeds collided")
    }

    func testEverySlabHasBone() {
        // exposure and intact both divide by boneCells.
        for site in sites {
            for seed in UInt64(0)..<120 {
                let (_, layout) = SlabGenerator.generate(seed: seed, site: site)
                XCTAssertGreaterThan(layout.boneCells, 0, "\(site.id) seed \(seed)")
            }
        }
    }

    func testBoneCountMatchesTheGrid() {
        for site in sites {
            for seed in UInt64(0)..<30 {
                let (grid, layout) = SlabGenerator.generate(seed: seed, site: site)
                let counted = grid.count { $0.flags & SlabGrid.Flag.bone != 0 }
                XCTAssertEqual(counted, layout.boneCells, "\(site.id) seed \(seed)")
                let rock = grid.count { $0.flags & SlabGrid.Flag.rock != 0 }
                XCTAssertEqual(rock, layout.rockCells)
            }
        }
    }

    func testRockNeverSitsOnBone() {
        for site in sites {
            for seed in UInt64(0)..<40 {
                let (grid, _) = SlabGenerator.generate(seed: seed, site: site)
                for cell in grid.cells {
                    let bone = cell.flags & SlabGrid.Flag.bone != 0
                    let rock = cell.flags & SlabGrid.Flag.rock != 0
                    XCTAssertFalse(bone && rock, "\(site.id) seed \(seed): rock on bone")
                }
            }
        }
    }

    /// Gem size is read from the tuning rather than written in, because it has moved once
    /// already: a 2x2 gem on a 96x128 slab is four pixels on a phone, smaller than the
    /// matrix noise around it, which is not something a player spots and decides to go
    /// carefully around.
    func testGemsAreWholeSquareClustersOnClearGround() {
        let side = SimTuning.standard.gemSize
        for site in sites {
            for seed in UInt64(0)..<40 {
                let (grid, layout) = SlabGenerator.generate(seed: seed, site: site)
                XCTAssertLessThanOrEqual(layout.gemClusters.count, SimTuning.standard.gemsMax)
                let gemCells = grid.count { $0.flags & SlabGrid.Flag.gem != 0 }
                XCTAssertEqual(gemCells, layout.gemClusters.count * side * side,
                               "\(site.id) seed \(seed): gem cells are not whole clusters")
                for origin in layout.gemClusters {
                    let x = origin % SlabGrid.width
                    let y = origin / SlabGrid.width
                    for (dx, dy) in (0..<side).flatMap({ dy in (0..<side).map { ($0, dy) } }) {
                        let cell = grid[x + dx, y + dy]
                        XCTAssertNotEqual(cell.flags & SlabGrid.Flag.gem, 0)
                        XCTAssertEqual(cell.flags & SlabGrid.Flag.bone, 0, "gem on bone")
                        XCTAssertEqual(cell.flags & SlabGrid.Flag.rock, 0, "gem in rock")
                    }
                }
            }
        }
    }

    func testRockNoduleCountIsInRange() {
        let tuning = SimTuning.standard
        for site in sites {
            // Nodules can overlap and clip, so assert on area rather than count:
            // somewhere between one minimum nodule and every nodule at max radius.
            let maxNodules = tuning.rockNodulesMax + site.modifiers.extraRockNodules
            let ceiling = Int(Double(maxNodules) * Double.pi * pow(Double(tuning.rockRadiusMax) * 1.4, 2))
            for seed in UInt64(0)..<30 {
                let (_, layout) = SlabGenerator.generate(seed: seed, site: site)
                XCTAssertGreaterThan(layout.rockCells, 0, "\(site.id) seed \(seed): no rock at all")
                XCTAssertLessThan(layout.rockCells, ceiling)
            }
        }
    }

    func testWheelerStartsAtDepthTwo() {
        guard let wheeler = ContentCatalog.shared.site("wheeler") else { return XCTFail() }
        let (grid, layout) = SlabGenerator.generate(seed: 5, site: wheeler)
        XCTAssertEqual(layout.maxDepth, 2)
        XCTAssertTrue(grid.cells.allSatisfy { $0.depth <= 2 })
    }

    func testWheelerPlacesMoreInstances() {
        guard let wheeler = ContentCatalog.shared.site("wheeler"),
              let charmouth = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        func averageInstances(_ site: Site) -> Double {
            let total = (UInt64(0)..<80).reduce(0) { sum, seed in
                sum + SlabGenerator.generate(seed: seed, site: site).layout.instances
            }
            return Double(total) / 80
        }
        XCTAssertGreaterThan(averageInstances(wheeler), averageInstances(charmouth))
    }

    func testFossilIsAlwaysDrawnFromTheSiteTable() {
        for site in sites {
            let allowed = Set(site.fossilWeights.keys)
            for seed in UInt64(0)..<60 {
                let (_, layout) = SlabGenerator.generate(seed: seed, site: site)
                XCTAssertTrue(allowed.contains(layout.fossilID),
                              "\(site.id) produced \(layout.fossilID)")
            }
        }
    }

    func testFossilDrawRespectsWeights() {
        // Ammonite is weighted 30 of 100 at Charmouth; over 2000 slabs it should be
        // the most common find there.
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        var counts: [String: Int] = [:]
        for seed in UInt64(0)..<2_000 {
            let id = SlabGenerator.generate(seed: seed, site: site).layout.fossilID
            counts[id, default: 0] += 1
        }
        XCTAssertEqual(counts.max { $0.value < $1.value }?.key, "ammonite")
        XCTAssertEqual(Set(counts.keys), Set(site.fossilWeights.keys), "a fossil never appeared")
    }

    func testNoiseFieldIsFilledAndBounded() {
        let (grid, _) = SlabGenerator.generate(seed: 11, site: sites[0])
        XCTAssertTrue(grid.cells.allSatisfy { $0.noise >= -1 && $0.noise <= 1 })
        XCTAssertTrue(grid.cells.contains { $0.noise > 0.5 })
        XCTAssertTrue(grid.cells.contains { $0.noise < -0.5 })
    }

    func testEverythingStartsBuried() {
        for site in sites {
            let (grid, layout) = SlabGenerator.generate(seed: 3, site: site)
            XCTAssertTrue(grid.cells.allSatisfy { $0.depth == layout.maxDepth })
            XCTAssertTrue(grid.cells.allSatisfy { $0.wear == 0 })
            XCTAssertTrue(grid.cells.allSatisfy { $0.flags & SlabGrid.Flag.cracked == 0 })
        }
    }
}
