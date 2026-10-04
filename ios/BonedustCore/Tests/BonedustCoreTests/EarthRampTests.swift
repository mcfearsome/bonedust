import XCTest
@testable import BonedustCore

final class EarthRampTests: XCTestCase {

    func testRampDarkensMonotonically() {
        let stops = Earth.all
        XCTAssertEqual(stops.count, 9)
        for i in 1..<stops.count {
            XCTAssertLessThan(
                stops[i].relativeLuminance, stops[i - 1].relativeLuminance,
                "stop \(i) is not darker than stop \(i - 1); a hex is mistyped"
            )
        }
    }

    func testContrastRatioIsSymmetricAndBounded() {
        let white = RGB8(255, 255, 255)
        let black = RGB8(0, 0, 0)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.01)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.01)
    }

    /// §Testing item 2. These are the pairs the design actually puts on screen.
    func testEveryTextPairClearsWCAGAAOnThePage() {
        let page = Earth.s1
        let bodyPairs: [(String, RGB8)] = [
            ("primary text", Earth.s8),
            ("secondary text", Earth.s5),
            ("stamp", Earth.stamp),
            ("gem", Earth.gem),
            ("safe", Earth.safe),
        ]
        for (name, colour) in bodyPairs {
            XCTAssertGreaterThanOrEqual(
                colour.contrastRatio(against: page), 4.5,
                "\(name) fails AA body contrast on the page"
            )
        }
    }

    /// The reason no text is allowed above s5. If someone lightens s5 this fails.
    func testDecorativeStopsCannotCarryBodyText() {
        XCTAssertLessThan(
            Earth.s4.contrastRatio(against: Earth.s1), 4.5,
            "s4 now clears AA; if that is deliberate, update the spec's role table"
        )
    }

    func testNightPageKeepsPrimaryTextReadableWhenInverted() {
        XCTAssertGreaterThanOrEqual(
            Earth.s1.contrastRatio(against: Earth.nightPage), 4.5,
            "night mode text is unreadable"
        )
    }
}
