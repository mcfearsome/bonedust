import XCTest
@testable import BonedustCore

/// Locks in the shape of the speed-versus-care trade-off, which is pillar 2 of the
/// brief ("every slab is a tension between clearing fast and protecting bone").
///
/// These are deliberately *relative* assertions. Absolute win rates depend on the
/// shop, which does not exist until M3, so pinning them now would bake in a number
/// that is about to change. What must never change is the ordering: rushing buys
/// exposure and costs intact, and neither extreme should beat playing in between.
final class EconomyBalanceTests: XCTestCase {

    private let seeds: [UInt64] = Array(0..<12).map { 0xBA1A_0000 + UInt64($0) * 7919 }

    private func slabs(_ policy: PlayerPolicy, site siteID: String = "charmouth")
        -> (exposure: Double, intact: Double, payout: Double) {
        let site = ContentCatalog.shared.site(siteID)!
        var exposure = 0.0, intact = 0.0, payout = 0.0
        for seed in seeds {
            let record = EconomySimulator.playSlab(
                seed: seed, day: 1, site: site, policy: policy
            )
            exposure += Double(record.payout.exposure)
            intact += Double(record.payout.intact)
            payout += Double(record.payout.total)
        }
        let count = Double(seeds.count)
        return (exposure / count, intact / count, payout / count)
    }

    func testRushingBuysExposureAndCostsIntact() {
        let careful = slabs(.careful)
        let average = slabs(.average)
        let reckless = slabs(.reckless)

        XCTAssertGreaterThan(reckless.exposure, average.exposure)
        XCTAssertGreaterThan(average.exposure, careful.exposure)

        XCTAssertGreaterThan(careful.intact, average.intact)
        XCTAssertGreaterThan(average.intact, reckless.intact)
    }

    func testNeitherExtremeOutEarnsPlayingInBetween() {
        // If one end of the dial were simply best, there would be no decision to make
        // and the core tension would be decorative.
        let careful = slabs(.careful)
        let average = slabs(.average)
        let reckless = slabs(.reckless)
        XCTAssertGreaterThan(average.payout, careful.payout, "care alone should not win")
        XCTAssertGreaterThan(average.payout, reckless.payout, "speed alone should not win")
    }

    func testLookaheadIsWorthMoney() {
        // The depth-1 tell only pays off if seeing bone early lets you protect it.
        var blind = PlayerPolicy.average
        blind.lookaheadSamples = 0
        let seeing = slabs(.average)
        let notSeeing = slabs(blind)
        XCTAssertGreaterThan(seeing.intact, notSeeing.intact,
                             "reading the slab ahead did not protect any bone")
    }

    func testFragileSitesAreHarderOnTheSameFossilCare() {
        // Green River's twist has to actually bite.
        let charmouth = slabs(.average, site: "charmouth")
        let greenRiver = slabs(.average, site: "green_river")
        XCTAssertLessThan(greenRiver.intact, charmouth.intact)
    }

    func testWheelersThinLayersClearFaster() {
        // Depth 2 instead of 3 means more exposure for the same daylight.
        let charmouth = slabs(.average, site: "charmouth")
        let wheeler = slabs(.average, site: "wheeler")
        XCTAssertGreaterThan(wheeler.exposure, charmouth.exposure)
    }

    func testAFullRunProducesFiveSlabsAndSettles() {
        let run = EconomySimulator.playRun(seed: 99, siteID: "charmouth", tier: 1)
        XCTAssertEqual(run.slabs.count, 5)
        XCTAssertTrue(run.isOver)
        XCTAssertEqual(Set(run.slabs.map(\.day)), Set(1...5))
        XCTAssertEqual(run.totalEarned, run.slabs.reduce(0) { $0 + $1.payout.total })
    }

    func testTheSimulatedRunIsDeterministic() {
        let first = EconomySimulator.playRun(seed: 4242, siteID: "green_river", tier: 3)
        let second = EconomySimulator.playRun(seed: 4242, siteID: "green_river", tier: 3)
        XCTAssertEqual(first, second)
    }

    func testSerpentinePathCoversTheRectangleWithoutJumping() {
        // A turn between passes must cost the same distance as any other movement, or
        // the speed EMA reads it as a flick and cracks bone the player never rushed.
        let path = SerpentinePath(x0: 2, x1: 94, y0: 2, y1: 126, rowStep: 6.7)
        var previous = path.point(at: 0)
        var maxStep: Float = 0
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var distance: Float = 0
        while distance < 4_000 {
            distance += 1
            let point = path.point(at: distance)
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
            // Skip the wrap back to the start of a new sweep.
            let step = (point - previous).length
            if step < 20 { maxStep = max(maxStep, step) }
            previous = point
        }
        XCTAssertLessThan(maxStep, 2.0, "the path jumped \(maxStep) cells in one step")
        XCTAssertLessThan(minX, 4)
        XCTAssertGreaterThan(maxX, 90)
        XCTAssertLessThan(minY, 4)
        XCTAssertGreaterThan(maxY, 118, "the sweep never reached the bottom of the slab")
    }
}
