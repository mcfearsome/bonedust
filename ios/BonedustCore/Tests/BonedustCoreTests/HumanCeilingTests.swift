import XCTest
@testable import BonedustCore

/// What one brush, held at exactly the safe speed on a perfect serpentine, can reach
/// before the daylight runs out.
///
/// This is the ceiling a *person* plays against. `EconomySimulator` does not measure it:
/// its model switches between a fast survey brush and a careful dig brush continuously and
/// for free, every sample, which no hand can do through a tool tray. The balance targets
/// were met by that model while the game was not winnable by hand, and nothing here
/// connected the two numbers.
final class HumanCeilingTests: XCTestCase {

    func testOneBrushAtSafeSpeedReachesUsefulExposureInOneDaylight() {
        let tuning = SimTuning.standard
        let catalog = ContentCatalog.shared
        let brush = BrushTool.brush
        let budget = tuning.daylightSeconds * 60 * brush.safeSpeed
        print("""

        daylight \(tuning.daylightSeconds)s, safeSpeed \(brush.safeSpeed) cells/frame, \
        radius \(brush.radius)
        travel budget: \(Int(budget)) cells
        """)

        var worst: Float = 1
        for siteID in ["charmouth", "green_river", "hell_creek"] {
            guard let site = catalog.site(siteID) else { continue }
            var totals: [Float] = []
            for seed in UInt64(0)..<12 {
                var sim = SlabSimulation(seed: seed, site: site, catalog: catalog)
                let frames = Int(tuning.daylightSeconds * 60)
                let step = brush.safeSpeed
                let gap = brush.radius * 0.9
                var used = 0
                var y = Float(1)
                var leftToRight = true
                outer: while y < Float(SlabGrid.height) {
                    let xs = Array(stride(from: Float(1), through: Float(SlabGrid.width) - 1,
                                          by: step))
                    let row = leftToRight ? xs : xs.reversed()
                    sim.beginStroke(at: Vec2(row[0], y), tool: brush)
                    for x in row.dropFirst() {
                        sim.moveStroke(to: Vec2(x, y), deltaMillis: 1000.0 / 60, tool: brush)
                        used += 1
                        if used >= frames { break outer }
                    }
                    sim.endStroke()
                    y += gap
                    // Back to the top rather than stopping: one covering is not a dig, and
                    // halting at the bottom edge is what made this read 0.000 the first time.
                    if y >= Float(SlabGrid.height) { y = 1 }
                    leftToRight.toggle()
                }
                sim.endStroke()
                totals.append(sim.exposure)
            }
            let mean = totals.reduce(0, +) / Float(totals.count)
            worst = min(worst, mean)
            print(String(format: "  %-13@ mean exposure %.3f  best %.3f",
                         siteID as NSString, mean, totals.max() ?? 0))
        }

        // A perfect machine sweep should comfortably clear a slab, or a person has no
        // chance at all. Payout scales as exposure^1.5, so 0.6 pays 46% of full.
        XCTAssertGreaterThan(
            worst, 0.85,
            "a flawless single-brush sweep cannot clear a slab in one daylight, so the "
                + "installments are unreachable by hand however well the player digs"
        )
    }
}
