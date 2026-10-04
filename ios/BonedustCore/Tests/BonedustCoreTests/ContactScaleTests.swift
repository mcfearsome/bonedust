import XCTest
@testable import BonedustCore

/// Brush size from contact size.
///
/// Testable without a touchscreen because the mapping is a pure function of one scalar —
/// the same split that made the breath detector testable. Everything iOS-specific stays in
/// `DigScene`, which reads `touch.majorRadius` and hands the number over.
final class ContactScaleTests: XCTestCase {

    func testAFingertipIsTheBaselineAndScalesNothing() {
        var contact = ContactScale()
        // Several light touches: the smallest becomes the reference.
        for _ in 0..<12 { contact.accept(radius: 9) }
        XCTAssertEqual(contact.accept(radius: 9), 1, accuracy: 0.05,
                       "the tip a player always uses must not shrink their own brush")
    }

    func testTheFlatOfAFingerWidensTheBrush() {
        var contact = ContactScale()
        for _ in 0..<12 { contact.accept(radius: 9) }
        let scale = contact.accept(radius: 18)
        XCTAssertGreaterThan(scale, 1.3, "double the contact should be a real difference")

        let brush = contact.applied(to: .brush)
        XCTAssertGreaterThan(brush.radius, BrushTool.brush.radius)
    }

    /// The trade. Without it, pressing harder is strictly better and the tip is pointless.
    func testABroaderContactIsHarderToControl() {
        var contact = ContactScale()
        for _ in 0..<12 { contact.accept(radius: 9) }
        contact.accept(radius: 20)
        let broad = contact.applied(to: .brush)
        XCTAssertLessThan(
            broad.safeSpeed, BrushTool.brush.safeSpeed,
            "a flat finger covers more ground and must be slower over bone, or there is no "
                + "reason ever to use the tip"
        )
    }

    func testTheScaleIsCappedSoAPalmCannotClearASlab() {
        var contact = ContactScale()
        for _ in 0..<12 { contact.accept(radius: 8) }
        XCTAssertEqual(
            contact.accept(radius: 400), SimTuning.standard.contactMaxScale, accuracy: 0.001
        )
    }

    /// Apple documents the units of `majorRadius` and nothing about what a finger produces,
    /// and it varies by device and by pressure. So the baseline is learned, and a player
    /// with small hands and one with large hands both get a brush that answers to them.
    func testCalibrationAdaptsToTheHand() {
        var small = ContactScale()
        var large = ContactScale()
        for _ in 0..<20 { small.accept(radius: 6); large.accept(radius: 14) }
        // Each lays a finger flat: twice their own tip.
        let smallFlat = small.accept(radius: 12)
        let largeFlat = large.accept(radius: 28)
        XCTAssertEqual(smallFlat, largeFlat, accuracy: 0.1,
                       "the same gesture should mean the same thing to different hands")
    }

    /// One freak sample must not poison the rest of the dig.
    func testAFreakTinySampleCannotRuinTheCalibration() {
        var contact = ContactScale()
        for _ in 0..<20 { contact.accept(radius: 10) }
        contact.accept(radius: 0.2)
        XCTAssertGreaterThanOrEqual(contact.tipRadius, SimTuning.standard.contactMinTipPoints)
        // An ordinary touch afterwards is still ordinary, not a sudden huge brush.
        XCTAssertLessThan(contact.accept(radius: 10), SimTuning.standard.contactMaxScale)
    }

    func testAZeroOrNegativeRadiusIsIgnored() {
        var contact = ContactScale()
        for _ in 0..<12 { contact.accept(radius: 9) }
        let before = contact.tipRadius
        contact.accept(radius: 0)
        contact.accept(radius: -3)
        XCTAssertEqual(contact.tipRadius, before, "a device reporting nothing must change nothing")
    }
}
