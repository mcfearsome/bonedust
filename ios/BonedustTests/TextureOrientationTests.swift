import BonedustCore
import SpriteKit
import XCTest

@testable import Bonedust

/// Which way up the slab reaches the screen.
///
/// Everything in Bonedust treats y as running *down*: grid row 0 is the top of the slab,
/// `SlabGenerator` lays fossils out that way, `DigScene.gridPoint` maps a touch near the top
/// of the view to row 0, and `SlabRenderer` lights bone from above. GPU textures inherited
/// the opposite convention from OpenGL.
///
/// Uploading rows in order therefore drew the slab mirrored, which put every brush stroke at
/// the vertically reflected position and made dragging down dig upwards. Nothing caught it:
/// `make render` writes its PNGs top row first and so looks correct, a procedurally generated
/// fossil is plausible either way up, and bone lit from below is not obviously wrong until
/// you are holding the phone.
///
/// These two tests are the pair that would have. The first measures what the framework does
/// rather than trusting anyone's memory of it; the second checks the whole upload path puts
/// grid row 0 where a finger expects to find it.
@MainActor
final class TextureOrientationTests: XCTestCase {

    /// If Apple ever flips this, `copyRowsBottomUp` becomes the bug and this test is the
    /// thing that says so.
    func testSpriteKitReadsTheFirstPixelRowAsTheBottom() throws {
        let side = 4
        let texture = SKMutableTexture(size: CGSize(width: side, height: side))
        texture.filteringMode = .nearest

        // Row 0 red, every other row blue.
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let o = (y * side + x) * 4
                bytes[o] = y == 0 ? 255 : 0
                bytes[o + 2] = y == 0 ? 0 : 255
                bytes[o + 3] = 255
            }
        }
        texture.modifyPixelData { pointer, length in
            guard let pointer else { return }
            bytes.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                memcpy(pointer, base, min(length, src.count))
            }
        }

        let image = try XCTUnwrap(texture.cgImage(), "no image back from the texture")
        let pixels = try XCTUnwrap(Self.rgba(of: image))
        let top = Self.pixel(pixels, width: side, x: 0, y: 0)
        let bottom = Self.pixel(pixels, width: side, x: 0, y: side - 1)

        XCTAssertGreaterThan(
            top.b, top.r,
            "SKMutableTexture now puts the first row at the top; copyRowsBottomUp is "
                + "flipping the slab for no reason and should be dropped"
        )
        XCTAssertGreaterThan(bottom.r, bottom.b, "row 0 should have landed at the bottom")
    }

    /// Brushes a band across the top of the slab and checks it shows up at the top.
    ///
    /// Measured against the real pipeline — generator, renderer, `copyRowsBottomUp`, texture
    /// — because every individual piece was already self-consistent while the composition
    /// was mirrored. Brightness of a band is compared before and after rather than exact
    /// pixel values, so the sRGB round trip through `CGContext` cannot make it flaky.
    func testBrushingTheTopOfTheSlabShowsAtTheTopOfTheTexture() throws {
        let site = try XCTUnwrap(ContentCatalog.shared.site("charmouth"))
        let engine = DigEngine(seed: 11, site: site)
        var renderer = SlabRenderer(palette: site.palette, tuning: engine.sim.tuning)
        renderer.lightLevel = site.modifiers.lightLevel

        let texture = SKMutableTexture(
            size: CGSize(width: SlabRenderer.width, height: SlabRenderer.height)
        )
        texture.filteringMode = .nearest

        func upload() throws -> [UInt8] {
            texture.modifyPixelData { pointer, length in
                guard let pointer else { return }
                renderer.copyRowsBottomUp(into: pointer, length: length)
            }
            let image = try XCTUnwrap(texture.cgImage())
            return try XCTUnwrap(Self.rgba(of: image))
        }

        renderer.redrawEverything(engine.grid)
        let before = try upload()

        // One band along grid y = 6, which is the top of the slab.
        engine.brushBegan(at: Vec2(6, 6))
        for x in stride(from: Float(6), through: 90, by: 0.9) {
            engine.brushMoved(to: Vec2(x, 6), deltaMillis: 16.67)
        }
        engine.brushEnded()
        renderer.redrawEverything(engine.grid)
        let after = try upload()

        let topBefore = Self.brightness(before, rows: Array(0..<16))
        let topAfter = Self.brightness(after, rows: Array(0..<16))
        let bottomRows = Array((SlabRenderer.height - 16)..<SlabRenderer.height)
        let bottomBefore = Self.brightness(before, rows: bottomRows)
        let bottomAfter = Self.brightness(after, rows: bottomRows)

        XCTAssertNotEqual(
            topBefore, topAfter, accuracy: 0.0001,
            "brushing grid row 6 changed nothing in the top of the texture — the slab is "
                + "going up mirrored and every stroke will land reflected"
        )
        XCTAssertEqual(
            bottomBefore, bottomAfter, accuracy: 0.0001,
            "brushing the top of the slab changed the bottom of the texture"
        )
    }

    // MARK: Pixel reading

    private static func rgba(of image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext draws with the origin at the top-left, so row 0 here is the top row of
        // what actually appears on screen.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private static func pixel(
        _ data: [UInt8], width: Int, x: Int, y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        let o = (y * width + x) * 4
        return (data[o], data[o + 1], data[o + 2])
    }

    private static func brightness(_ data: [UInt8], rows: [Int]) -> Double {
        var sum = 0.0
        var count = 0
        for y in rows {
            for x in 0..<SlabRenderer.width {
                let p = pixel(data, width: SlabRenderer.width, x: x, y: y)
                sum += Double(p.r) + Double(p.g) + Double(p.b)
                count += 3
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }
}
