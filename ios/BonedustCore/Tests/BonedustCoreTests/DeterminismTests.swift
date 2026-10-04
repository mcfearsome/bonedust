import XCTest
@testable import BonedustCore

/// §9: "Simulation fully deterministic: same seed + same input trace gives the same
/// result. Add a test that replays a recorded input trace."
final class DeterminismTests: XCTestCase {

    func testReplayingATraceGivesAnIdenticalSlab() {
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        let trace = Trace.scrub(samples: 500)

        func run() -> (UInt64, Int, Int, Int, Float) {
            var sim = SlabSimulation(seed: 0xDEAD_BEEF, site: site)
            Trace.replay(trace, on: &sim, tool: .brush)
            return (sim.grid.contentHash, sim.exposedBone, sim.crackedBone,
                    sim.wholeGems, sim.speed)
        }

        let first = run()
        for _ in 0..<5 {
            let next = run()
            XCTAssertEqual(next.0, first.0, "grid diverged")
            XCTAssertEqual(next.1, first.1, "exposed bone diverged")
            XCTAssertEqual(next.2, first.2, "cracked bone diverged")
            XCTAssertEqual(next.3, first.3, "whole gems diverged")
            XCTAssertEqual(next.4, first.4, "speed diverged")
        }
    }

    func testTraceActuallyExercisesCrackingAndRemoval() {
        // A determinism test over a trace that does nothing would pass forever.
        guard let site = ContentCatalog.shared.site("green_river") else { return XCTFail() }
        var sim = SlabSimulation(seed: 4, site: site)
        Trace.replay(Trace.scrub(samples: 500), on: &sim, tool: .airBlower)
        XCTAssertGreaterThan(sim.exposedBone, 0, "trace exposed no bone")
        XCTAssertGreaterThan(sim.crackedBone, 0, "trace cracked nothing")
        XCTAssertGreaterThan(sim.speed, 0)
    }

    func testTwoToolsOnTheSameTraceDiverge() {
        // Guards against the tool being accidentally ignored, which would make every
        // other determinism assertion vacuous.
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        let trace = Trace.scrub(samples: 300)
        var a = SlabSimulation(seed: 9, site: site)
        var b = SlabSimulation(seed: 9, site: site)
        Trace.replay(trace, on: &a, tool: .fineBrush)
        Trace.replay(trace, on: &b, tool: .airBlower)
        XCTAssertNotEqual(a.grid.contentHash, b.grid.contentHash)
    }

    func testGameplayAndGenerationStreamsAreIndependent() {
        // Cracking draws from a forked stream. If it shared the generation stream,
        // the grid produced by brushing would depend on how many draws generation
        // happened to make, and any content edit would silently change every replay.
        let gameplay = SlabSimulation.gameplaySeed(from: 12345)
        XCTAssertNotEqual(gameplay, 12345)
        XCTAssertEqual(SlabSimulation.gameplaySeed(from: 12345), gameplay, "must be stable")
    }

    func testSerialisedSlabRestoresIdentically() {
        // §5 requires restoring a slab mid-dig from autosave with daylight paused.
        // The restored sim must agree with the live one on every metric *and* carry
        // on identically, which is why randomState is part of the saved state.
        guard let site = ContentCatalog.shared.site("hell_creek") else { return XCTFail() }
        var live = SlabSimulation(seed: 31, site: site)
        Trace.replay(Trace.scrub(samples: 250), on: &live, tool: .brush)

        var restored = SlabSimulation(
            grid: live.grid, layout: live.layout, tuning: live.tuning,
            randomState: live.randomState
        )
        restored.crackMultiplier = live.crackMultiplier
        XCTAssertEqual(restored.grid.contentHash, live.grid.contentHash)
        XCTAssertEqual(restored.exposedBone, live.exposedBone)
        XCTAssertEqual(restored.crackedBone, live.crackedBone)
        XCTAssertEqual(restored.wholeGems, live.wholeGems)
        XCTAssertEqual(restored.exposure, live.exposure)
        XCTAssertEqual(restored.intact, live.intact)
        XCTAssertEqual(restored.speed, 0, "a restored slab has no finger on it")

        // The app was killed, so the speed EMA is gone either way. Model that on the
        // live side before comparing what happens next.
        live.endStroke()
        live.tickIdle(frames: 400)
        XCTAssertEqual(live.speed, 0)

        let continuation = Trace.scrub(samples: 120, seed: 0xFEED)
        var liveCopy = live
        Trace.replay(continuation, on: &liveCopy, tool: .brush)
        Trace.replay(continuation, on: &restored, tool: .brush)
        XCTAssertEqual(restored.grid.contentHash, liveCopy.grid.contentHash)
        XCTAssertEqual(restored.crackedBone, liveCopy.crackedBone)
    }

    func testRestoringWithoutTheRandomStateDivergesOnCracks() {
        // Documents why randomState is saved: without it, the same continuation
        // produces different crack rolls, which is the save-scum hole.
        guard let site = ContentCatalog.shared.site("green_river") else { return XCTFail() }
        var live = SlabSimulation(seed: 77, site: site)
        Trace.replay(Trace.scrub(samples: 300), on: &live, tool: .airBlower)
        live.endStroke()
        live.tickIdle(frames: 400)

        let continuation = Trace.scrub(samples: 200, seed: 0xC0FFEE)
        var withState = SlabSimulation(
            grid: live.grid, layout: live.layout, randomState: live.randomState
        )
        var withoutState = SlabSimulation(grid: live.grid, layout: live.layout)
        // Modifiers are composed by the run layer, not stored in the grid, so a
        // restore has to re-apply them. Forgetting this changes the physics silently.
        withState.crackMultiplier = live.crackMultiplier
        withoutState.crackMultiplier = live.crackMultiplier
        withState.siteCrackMultiplier = live.siteCrackMultiplier
        withoutState.siteCrackMultiplier = live.siteCrackMultiplier
        var reference = live
        Trace.replay(continuation, on: &reference, tool: .airBlower)
        Trace.replay(continuation, on: &withState, tool: .airBlower)
        Trace.replay(continuation, on: &withoutState, tool: .airBlower)

        XCTAssertEqual(withState.grid.contentHash, reference.grid.contentHash)
        XCTAssertNotEqual(withoutState.grid.contentHash, reference.grid.contentHash)
    }

    func testValueSemanticsMeanACopyIsNotAliased() {
        // The sim is a struct on purpose: the renderer can snapshot it without the
        // dig mutating underneath. If SlabGrid ever becomes a class this fails.
        guard let site = ContentCatalog.shared.site("charmouth") else { return XCTFail() }
        var sim = SlabSimulation(seed: 1, site: site)
        let snapshot = sim
        Trace.replay(Trace.scrub(samples: 200), on: &sim, tool: .airBlower)
        XCTAssertNotEqual(sim.grid.contentHash, snapshot.grid.contentHash)
        XCTAssertEqual(snapshot.exposedBone, 0, "the snapshot was mutated")
    }
}
