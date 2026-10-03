import XCTest
@testable import BonedustCore

final class MetricsTests: XCTestCase {

    func testExposureIsExposedBoneOverBone() {
        var (grid, layout) = TestSlab.boneBlock(size: (w: 10, h: 10), exposed: false)
        XCTAssertEqual(layout.boneCells, 100)
        // Expose exactly a quarter of it by hand.
        for y in 44..<49 {
            for x in 28..<33 {
                grid.cells[SlabGrid.index(x, y)].depth = 0
            }
        }
        let sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertEqual(sim.exposedBone, 25)
        XCTAssertEqual(sim.exposure, 0.25, accuracy: 0.0001)
        layout.boneCells = 0
        XCTAssertEqual(SlabSimulation(grid: grid, layout: layout).exposure, 0,
                       "a bone-free slab must not divide by zero")
    }

    func testIntactFormula() {
        var (grid, layout) = TestSlab.boneBlock(size: (w: 10, h: 10), exposed: true)
        func withCracked(_ count: Int) -> Float {
            var copy = grid
            var marked = 0
            outer: for y in 44..<54 {
                for x in 28..<38 {
                    guard marked < count else { break outer }
                    copy.cells[SlabGrid.index(x, y)].flags |= SlabGrid.Flag.cracked
                    marked += 1
                }
            }
            return SlabSimulation(grid: copy, layout: layout).intact
        }
        // intact = max(0, 1 - (cracked / bone) * intactCrackWeight), weight 5.
        XCTAssertEqual(withCracked(0), 1, accuracy: 0.0001)
        XCTAssertEqual(withCracked(10), 0.5, accuracy: 0.0001)
        XCTAssertEqual(withCracked(19), 0.05, accuracy: 0.0001)
        XCTAssertEqual(withCracked(20), 0, "a fifth cracked makes it worthless")
        XCTAssertEqual(withCracked(40), 0, "intact floors at zero")
        layout.boneCells = 0
        XCTAssertEqual(SlabSimulation(grid: grid, layout: layout).intact, 1)
    }

    func testIdentificationThreshold() {
        var (grid, layout) = TestSlab.boneBlock(size: (w: 10, h: 10), exposed: false)
        var sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertFalse(sim.isIdentified)
        for y in 44..<49 {
            for x in 28..<33 { grid.cells[SlabGrid.index(x, y)].depth = 0 }
        }
        sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertEqual(sim.exposure, 0.25, accuracy: 0.0001)
        XCTAssertTrue(sim.isIdentified, "identification is at >= 0.25 exposure")
        // Collector's eye drops the threshold.
        sim.tuning.identifyExposure = 0.10
        XCTAssertTrue(sim.isIdentified)
    }

    func testWholeGemsOnlyCountWhenAllFourCellsAreExposed() {
        var (grid, layout) = TestSlab.blank()
        let origin = SlabGrid.index(20, 30)
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            grid.cells[SlabGrid.index(20 + dx, 30 + dy)].flags |= SlabGrid.Flag.gem
        }
        layout.gemClusters = [origin]
        layout.boneCells = 1

        var sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertEqual(sim.wholeGems, 0)

        // Expose three of the four: still worth nothing.
        for (dx, dy) in [(0, 0), (1, 0), (0, 1)] {
            grid.cells[SlabGrid.index(20 + dx, 30 + dy)].depth = 0
        }
        sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertEqual(sim.exposedGemCells, 3)
        XCTAssertEqual(sim.wholeGems, 0, "a part-dug gem pays nothing")

        grid.cells[SlabGrid.index(21, 31)].depth = 0
        sim = SlabSimulation(grid: grid, layout: layout)
        XCTAssertEqual(sim.wholeGems, 1)
    }

    func testGemCompletionIsReportedOnTheStrokeThatFinishesIt() {
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        // Find a seed that actually places a gem, then dig the whole slab out and
        // check the completion event fires exactly as many times as there are gems.
        var seed: UInt64 = 0
        var found: (SlabGrid, SlabLayout)?
        while seed < 400 {
            let generated = SlabGenerator.generate(seed: seed, site: site)
            if !generated.layout.gemClusters.isEmpty {
                found = (generated.grid, generated.layout)
                break
            }
            seed += 1
        }
        guard let (grid, layout) = found else {
            return XCTFail("no seed in 400 produced a gem")
        }
        var sim = SlabSimulation(grid: grid, layout: layout)
        var completions = 0
        sim.beginStroke(at: Vec2(2, 2), tool: .airBlower)
        for pass in 0..<70 {
            for y in stride(from: Float(2), through: 125, by: 2) {
                let row = pass % 2 == 0
                    ? stride(from: Float(2), through: 93, by: 1.5)
                    : stride(from: Float(93), through: 2, by: -1.5)
                for x in row {
                    completions += sim.moveStroke(
                        to: Vec2(x, y), deltaMillis: 16.67, tool: .airBlower
                    ).gemsCompleted
                }
            }
            if sim.wholeGems == layout.gemClusters.count { break }
        }
        sim.endStroke()
        XCTAssertEqual(sim.wholeGems, layout.gemClusters.count, "did not fully clear the slab")
        XCTAssertEqual(completions, layout.gemClusters.count,
                       "gem completion events did not match gems")
    }

    func testRecountMatchesIncrementalCounters() {
        guard let site = ContentCatalog.shared.site("green_river") else { return XCTFail() }
        var sim = SlabSimulation(seed: 77, site: site)
        Trace.replay(Trace.scrub(samples: 400), on: &sim, tool: .airBlower)
        let incremental = (
            sim.exposedBone, sim.crackedBone, sim.exposedGemCells,
            sim.wholeGems, sim.rockCellsCleared
        )
        sim.recountMetrics()
        XCTAssertEqual(sim.exposedBone, incremental.0)
        XCTAssertEqual(sim.crackedBone, incremental.1)
        XCTAssertEqual(sim.exposedGemCells, incremental.2)
        XCTAssertEqual(sim.wholeGems, incremental.3)
        XCTAssertEqual(sim.rockCellsCleared, incremental.4)
    }

    func testExposureNeverExceedsOne() {
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        var sim = SlabSimulation(seed: 123, site: site)
        for _ in 0..<40 {
            Trace.replay(Trace.scrub(samples: 300, seed: 1), on: &sim, tool: .airBlower)
        }
        XCTAssertLessThanOrEqual(sim.exposure, 1)
        XCTAssertLessThanOrEqual(sim.exposedBone, sim.boneCells)
    }
}
