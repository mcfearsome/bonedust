import XCTest
@testable import BonedustCore

final class RemovalTests: XCTestCase {

    /// Sweeps horizontally across the middle of the slab in one-cell samples.
    private func sweep(
        _ sim: inout SlabSimulation, tool: BrushTool,
        from x0: Float = 10, to x1: Float = 86, y: Float = 64,
        deltaMillis: Float = 16.67, passes: Int = 1
    ) {
        sim.beginStroke(at: Vec2(x0, y), tool: tool)
        for pass in 0..<passes {
            let forward = pass % 2 == 0
            let range = forward ? stride(from: x0, through: x1, by: 1)
                                : stride(from: x1, through: x0, by: -1)
            for x in range {
                sim.moveStroke(to: Vec2(x, y), deltaMillis: deltaMillis, tool: tool)
            }
        }
        sim.endStroke()
    }

    func testBrushingRemovesDepth() {
        var sim = TestSlab.simulation(TestSlab.blank())
        let before = sim.grid[48, 64].depth
        sweep(&sim, tool: .brush, passes: 2)
        XCTAssertLessThan(sim.grid[48, 64].depth, before)
    }

    func testEnoughBrushingReachesTheFloor() {
        var sim = TestSlab.simulation(TestSlab.blank())
        sweep(&sim, tool: .brush, passes: 40)
        XCTAssertEqual(sim.grid[48, 64].depth, 0)
        XCTAssertEqual(sim.grid[48, 64].wear, 0, "wear resets at the floor")
    }

    func testRemovalDependsOnDistanceNotTime() {
        // §3: "Removal depends on distance travelled, not time." The same path at a
        // tenth the frame rate must leave the slab in the same state.
        var slow = TestSlab.simulation(TestSlab.blank())
        var fast = TestSlab.simulation(TestSlab.blank())
        sweep(&slow, tool: .brush, deltaMillis: 160, passes: 3)
        sweep(&fast, tool: .brush, deltaMillis: 16, passes: 3)
        XCTAssertEqual(slow.grid.contentHash, fast.grid.contentHash)
    }

    func testAHeldFingerRemovesNothing() {
        var sim = TestSlab.simulation(TestSlab.blank())
        sim.beginStroke(at: Vec2(48, 64), tool: .brush)
        let hashAfterDab = sim.grid.contentHash
        for _ in 0..<120 {
            let result = sim.moveStroke(to: Vec2(48, 64), deltaMillis: 16.67, tool: .brush)
            XCTAssertEqual(result.cellsWorn, 0)
        }
        XCTAssertEqual(sim.grid.contentHash, hashAfterDab)
    }

    func testTouchDownDoesSomething() {
        // Removal being distance-based would otherwise make first contact inert.
        var sim = TestSlab.simulation(TestSlab.blank())
        let result = sim.beginStroke(at: Vec2(48, 64), tool: .brush)
        XCTAssertGreaterThan(result.cellsWorn, 0)
        XCTAssertGreaterThan(sim.grid[48, 64].wear, 0)
    }

    func testDeeperLayersAreHarder() {
        // Equal travel over a depth-1 slab clears more cells than over depth-3.
        func cleared(depth: UInt8) -> Int {
            var sim = TestSlab.simulation(TestSlab.blank(depth: depth))
            sweep(&sim, tool: .brush, passes: 6)
            return sim.grid.count { $0.depth < depth }
        }
        let shallow = cleared(depth: 1)
        let deep = cleared(depth: 3)
        XCTAssertGreaterThan(shallow, deep)
    }

    func testLayerHardnessRatiosMatchTheSpec() {
        // Hardness is [_, 1.0, 1.35, 1.7] and wear is divided by it, so measuring
        // accumulated wear for identical travel gives the ratios exactly. Counting
        // *strokes until a layer breaks* would quantise the answer to one stroke's
        // worth of wear, which at these magnitudes is a ten percent error.
        func wearAfterOneShortStroke(depth: UInt8) -> Float {
            var sim = TestSlab.simulation(TestSlab.blank(depth: depth))
            sim.beginStroke(at: Vec2(48, 64), tool: .fineBrush)
            sim.moveStroke(to: Vec2(48.5, 64), deltaMillis: 16.67, tool: .fineBrush)
            sim.endStroke()
            return sim.grid[48, 64].wear
        }
        let sandstone = wearAfterOneShortStroke(depth: 1)
        let clay = wearAfterOneShortStroke(depth: 2)
        let topsoil = wearAfterOneShortStroke(depth: 3)
        XCTAssertGreaterThan(sandstone, 0)
        XCTAssertLessThan(sandstone, 1, "the probe stroke must not break through")
        XCTAssertEqual(sandstone / clay, 1.35, accuracy: 0.001)
        XCTAssertEqual(sandstone / topsoil, 1.7, accuracy: 0.001)
    }

    func testRockMultipliesHardnessByThreePointTwo() {
        var (grid, layout) = TestSlab.blank(depth: 1)
        grid.cells[SlabGrid.index(48, 64)].flags |= SlabGrid.Flag.rock
        layout.rockCells = 1
        var sim = SlabSimulation(grid: grid, layout: layout)
        sim.beginStroke(at: Vec2(48, 64), tool: .fineBrush)
        sim.moveStroke(to: Vec2(48.5, 64), deltaMillis: 16.67, tool: .fineBrush)
        sim.endStroke()
        let rockWear = sim.grid[48, 64].wear

        var plain = TestSlab.simulation(TestSlab.blank(depth: 1))
        plain.beginStroke(at: Vec2(48, 64), tool: .fineBrush)
        plain.moveStroke(to: Vec2(48.5, 64), deltaMillis: 16.67, tool: .fineBrush)
        plain.endStroke()
        XCTAssertEqual(plain.grid[48, 64].wear / rockWear, 3.2, accuracy: 0.001)
    }

    func testRockTakesMorePassesThanMatrix() {
        // Counts passes for each rather than asserting rock survives *the* pass that
        // clears matrix. That weaker form held only while one pass delivered less than
        // 3.2x the wear a cell needed; doubling removalRate took both to one pass and the
        // test failed for a reason that had nothing to do with rock being hard.
        //
        // Full depth 3, so there is enough resolution to tell the two apart at all.
        func passesToClear(rock: Bool) -> Int {
            var (grid, layout) = TestSlab.blank(depth: 3)
            if rock {
                for y in 0..<SlabGrid.height {
                    for x in 0..<SlabGrid.width {
                        grid.cells[SlabGrid.index(x, y)].flags |= SlabGrid.Flag.rock
                    }
                }
                layout.rockCells = SlabGrid.width * SlabGrid.height
            }
            var sim = SlabSimulation(grid: grid, layout: layout)
            var passes = 0
            while sim.grid[48, 64].depth > 0, passes < 60 {
                sweep(&sim, tool: .brush, passes: 1)
                passes += 1
            }
            return passes
        }

        let matrix = passesToClear(rock: false)
        let rock = passesToClear(rock: true)
        XCTAssertLessThan(matrix, 60, "matrix never cleared")
        XCTAssertLessThan(rock, 60, "rock never cleared")
        XCTAssertGreaterThan(
            rock, matrix,
            "rock (\(rock) passes) is no harder to clear than plain matrix (\(matrix))"
        )
    }

    func testStrongerToolsRemoveMore() {
        func clearedCells(_ tool: BrushTool) -> Int {
            var sim = TestSlab.simulation(TestSlab.blank())
            sweep(&sim, tool: tool, passes: 4)
            return sim.grid.count { $0.depth < 3 }
        }
        XCTAssertLessThan(clearedCells(.fineBrush), clearedCells(.brush))
        XCTAssertLessThan(clearedCells(.brush), clearedCells(.airBlower))
    }

    func testFastFlickDoesNotTunnel() {
        // One enormous jump must be split into steps, leaving a continuous trench
        // rather than two dots. This is the `steps = ceil(dist / (r*0.35))` rule.
        var sim = TestSlab.simulation(TestSlab.blank())
        sim.beginStroke(at: Vec2(5, 64), tool: .brush)
        sim.moveStroke(to: Vec2(90, 64), deltaMillis: 16.67, tool: .brush)
        sim.endStroke()
        var gaps = 0
        for x in 6..<90 where sim.grid[x, 64].wear == 0 && sim.grid[x, 64].depth == 3 {
            gaps += 1
        }
        XCTAssertEqual(gaps, 0, "the brush skipped \(gaps) cells along the path")
    }

    func testBrushDoesNotWriteOutsideTheGrid() {
        // Corners and edges: a crash here would be an out-of-bounds write.
        var sim = TestSlab.simulation(TestSlab.blank())
        let corners: [Vec2] = [
            Vec2(0, 0), Vec2(95, 0), Vec2(0, 127), Vec2(95, 127),
            Vec2(-40, -40), Vec2(200, 200),
        ]
        sim.beginStroke(at: corners[0], tool: .airBlower)
        for corner in corners {
            sim.moveStroke(to: corner, deltaMillis: 16.67, tool: .airBlower)
        }
        sim.endStroke()
        XCTAssertEqual(sim.grid.cells.count, SlabGrid.cellCount)
    }

    func testDirtyRegionCoversWhatChanged() {
        var sim = TestSlab.simulation(TestSlab.blank())
        _ = sim.consumeDirty()
        sim.beginStroke(at: Vec2(40, 60), tool: .fineBrush)
        sim.moveStroke(to: Vec2(44, 60), deltaMillis: 16.67, tool: .fineBrush)
        sim.endStroke()
        let dirty = sim.consumeDirty()
        XCTAssertFalse(dirty.isEmpty)
        XCTAssertLessThanOrEqual(dirty.minX, 38)
        XCTAssertGreaterThanOrEqual(dirty.maxX, 46)
        XCTAssertTrue(sim.consumeDirty().isEmpty, "dirty region was not cleared")
    }

    func testDirtyRegionBoundsEveryChangedCell() {
        var sim = TestSlab.simulation(TestSlab.blank())
        let before = sim.grid
        _ = sim.consumeDirty()
        Trace.replay(Trace.scrub(samples: 80), on: &sim, tool: .brush)
        let dirty = sim.consumeDirty()
        for y in 0..<SlabGrid.height {
            for x in 0..<SlabGrid.width where before[x, y] != sim.grid[x, y] {
                XCTAssertTrue(
                    x >= dirty.minX && x <= dirty.maxX && y >= dirty.minY && y <= dirty.maxY,
                    "cell \(x),\(y) changed outside the dirty region"
                )
            }
        }
    }
}
