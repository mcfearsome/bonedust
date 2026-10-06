import XCTest
@testable import BonedustCore

/// Every species has to actually rasterise into something diggable.
///
/// The roster went from 19 to 99, which is 80 hand-written parameter sets across eight
/// shape generators. A `thickness` an order of magnitude too small gives a fossil of four
/// cells that cannot be found in forty seconds; one too large gives a slab that is entirely
/// bone. Neither throws, and neither shows up in a content check that counts entries.
final class ShapeSanityTests: XCTestCase {

    func testEverySpeciesRasterisesToAPlayableFossil() {
        let catalog = ContentCatalog.shared
        var cells: [String: [Int]] = [:]

        for site in catalog.sites {
            for seed in UInt64(0)..<3_000 {
                let layout = SlabGenerator.generate(seed: seed, site: site).layout
                cells[layout.fossilID, default: []].append(layout.boneCells)
            }
        }

        let listed = Set(catalog.sites.flatMap { $0.fossilWeights.keys })
        XCTAssertEqual(
            Set(cells.keys), listed,
            "a listed species never came up in 3,000 slabs a site: "
                + "\(listed.subtracting(cells.keys).sorted())"
        )

        var smallest = (id: "", cells: Int.max)
        var largest = (id: "", cells: 0)
        for (id, counts) in cells {
            let mean = counts.reduce(0, +) / counts.count
            if mean < smallest.cells { smallest = (id, mean) }
            if mean > largest.cells { largest = (id, mean) }

            let name = catalog.fossil(id)?.name ?? id
            // 450, not 60. A hyolith cluster passed the old floor at 118 cells and played
            // as five white specks on a cleared slab -- "what the hell is this garbage",
            // and fairly. 60 cells is half a percent of the grid, which was never a
            // standard; it only ever caught shapes that had failed to rasterise at all.
            XCTAssertGreaterThan(
                mean, 450,
                "\(name) averages \(mean) cells, \(mean * 100 / (SlabGrid.width * SlabGrid.height))% "
                    + "of the slab -- too little to be worth forty seconds"
            )
            XCTAssertLessThan(
                mean, SlabGrid.width * SlabGrid.height / 3,
                "\(name) averages \(mean) cells, a third of the slab or more"
            )
        }
        print("")
        print("  \(cells.count) species rasterised")
        print("  smallest \(smallest.id) at \(smallest.cells) cells")
        print("  largest  \(largest.id) at \(largest.cells) cells")
    }

    /// Two fossils of the same shape with different parameters must not draw identically.
    ///
    /// This is the bug that kept hiding. `crescent` read `taperFrom`/`taperTo`/`bend` while
    /// every crescent in the content specified `thickness`/`sweep`; `segmentedBody` read
    /// `aspect`/`ribs` while every trilobite specified `segments`/`width`/`taper`. Nothing
    /// errored, because a missing key decodes to a plausible default — so twelve crescents
    /// and ten trilobites all drew as the same animal.
    ///
    /// Each time, the tell was a number being *exactly* equal when it had no business
    /// being: four trilobites at 34x16, twelve crescents at 371 cells. That is a test.
    func testFossilsOfAKindWithDifferentParametersDrawDifferently() {
        let catalog = ContentCatalog.shared
        var byShape: [String: [(id: String, params: ShapeParams, cells: Int, box: String)]] = [:]

        for fossil in catalog.fossils {
            var grid = SlabGrid()
            for i in 0..<SlabGrid.cellCount { grid.cells[i].depth = 0 }
            let cells = ShapeRasterizer.rasterize(
                fossil.shape.expand(),
                transform: ShapeTransform(
                    scale: fossil.shape.spanCells / 2, rotation: 0,
                    center: Vec2(Float(SlabGrid.width) / 2, Float(SlabGrid.height) / 2)
                ),
                flag: SlabGrid.Flag.bone, into: &grid
            )
            var minX = SlabGrid.width, maxX = -1, minY = SlabGrid.height, maxY = -1
            for y in 0..<SlabGrid.height {
                for x in 0..<SlabGrid.width where grid.isBone(SlabGrid.index(x, y)) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            byShape[fossil.shape.kind.rawValue, default: []].append(
                (fossil.id, fossil.shape.params, cells, "\(maxX - minX)x\(maxY - minY)")
            )
        }

        for (kind, members) in byShape where members.count > 1 {
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    let a = members[i], b = members[j]
                    guard a.params != b.params else { continue }
                    // Same span *and* same footprint from different parameters means the
                    // generator is not reading them.
                    let sameSpan = catalog.fossil(a.id)?.shape.spanCells
                        == catalog.fossil(b.id)?.shape.spanCells
                    guard sameSpan else { continue }
                    XCTAssertFalse(
                        a.cells == b.cells && a.box == b.box,
                        "\(kind): \(a.id) and \(b.id) have different parameters and draw "
                            + "identically (\(a.cells) cells, \(a.box)) — the generator is "
                            + "reading names the content does not use"
                    )
                }
            }
        }
    }
}
