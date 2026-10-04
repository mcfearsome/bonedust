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
            XCTAssertGreaterThan(
                mean, 60,
                "\(name) averages \(mean) cells, too small to find let alone expose"
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
