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

    /// Pins the formula itself, not just its endpoints. Without these, a
    /// "simplified" channel() or a one-digit threshold typo stays green while
    /// every contrast guarantee downstream silently inflates.
    func testLuminanceMatchesWCAGReferenceValues() {
        let white = RGB8(0xFF, 0xFF, 0xFF)
        XCTAssertEqual(
            RGB8(0x59, 0x59, 0x59).contrastRatio(against: white), 7.00, accuracy: 0.01
        )
        XCTAssertEqual(RGB8(0xFF, 0x00, 0x00).relativeLuminance, 0.2126, accuracy: 0.0001)
        XCTAssertEqual(RGB8(0x00, 0x00, 0xFF).relativeLuminance, 0.0722, accuracy: 0.0001)
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
        let nightPage = Earth.nightPage
        let nightPairs: [(String, RGB8)] = [
            ("primary text", Earth.s1),
            ("stamp", Earth.stampNight),
            ("gem", Earth.gemNight),
            ("safe", Earth.safeNight),
        ]
        for (name, colour) in nightPairs {
            XCTAssertGreaterThanOrEqual(
                colour.contrastRatio(against: nightPage), 4.5,
                "\(name) fails AA contrast on the night page"
            )
        }
    }
}
