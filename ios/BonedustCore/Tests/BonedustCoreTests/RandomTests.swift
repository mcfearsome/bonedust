import XCTest
@testable import BonedustCore

final class RandomTests: XCTestCase {

    func testSameSeedGivesSameSequence() {
        var a = SplitMix64(seed: 12345)
        var b = SplitMix64(seed: 12345)
        for _ in 0..<1000 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testDifferentSeedsDiverge() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        var matches = 0
        for _ in 0..<100 where a.next() == b.next() { matches += 1 }
        XCTAssertEqual(matches, 0)
    }

    func testNextUnitStaysInRange() {
        var rng = SplitMix64(seed: 99)
        for _ in 0..<10_000 {
            let value = rng.nextUnit()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }

    func testNextUnitIsRoughlyUniform() {
        var rng = SplitMix64(seed: 4242)
        var buckets = [Int](repeating: 0, count: 10)
        let draws = 100_000
        for _ in 0..<draws {
            buckets[min(9, Int(rng.nextUnit() * 10))] += 1
        }
        for count in buckets {
            // 10% expected; allow a generous band, this is a smoke test for a
            // broken shift, not a statistics exam.
            XCTAssertGreaterThan(count, draws / 20)
            XCTAssertLessThan(count, draws / 5)
        }
    }

    func testIntBoundsAreRespected() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<5_000 {
            let value = rng.nextInt(below: 6)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 6)
            let inclusive = rng.nextInt(3, through: 8)
            XCTAssertGreaterThanOrEqual(inclusive, 3)
            XCTAssertLessThanOrEqual(inclusive, 8)
        }
        XCTAssertEqual(rng.nextInt(below: 0), 0)
        XCTAssertEqual(rng.nextInt(5, through: 5), 5)
    }

    func testInclusiveRangeHitsBothEnds() {
        var rng = SplitMix64(seed: 31337)
        var sawMin = false, sawMax = false
        for _ in 0..<2_000 {
            let value = rng.nextInt(3, through: 8)
            if value == 3 { sawMin = true }
            if value == 8 { sawMax = true }
        }
        XCTAssertTrue(sawMin, "crack walk length could never be the minimum")
        XCTAssertTrue(sawMax, "crack walk length could never be the maximum")
    }

    func testForkDivergesFromParent() {
        var parent = SplitMix64(seed: 500)
        var child = parent.fork()
        XCTAssertNotEqual(parent.next(), child.next())
    }
}
