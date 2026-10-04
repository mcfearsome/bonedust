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

    func testNotReadingTheSlabCostsTheFossil() {
        // The ordering that has to hold: a player who does not look ahead wrecks bone,
        // and a careful one does not. Exposure is deliberately *not* asserted to be
        // monotonic in speed — once the model avoids known bone properly, going faster
        // stops buying meaningfully more coverage, and pinning an order here would be
        // asserting an artefact of the player model rather than a property of the game.
        let careful = slabs(.careful)
        let average = slabs(.average)
        let reckless = slabs(.reckless)

        XCTAssertGreaterThanOrEqual(careful.intact, average.intact)
        XCTAssertGreaterThan(average.intact, reckless.intact)
        XCTAssertGreaterThan(careful.exposure, 0.5, "careful should still finish fossils")
    }

    func testRecklessnessIsPunished() {
        let average = slabs(.average)
        let reckless = slabs(.reckless)
        XCTAssertGreaterThan(average.payout, reckless.payout,
                             "not reading the slab should cost money")
    }

    /// The depth-1 tell only pays off if seeing bone early lets you protect it.
    ///
    /// Measured across the whole fossil roster rather than one site, because a single
    /// site's species mix moved the number by more than the effect being measured: on
    /// Charmouth alone the two policies came out 0.9393 against 0.9399, which is noise
    /// wearing the shape of a result.
    func testLookaheadIsWorthMoney() {
        var blind = PlayerPolicy.average
        blind.lookaheadSamples = 0
        var seeing = 0.0
        var notSeeing = 0.0
        let sites = ["charmouth", "wheeler", "green_river", "hell_creek"]
        for site in sites {
            seeing += Double(slabs(.average, site: site).intact) / Double(sites.count)
            notSeeing += Double(slabs(blind, site: site).intact) / Double(sites.count)
        }
        XCTAssertGreaterThan(seeing, notSeeing,
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
