import XCTest
@testable import BonedustCore

final class CrackingTests: XCTestCase {

    /// Scrubs over exposed bone at a controlled speed, in cells per frame.
    private func scrubOverBone(
        _ sim: inout SlabSimulation, tool: BrushTool,
        cellsPerFrame: Float, samples: Int = 400
    ) -> (cracks: Int, cells: Int) {
        var cracks = 0, cells = 0
        var x: Float = 30
        var direction: Float = 1
        sim.beginStroke(at: Vec2(x, 64), tool: tool)
        for _ in 0..<samples {
            x += direction * cellsPerFrame
            if x > 66 { x = 66; direction = -1 }
            if x < 30 { x = 30; direction = 1 }
            let result = sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: tool)
            cracks += result.cracksStarted
            cells += result.cellsCracked
        }
        sim.endStroke()
        return (cracks, cells)
    }

    /// Covers the whole bone block rather than one band. Comparisons between
    /// modifier settings have to stay well away from saturation: once a band is
    /// fully cracked, a 35% higher crack rate produces the same number as a 0%
    /// higher one, and the test is measuring nothing.
    private func scrubArea(
        _ sim: inout SlabSimulation, tool: BrushTool,
        cellsPerFrame: Float, passes: Int = 1,
        area: (x0: Float, x1: Float, y0: Float, y1: Float) = (30, 66, 46, 82),
        rowStep: Float = 4
    ) -> (cracks: Int, cells: Int) {
        var cracks = 0, cells = 0
        sim.beginStroke(at: Vec2(area.x0, area.y0), tool: tool)
        for pass in 0..<passes {
            var y = area.y0
            var row = 0
            while y <= area.y1 {
                let forward = (row + pass) % 2 == 0
                let xs = forward
                    ? stride(from: area.x0, through: area.x1, by: cellsPerFrame)
                    : stride(from: area.x1, through: area.x0, by: -cellsPerFrame)
                for x in xs {
                    let result = sim.moveStroke(
                        to: Vec2(x, y), deltaMillis: 16.67, tool: tool
                    )
                    cracks += result.cracksStarted
                    cells += result.cellsCracked
                }
                y += rowStep
                row += 1
            }
        }
        sim.endStroke()
        return (cracks, cells)
    }

    /// Mean cracked cells over several independent gameplay seeds.
    private func meanCracked(
        tool: BrushTool = .brush, cellsPerFrame: Float = 3, passes: Int = 1,
        trials: Int = 16, configure: (inout SlabSimulation) -> Void = { _ in }
    ) -> Double {
        var total = 0
        for trial in 0..<trials {
            var sim = TestSlab.simulation(
                TestSlab.boneBlock(exposed: true, seed: UInt64(trial) * 7919 + 1)
            )
            configure(&sim)
            _ = scrubArea(&sim, tool: tool, cellsPerFrame: cellsPerFrame, passes: passes)
            total += sim.crackedBone
        }
        return Double(total) / Double(trials)
    }

    func testNoCracksBelowTheSafeSpeed() {
        // The brush is safe up to 1.4 cells/frame. At 0.4 the EMA never gets near it.
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        let result = scrubOverBone(&sim, tool: .brush, cellsPerFrame: 0.4, samples: 1_500)
        XCTAssertEqual(result.cracks, 0)
        XCTAssertEqual(sim.crackedBone, 0)
        XCTAssertEqual(sim.intact, 1)
    }

    func testCracksAppearAboveTheSafeSpeed() {
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        let result = scrubOverBone(&sim, tool: .brush, cellsPerFrame: 9, samples: 800)
        XCTAssertGreaterThan(result.cracks, 0)
        XCTAssertGreaterThan(sim.crackedBone, 0)
        XCTAssertLessThan(sim.intact, 1)
    }

    func testFirstCrackWalksBetweenThreeAndEightCells() {
        // The 3-8 range in §3 is only guaranteed for a walk in untouched bone. A
        // later walk can run into cells that are already cracked and stop short,
        // which is correct behaviour: the fracture merges into the existing one.
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        var x: Float = 32
        var direction: Float = 1
        var walkLength: Int?
        sim.beginStroke(at: Vec2(x, 64), tool: .brush)
        for _ in 0..<4_000 where walkLength == nil {
            x += direction * 4
            if x > 60 { x = 60; direction = -1 }
            if x < 32 { x = 32; direction = 1 }
            let result = sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .brush)
            if result.cracksStarted == 1 { walkLength = result.cellsCracked }
            else if result.cracksStarted > 1 { break }
        }
        sim.endStroke()
        guard let length = walkLength else {
            return XCTFail("never produced a single isolated crack")
        }
        XCTAssertGreaterThanOrEqual(length, SimTuning.standard.crackWalkMin)
        XCTAssertLessThanOrEqual(length, SimTuning.standard.crackWalkMax)
    }

    func testNoWalkEverExceedsTheMaximum() {
        // The upper bound holds unconditionally, saturated or not.
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        var x: Float = 32
        var direction: Float = 1
        sim.beginStroke(at: Vec2(x, 64), tool: .airBlower)
        for _ in 0..<800 {
            x += direction * 12
            if x > 60 { x = 60; direction = -1 }
            if x < 32 { x = 32; direction = 1 }
            let result = sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .airBlower)
            XCTAssertLessThanOrEqual(
                result.cellsCracked,
                SimTuning.standard.crackWalkMax * result.cracksStarted
            )
        }
        sim.endStroke()
        XCTAssertGreaterThan(sim.crackedBone, 0, "the test never actually cracked anything")
    }

    func testCrackedCellsAreAlwaysBone() {
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        _ = scrubOverBone(&sim, tool: .airBlower, cellsPerFrame: 14, samples: 600)
        XCTAssertGreaterThan(sim.crackedBone, 0)
        for cell in sim.grid.cells where cell.flags & SlabGrid.Flag.cracked != 0 {
            XCTAssertNotEqual(cell.flags & SlabGrid.Flag.bone, 0, "cracked a non-bone cell")
        }
    }

    func testCrackedCountMatchesTheGrid() {
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        _ = scrubOverBone(&sim, tool: .airBlower, cellsPerFrame: 14, samples: 400)
        let counted = sim.grid.count { $0.flags & SlabGrid.Flag.cracked != 0 }
        XCTAssertEqual(counted, sim.crackedBone, "incremental counter drifted from the grid")
    }

    func testFineBrushCracksLessThanTheAirBlower() {
        // ck is 0.35 vs 2.6, and vs is 2.2 vs 0.75, so at the same speed the blower
        // should be dramatically worse.
        func cracked(_ tool: BrushTool) -> Int {
            var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
            _ = scrubOverBone(&sim, tool: tool, cellsPerFrame: 6, samples: 600)
            return sim.crackedBone
        }
        let fine = cracked(.fineBrush)
        let blower = cracked(.airBlower)
        XCTAssertLessThan(fine, blower)
        XCTAssertGreaterThan(blower, fine * 3, "the blower is not scary enough")
    }

    func testSteadyHandsStyleModifierReducesCracks() {
        let plain = meanCracked()
        let steady = meanCracked { $0.safeSpeedMultiplier = 1.25 }
        XCTAssertLessThan(steady, plain * 0.95,
                          "steady hands \(steady) vs plain \(plain)")
    }

    func testSiteCrackMultiplierRaisesCracks() {
        let plain = meanCracked()
        let fragile = meanCracked { $0.crackMultiplier = 1.35 }
        XCTAssertGreaterThan(fragile, plain * 1.05,
                             "fragile \(fragile) vs plain \(plain)")
    }

    func testCrackingStaysFarFromSaturationInTheseTests() {
        // Guards the two comparisons above: if a tuning change pushes the scrub into
        // saturation they stop measuring anything, and this fails first with a clear
        // reason instead of them failing mysteriously.
        let mean = meanCracked()
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        XCTAssertGreaterThan(mean, 10, "too few cracks to compare: \(mean)")
        XCTAssertLessThan(mean, Double(sim.boneCells) * 0.5,
                          "scrub is saturating the block: \(mean) of \(sim.boneCells)")
        sim.endStroke()
    }

    func testCrackCanPropagateIntoBuriedBone() {
        // Deliberate, per DECISIONS.md: the walk crosses adjacent bone cells without
        // an exposure test, which is what makes the depth-1 bone tell matter.
        var sim = TestSlab.simulation(TestSlab.boneBlock(depth: 1, exposed: false))
        // Clear a narrow channel so some bone is exposed and the rest is buried.
        sim.beginStroke(at: Vec2(30, 64), tool: .brush)
        for x in stride(from: Float(30), through: 68, by: 0.5) {
            sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .brush)
        }
        for _ in 0..<60 {
            for x in stride(from: Float(68), through: 30, by: -0.5) {
                sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .brush)
            }
            for x in stride(from: Float(30), through: 68, by: 0.5) {
                sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .brush)
            }
        }
        // Now scrub fast to crack, and look for cracked cells that are still buried.
        _ = scrubOverBone(&sim, tool: .airBlower, cellsPerFrame: 16, samples: 400)
        let buriedCracked = sim.grid.cells.contains {
            $0.flags & SlabGrid.Flag.cracked != 0 && $0.depth > 0
        }
        XCTAssertTrue(buriedCracked, "cracks never reached buried bone")
    }

    func testACellOnlyCracksOnce() {
        var sim = TestSlab.simulation(TestSlab.boneBlock(exposed: true))
        var totalMarked = 0
        var x: Float = 32
        var direction: Float = 1
        sim.beginStroke(at: Vec2(x, 64), tool: .airBlower)
        for _ in 0..<2_000 {
            x += direction * 16
            if x > 62 { x = 62; direction = -1 }
            if x < 32 { x = 32; direction = 1 }
            totalMarked += sim.moveStroke(
                to: Vec2(x, 64), deltaMillis: 16.67, tool: .airBlower
            ).cellsCracked
        }
        sim.endStroke()
        XCTAssertEqual(totalMarked, sim.crackedBone, "a cell was cracked twice")
    }

    func testSpeedEmaRisesAndDecays() {
        var sim = TestSlab.simulation(TestSlab.blank())
        sim.beginStroke(at: Vec2(10, 64), tool: .brush)
        for x in stride(from: Float(10), through: 80, by: 5) {
            sim.moveStroke(to: Vec2(x, 64), deltaMillis: 16.67, tool: .brush)
        }
        let moving = sim.speed
        XCTAssertGreaterThan(moving, 2)
        sim.endStroke()
        sim.tickIdle(frames: 1)
        XCTAssertEqual(sim.speed, moving * SimTuning.standard.emaIdleDecay, accuracy: 0.001)
        sim.tickIdle(frames: 120)
        XCTAssertEqual(sim.speed, 0)
    }

    func testSpeedIsClampedAgainstFrameHitches() {
        // A dropped frame must not read as a flick and shatter the fossil.
        var sim = TestSlab.simulation(TestSlab.blank())
        sim.beginStroke(at: Vec2(5, 64), tool: .brush)
        sim.moveStroke(to: Vec2(90, 64), deltaMillis: 600, tool: .brush)
        XCTAssertLessThan(sim.speed, SimTuning.standard.maxSampleSpeed)
    }
}
