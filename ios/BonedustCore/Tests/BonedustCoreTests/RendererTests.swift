import XCTest
@testable import BonedustCore

/// The renderer lives in the package now, so these run on the host in a second instead of
/// waiting on a simulator. They cover what a test usefully can — that pixels are written,
/// that the tell brightens, that an incremental redraw matches a full one. What they
/// cannot cover is whether the slab *looks* right, which is what `bonedust-tool render`
/// is for.
final class SlabRendererTests: XCTestCase {

    func testRendererFillsEveryPixelOpaque() {
        let site = ContentCatalog.shared.site("charmouth")!
        let (grid, _) = SlabGenerator.generate(seed: 1, site: site)
        var renderer = SlabRenderer(palette: site.palette)
        renderer.redrawEverything(grid)
        XCTAssertEqual(
            renderer.pixels.count,
            SlabGrid.width * SlabGrid.height * 4
        )
        for index in stride(from: 3, to: renderer.pixels.count, by: 4) {
            XCTAssertEqual(renderer.pixels[index], 255, "pixel \(index / 4) is not opaque")
        }
    }

    func testExposedBoneRendersLighterThanBuriedMatrix() {
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount { grid.cells[index].depth = 3 }
        // One exposed bone cell in a field of topsoil.
        let bone = SlabGrid.index(48, 64)
        grid.cells[bone].depth = 0
        grid.cells[bone].flags |= SlabGrid.Flag.bone

        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertGreaterThan(luma(48, 64), luma(10, 10), "bone should read brighter than topsoil")
    }

    func testTheBoneTellBrightensSandstoneOverBone() {
        // §3's tell. If this stops working, careful play stops being possible.
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 1
        }
        let overBone = SlabGrid.index(30, 30)
        grid.cells[overBone].flags |= SlabGrid.Flag.bone
        // Remove cosmetic noise so the comparison is only about the tell.
        for index in 0..<SlabGrid.cellCount { grid.cells[index].noise = 0 }

        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertGreaterThan(luma(30, 30), luma(60, 60), "sandstone over bone is not tinted")
    }

    func testDirtyRedrawMatchesAFullRedraw() {
        // The renderer inflates the dirty rect by one cell for edge shading. If that
        // inflation is wrong, digging leaves stale seams, which this catches.
        let site = ContentCatalog.shared.site("hell_creek")!
        var sim = SlabSimulation(seed: 88, site: site)
        var incremental = SlabRenderer(palette: site.palette)
        incremental.redrawEverything(sim.grid)
        _ = sim.consumeDirty()

        sim.beginStroke(at: Vec2(20, 30), tool: .brush)
        for step in 0..<120 {
            let x = 20 + Float(step) * 0.5
            sim.moveStroke(to: Vec2(x, 30 + Float(step) * 0.3), deltaMillis: 16.67, tool: .brush)
        }
        sim.endStroke()
        incremental.redraw(sim.grid, region: sim.consumeDirty())

        var full = SlabRenderer(palette: site.palette)
        full.redrawEverything(sim.grid)
        XCTAssertEqual(incremental.pixels, full.pixels,
                       "incremental redraw left stale pixels")
    }

    func testNightDigsDimEverythingWithoutLosingTheFossil() {
        // lightLevel 0.55 is a whole-palette change and the obvious way to make a site
        // unplayable. Bone has to stay clearly brighter than the matrix around it.
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 0
            grid.cells[index].noise = 0
        }
        // A block, not a single cell: a lone bone cell is the pathological case and
        // asserting against it measures the edge shading rather than the palette.
        for y in 60..<70 {
            for x in 44..<54 {
                grid.cells[SlabGrid.index(x, y)].flags |= SlabGrid.Flag.bone
            }
        }

        var renderer = SlabRenderer()
        renderer.lightLevel = 0.55
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertGreaterThan(luma(48, 64), luma(10, 10) + 40,
                             "bone does not stand out from matrix at night")
    }

    func testAOneCellWideFeatureIsNotDimmedByEdgeShading() {
        // The fine ribs of a Knightia and the veins of a leaf are one cell across. Shading
        // them from both sides used to make them darker than plain bone, which is the
        // opposite of what edge shading is for.
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 0
            grid.cells[index].noise = 0
        }
        // A horizontal hairline: every cell has no bone above or below it.
        for x in 20..<70 { grid.cells[SlabGrid.index(x, 40)].flags |= SlabGrid.Flag.bone }
        // And a block, for comparison.
        for y in 60..<70 {
            for x in 20..<30 { grid.cells[SlabGrid.index(x, y)].flags |= SlabGrid.Flag.bone }
        }

        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertEqual(luma(45, 40), luma(25, 65), accuracy: 2,
                       "a hairline reads dimmer than the body of a fossil")
        XCTAssertGreaterThan(luma(45, 40), luma(5, 5) + 60,
                             "a hairline does not stand out from the matrix")
    }

    func testCrackedBoneIsDarkerThanIntactBone() {
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 0
            grid.cells[index].noise = 0
            grid.cells[index].flags |= SlabGrid.Flag.bone
        }
        grid.cells[SlabGrid.index(20, 20)].flags |= SlabGrid.Flag.cracked
        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertLessThan(luma(20, 20), luma(60, 60) - 150,
                          "a ruined specimen has to read as ruined at a glance")
    }

    func testTheXRayRevealShowsBuriedBone() {
        var grid = SlabGrid()
        for index in 0..<SlabGrid.cellCount {
            grid.cells[index].depth = 3
            grid.cells[index].noise = 0
        }
        grid.cells[SlabGrid.index(30, 30)].flags |= SlabGrid.Flag.bone

        var plain = SlabRenderer()
        plain.redrawEverything(grid)
        var revealing = SlabRenderer()
        revealing.revealBuriedBone = true
        revealing.redrawEverything(grid)

        func luma(_ renderer: SlabRenderer, _ x: Int, _ y: Int) -> Int {
            let offset = (y * SlabGrid.width + x) * 4
            return Int(renderer.pixels[offset]) + Int(renderer.pixels[offset + 1])
                + Int(renderer.pixels[offset + 2])
        }
        XCTAssertEqual(luma(plain, 30, 30), luma(plain, 70, 70),
                       "bone under three layers must be invisible without the goggles")
        XCTAssertGreaterThan(luma(revealing, 30, 30), luma(revealing, 70, 70))
    }
}
