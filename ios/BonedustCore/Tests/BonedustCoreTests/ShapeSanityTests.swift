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
}
