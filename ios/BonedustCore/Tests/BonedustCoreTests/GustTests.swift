import XCTest
@testable import BonedustCore

/// Blowing on the slab.
///
/// The mechanic has to hold three properties or it is either a free win or a cheat vector:
/// it stops short of uncovering the fossil, it punishes being used late, and it is drawn
/// from the gameplay PRNG so it cannot be re-rolled by force-quitting.
final class GustTests: XCTestCase {

    private func slab(seed: UInt64 = 5) -> SlabSimulation {
        SlabSimulation(seed: seed, site: ContentCatalog.shared.site("charmouth")!)
    }

    func testAGustLiftsMaterialAcrossTheWholeSlab() {
        var sim = slab()
        let before = sim.grid.cells.reduce(0) { $0 + Int($1.depth) }
        let result = sim.gust(strength: 1)

        XCTAssertGreaterThan(result.patches, 0)
        XCTAssertGreaterThan(result.cellsLifted, 0)
        let after = sim.grid.cells.reduce(0) { $0 + Int($1.depth) }
        XCTAssertEqual(before - after, result.cellsLifted, "lifted cells should be one layer each")

        // Scattered, not local: the brush is local and breath is the opposite. Check the
        // change is spread over both halves rather than clustered in one place.
        let half = SlabGrid.height / 2
        var top = 0, bottom = 0
        for y in 0..<SlabGrid.height {
            for x in 0..<SlabGrid.width where sim.grid[x, y].depth < 3 {
                if y < half { top += 1 } else { bottom += 1 }
            }
        }
        XCTAssertGreaterThan(top, 0, "nothing lifted in the top half")
        XCTAssertGreaterThan(bottom, 0, "nothing lifted in the bottom half")
    }

    func testAGustNeverUncoversTheFossil() {
        var sim = slab()
        // Far more breath than anyone has.
        for _ in 0..<40 { sim.gust(strength: 1) }

        for i in 0..<sim.grid.cells.count where sim.grid.isBone(i) {
            XCTAssertGreaterThanOrEqual(
                sim.grid.cells[i].depth, SimTuning.standard.gustFloorDepth,
                "breath took a bone cell below the floor depth, so it can dig for you"
            )
        }
        XCTAssertEqual(sim.exposedBone, 0, "the fossil should still need brushing by hand")
    }

    func testBlowingOnBoneYouHaveAlreadyExposedCracksIt() {
        var sim = slab()
        // Open the fossil up first.
        var passes = 0
        while sim.exposedBone < 40, passes < 400 {
            let y = Float(2 + (passes * 3) % 124)
            sim.beginStroke(at: Vec2(2, y), tool: .brush)
            for x in stride(from: Float(2), through: 94, by: 0.9) {
                sim.moveStroke(to: Vec2(x, y), deltaMillis: 16.67, tool: .brush)
            }
            sim.endStroke()
            passes += 1
        }
        XCTAssertGreaterThan(sim.exposedBone, 0, "could not expose any bone to test with")

        let crackedBefore = sim.crackedBone
        // Enough attempts that a gust is bound to land on the exposed patch. Seven
        // patches at radius 5 cover a small share of a 96x128 slab, so a fixed handful of
        // blows is a coin flip rather than a test -- and the patch count is tuned against
        // play, so it will move again.
        var cracks = 0
        var blows = 0
        while cracks == 0, blows < 60 {
            cracks += sim.gust(strength: 1).cracksStarted
            blows += 1
        }
        XCTAssertGreaterThan(cracks, 0, "breath across an open slab did no damage at all")
        XCTAssertGreaterThan(sim.crackedBone, crackedBefore)
    }

    func testAGustIsDeterministicAndPartOfTheSaveState() {
        var a = slab()
        a.gust(strength: 0.6)
        // Both halves of the save, captured together and *before* the gust being
        // replayed. Reading the grid afterwards compares a replay against a slab that
        // has already had the gust applied, which is a different question.
        let savedGrid = a.grid
        let savedState = a.randomState
        let resultA = a.gust(strength: 0.8)

        // Restore exactly as RunStore would, then replay.
        var b = SlabSimulation(grid: savedGrid, layout: a.layout, randomState: savedState)
        XCTFail_ifDifferent(resultA, b.gust(strength: 0.8))
        XCTAssertEqual(a.randomState, b.randomState, "the PRNG diverged")
    }

    private func XCTFail_ifDifferent(
        _ expected: SlabSimulation.GustResult, _ actual: SlabSimulation.GustResult
    ) {
        XCTAssertEqual(
            expected, actual,
            "a restored slab rolled a different gust, so force-quitting re-rolls it"
        )
    }

    func testStrengthScalesTheGust() {
        func lifted(_ strength: Float) -> Int {
            var sim = slab()
            return sim.gust(strength: strength).cellsLifted
        }
        XCTAssertEqual(lifted(0), 0, "no breath, no gust")
        XCTAssertLessThan(lifted(0.25), lifted(1))
    }
}
