import Foundation
import XCTest
@testable import BonedustCore

final class SlabSnapshotTests: XCTestCase {

    private func digInProgress(
        site siteID: String = "hell_creek", seed: UInt64 = 5150
    ) -> (SlabSimulation, Site) {
        let site = ContentCatalog.shared.site(siteID)!
        var sim = SlabSimulation(seed: seed, site: site)
        Trace.replay(Trace.scrub(samples: 320), on: &sim, tool: .airBlower)
        sim.endStroke()
        sim.tickIdle(frames: 400)
        return (sim, site)
    }

    func testSnapshotRestoresTheExactSlab() throws {
        let (sim, _) = digInProgress()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 23.5, toolID: BrushTool.airBlower.id, day: 3
        )
        let restored = try snapshot.restore().simulation

        XCTAssertEqual(restored.grid.contentHash, sim.grid.contentHash)
        XCTAssertEqual(restored.exposedBone, sim.exposedBone)
        XCTAssertEqual(restored.crackedBone, sim.crackedBone)
        XCTAssertEqual(restored.wholeGems, sim.wholeGems)
        XCTAssertEqual(restored.exposure, sim.exposure)
        XCTAssertEqual(restored.intact, sim.intact)
        XCTAssertEqual(restored.layout, sim.layout)
        XCTAssertEqual(restored.crackMultiplier, sim.crackMultiplier, accuracy: 0.0001)
    }

    func testRestoredDigContinuesIdentically() throws {
        let (sim, _) = digInProgress()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 12, toolID: BrushTool.brush.id, day: 1
        )
        var restored = try snapshot.restore().simulation
        var reference = sim

        let continuation = Trace.scrub(samples: 200, seed: 0xBADC0DE)
        Trace.replay(continuation, on: &restored, tool: .brush)
        Trace.replay(continuation, on: &reference, tool: .brush)
        XCTAssertEqual(restored.grid.contentHash, reference.grid.contentHash)
        XCTAssertEqual(restored.crackedBone, reference.crackedBone)
    }

    func testSnapshotCarriesDaylightToolAndDay() throws {
        let (sim, _) = digInProgress()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 18.25, toolID: BrushTool.fineBrush.id, day: 4
        )
        let restored = try snapshot.restore()
        XCTAssertEqual(restored.daylightRemaining, 18.25)
        XCTAssertEqual(restored.tool.id, BrushTool.fineBrush.id)
        XCTAssertEqual(restored.day, 4)
    }

    func testSnapshotIsSixBytesPerCell() {
        let (sim, _) = digInProgress()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        XCTAssertEqual(snapshot.cells.count, SlabGrid.cellCount * 6)
        // 72 KB. Worth stating: storing the noise field too would be 48 KB more for
        // information the seed already contains.
        XCTAssertEqual(snapshot.cells.count, 73_728)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let (sim, _) = digInProgress()
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 30, toolID: BrushTool.brush.id, day: 2
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SlabSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(try decoded.restore().simulation.grid.contentHash, sim.grid.contentHash)
    }

    func testStaleSchemaIsRefused() {
        let (sim, _) = digInProgress()
        var snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        snapshot.schema = 99
        XCTAssertThrowsError(try snapshot.restore()) { error in
            XCTAssertEqual(
                error as? SlabSnapshot.Failure,
                .schemaMismatch(found: 99, expected: SlabSnapshot.currentSchema)
            )
        }
    }

    func testTruncatedDataIsRefused() {
        let (sim, _) = digInProgress()
        var snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        snapshot.cells = snapshot.cells.prefix(1_000)
        XCTAssertThrowsError(try snapshot.restore()) { error in
            guard case .truncated = error as? SlabSnapshot.Failure else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testUnknownSiteIsRefused() {
        let (sim, _) = digInProgress()
        var snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        snapshot.siteID = "atlantis"
        XCTAssertThrowsError(try snapshot.restore()) { error in
            XCTAssertEqual(error as? SlabSnapshot.Failure, .unknownSite("atlantis"))
        }
    }

    func testAChangedBoneMaskIsRefused() {
        // The important one. If a content update retunes a fossil's shape, the saved
        // slab's bone mask no longer matches what the seed now generates, and resuming
        // would give a dig whose boneCells disagrees with the bone on screen — every
        // payout from then on quietly wrong. Refusing means a fresh slab instead.
        let (sim, _) = digInProgress()
        var snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        var bytes = snapshot.cells
        // Flip a bone bit on one cell, as a shape change would.
        let victim = SlabGrid.index(10, 10) * SlabSnapshot.bytesPerCell + 1
        bytes[victim] ^= SlabGrid.Flag.bone
        snapshot.cells = bytes
        XCTAssertThrowsError(try snapshot.restore()) { error in
            XCTAssertEqual(error as? SlabSnapshot.Failure, .contentChanged)
        }
    }

    func testCrackedBitsAreNotTreatedAsAContentChange() throws {
        // Cracks are the one flag the player creates, so they must survive a restore
        // without tripping the content check.
        let (sim, _) = digInProgress()
        XCTAssertGreaterThan(sim.crackedBone, 0, "this test needs some cracks")
        let snapshot = SlabSnapshot.capture(
            sim, daylightRemaining: 1, toolID: BrushTool.brush.id, day: 1
        )
        let restored = try snapshot.restore().simulation
        XCTAssertEqual(restored.crackedBone, sim.crackedBone)
    }
}
