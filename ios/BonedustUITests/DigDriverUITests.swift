import XCTest

/// Real touches against the real app. This is the one test in the project that goes through a
/// `UITouch`, SwiftUI's layout, SpriteKit's compositor and the framebuffer, and it is black-box:
/// it knows the app only by what a player or VoiceOver could read. README.md says why it exists.
final class DigDriverUITests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: A check

    /// A drag across the slab digs where the finger went. Every part of that is something an
    /// offscreen test cannot see:
    ///
    /// - The slab has a size on a real screen. A scene stuck at 1x1 and stretched by SpriteKit
    ///   gave a slab of 0x0 and every offscreen test stayed green.
    /// - The touch reaches the engine. With that slab, `gridPoint` returned nil and touches did
    ///   nothing at all; the daylight clock, which starts on the first touch, never moved.
    /// - The dig lands under the finger and not mirrored from it. The drag is off-centre in both
    ///   directions, so a flipped or reflected mapping puts the trench somewhere else.
    ///
    /// The slab is random each time, so this asserts where something changed on screen and not
    /// what is under it.
    func testARealDragDigsTheSlabUnderTheFinger() throws {
        let (app, slab) = startADig(site: "Charmouth")
        let frame = slab.frame
        XCTAssertGreaterThan(frame.width, 250, "the slab has no real size: \(frame)")
        XCTAssertGreaterThan(frame.height, 250, "the slab has no real size: \(frame)")

        let before = try daylight(app)
        XCTAssertEqual(before.remaining, before.total, "daylight started before anyone touched the slab")
        let untouched = try pixels(of: frame, in: app, named: "before the drag")

        let y = frame.minY + 0.30 * frame.height
        let from = CGPoint(x: frame.minX + 0.15 * frame.width, y: y)
        let to = CGPoint(x: frame.minX + 0.65 * frame.width, y: y)
        drag(app, from: from, to: to, velocity: 160)
        let dug = try pixels(of: frame, in: app, named: "after the drag")

        let after = try daylight(app)
        XCTAssertLessThan(after.remaining, after.total, "the touch never reached the engine: the daylight clock did not start")

        let change = untouched.changes(to: dug)
        XCTAssertGreaterThan(change.fraction, 0.01, "a drag across the slab changed \(change.fraction * 100)% of it")

        // In points from the slab's own top left corner, against where the finger went.
        let centreX = (from.x + to.x) / 2 - frame.minX
        let lineY = y - frame.minY
        let centroid = try XCTUnwrap(change.centroid, "nothing changed")
        XCTAssertEqual(centroid.x, centreX, accuracy: 0.08 * frame.width, "the dig is not under the finger horizontally")
        XCTAssertEqual(centroid.y, lineY, accuracy: 0.06 * frame.height, "the dig is not under the finger vertically")
        let (low, high) = try XCTUnwrap(change.columnSpan, "nothing changed")
        XCTAssertLessThan(low, from.x - frame.minX + 0.10 * frame.width, "the dig does not reach where the drag began")
        XCTAssertGreaterThan(high, to.x - frame.minX - 0.10 * frame.width, "the dig stops short of where the drag ended")
    }

    // MARK: A camera

    /// Not a check: a camera. Drives a whole dig with real touches and writes screenshots and a
    /// marker log, for a person or ffmpeg to look at afterwards. It runs only when
    /// `BONEDUST_UI_CAPTURE_DIR` is set, which `scripts/ui-capture.sh` does around a screen
    /// recording. Settings, all optional: `BONEDUST_UI_SITE` (a word from the site's name),
    /// `BONEDUST_UI_TOOL` (the tool button's name), `BONEDUST_UI_CAREFUL` and `BONEDUST_UI_FAST`
    /// (drag speeds in points a second), `BONEDUST_UI_ROWSTEP` (row spacing as a fraction of the
    /// slab's height).
    func testCaptureTour() throws {
        let directory = try XCTUnwrap(
            env["BONEDUST_UI_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "set BONEDUST_UI_CAPTURE_DIR to run the capture tour"
        )
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tool = env["BONEDUST_UI_TOOL"] ?? "Brush"
        let careful = CGFloat(Double(env["BONEDUST_UI_CAREFUL"] ?? "") ?? 170)
        let fast = CGFloat(Double(env["BONEDUST_UI_FAST"] ?? "") ?? 900)
        let rowStep = CGFloat(Double(env["BONEDUST_UI_ROWSTEP"] ?? "") ?? 0.11)

        var markers = ""
        func mark(_ text: String) {
            markers += String(format: "%.3f %@\n", Date().timeIntervalSince1970, text)
            try? markers.write(toFile: "\(directory)/markers.txt", atomically: true, encoding: .utf8)
        }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            mark("shot \(name)")
        }

        let (app, slab) = startADig(site: env["BONEDUST_UI_SITE"] ?? "Charmouth")
        func status(_ tag: String) {
            func value(_ label: String) -> String {
                let found = element(app, labelled: label)
                return found.exists ? (found.value as? String ?? "?") : "-"
            }
            mark("\(tag): exposed=\(value("Exposed")) intact=\(value("Intact")) daylight=\(value("Daylight remaining"))")
        }
        let frame = slab.frame
        mark("slab frame \(frame)")
        status("fresh")
        shot("01-fresh")

        if tool != "Brush" {
            let button = app.buttons[tool]
            XCTAssertTrue(button.exists, "no tool button called \(tool)")
            button.tap()
            mark("tool \(tool)")
        }

        func sweep(_ name: String, speed: CGFloat, from start: CGFloat, reversed: Bool) {
            mark("\(name) begin, \(speed) pt/s")
            var rows = Array(stride(from: start, through: 0.96, by: rowStep))
            if reversed { rows.reverse() }
            for (index, row) in rows.enumerated() {
                // The dig ends when the daylight does, and the slab goes with it.
                guard slab.exists else { return mark("\(name): the dig ended") }
                let y = frame.minY + frame.height * row
                let ends = (frame.minX + 6, frame.maxX - 6)
                let (x0, x1) = index % 2 == 0 ? ends : (ends.1, ends.0)
                drag(app, from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), velocity: speed)
            }
            mark("\(name) end")
        }

        sweep("careful 1", speed: careful, from: 0.05, reversed: false)
        status("after careful 1")
        if slab.exists { shot("02-after-careful-1") }
        sweep("careful 2", speed: careful, from: 0.05 + rowStep / 2, reversed: true)
        status("after careful 2")
        if slab.exists { shot("03-after-careful-2") }
        sweep("fast", speed: fast, from: 0.08, reversed: false)
        status("after fast")
        if slab.exists { shot("04-after-fast") }
        mark("done")
    }

    // MARK: Driving the app

    /// Launches the app, picks a site and starts a slab. `site` is any word in the site's name.
    ///
    /// The way in is the run loop's: the title screen, a card per site, then the dig. On the way it
    /// turns off "Listen while digging". This driver is about touches, and with the microphone on a
    /// dig starts an audio engine on the main thread, which on a simulator can leave the app
    /// unresponsive for minutes while XCTest waits for it to go idle.
    private func startADig(site: String) -> (app: XCUIApplication, slab: XCUIElement) {
        let app = XCUIApplication()
        app.launch()
        stopListening(app)
        // With a run already saved the title also offers `Continue run`; `New run` is the one
        // that goes to the site cards.
        let newRun = app.buttons["New run"]
        XCTAssertTrue(newRun.waitForExistence(timeout: 20), "no New run button on the title screen")
        newRun.tap()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", site)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no site called \(site) on the site-select screen")
        card.tap()
        let slab = element(app, labelled: "Dig slab")
        XCTAssertTrue(slab.waitForExistence(timeout: 10), "no slab on screen")
        return (app, slab)
    }

    /// Settings, "Listen while digging" off, Done. The preference is saved, so this only changes
    /// anything the first time.
    private func stopListening(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings button on the title screen")
        settings.tap()
        let listen = app.switches["Listen while digging"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10), "no Listen while digging switch in Settings")
        if (listen.value as? String) == "1" {
            // The row spans the screen and only the switch at its right end toggles.
            listen.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(listen.value as? String, "0", "could not turn Listen while digging off")
        }
        app.buttons["Done"].tap()
    }

    private func element(_ app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// `velocity` is in points a second. At a hundred and sixty the standard brush is well inside
    /// its safe speed, so a drag digs without cracking anything.
    private func drag(_ app: XCUIApplication, from start: CGPoint, to end: CGPoint, velocity: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(
            forDuration: 0.02,
            thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
            withVelocity: XCUIGestureVelocity(rawValue: velocity),
            thenHoldForDuration: 0
        )
    }

    /// The daylight bar's own accessibility value, "60 seconds of 60".
    private func daylight(_ app: XCUIApplication) throws -> (remaining: Int, total: Int) {
        let text = try XCTUnwrap(element(app, labelled: "Daylight remaining").value as? String, "no daylight bar")
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        XCTAssertEqual(numbers.count, 2, "cannot read the daylight from \"\(text)\"")
        return (numbers.first ?? 0, numbers.last ?? 0)
    }

    // MARK: Reading the screen

    /// A region of a real screenshot as 8-bit RGBA, so two moments can be compared.
    private struct Pixels {
        let width: Int
        let height: Int
        let scale: CGFloat
        let bytes: [UInt8]

        /// Where the other picture differs from this one by more than a visible amount.
        func changes(to other: Pixels) -> Changes {
            var count = 0
            var sumX = 0.0, sumY = 0.0
            var columns = [Int](repeating: 0, count: width)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let difference = abs(Int(bytes[i]) - Int(other.bytes[i]))
                        + abs(Int(bytes[i + 1]) - Int(other.bytes[i + 1]))
                        + abs(Int(bytes[i + 2]) - Int(other.bytes[i + 2]))
                    if difference > 40 {
                        count += 1
                        sumX += Double(x)
                        sumY += Double(y)
                        columns[x] += 1
                    }
                }
            }
            return Changes(count: count, total: width * height, scale: scale, sumX: sumX, sumY: sumY, columns: columns)
        }
    }

    private struct Changes {
        let count: Int
        let total: Int
        let scale: CGFloat
        let sumX: Double
        let sumY: Double
        let columns: [Int]

        var fraction: Double { Double(count) / Double(max(total, 1)) }

        /// The middle of what changed, in points from the region's top left corner.
        var centroid: CGPoint? {
            guard count > 0 else { return nil }
            return CGPoint(x: sumX / Double(count) / scale, y: sumY / Double(count) / scale)
        }

        /// The columns, in points, that hold the 2nd and the 98th percentile of what changed, so a
        /// few stray pixels do not stretch it.
        var columnSpan: (CGFloat, CGFloat)? {
            guard count > 0 else { return nil }
            func column(atFraction fraction: Double) -> CGFloat {
                var seen = 0
                for (x, n) in columns.enumerated() {
                    seen += n
                    if Double(seen) >= fraction * Double(count) { return CGFloat(x) / scale }
                }
                return CGFloat(columns.count) / scale
            }
            return (column(atFraction: 0.02), column(atFraction: 0.98))
        }
    }

    /// The region's pixels, and the whole screenshot kept with the results under `name` so a
    /// failing run can be looked at instead of guessed at.
    private func pixels(of region: CGRect, in app: XCUIApplication, named name: String) throws -> Pixels {
        let capture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = try XCTUnwrap(capture.image.cgImage, "no screenshot")
        let scale = CGFloat(screenshot.width) / app.frame.width
        let crop = CGRect(
            x: region.minX * scale, y: region.minY * scale,
            width: region.width * scale, height: region.height * scale
        ).integral
        let cropped = try XCTUnwrap(screenshot.cropping(to: crop), "the slab is not on the screen")
        let width = cropped.width, height = cropped.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the screenshot back")
        return Pixels(width: width, height: height, scale: scale, bytes: bytes)
    }
}
