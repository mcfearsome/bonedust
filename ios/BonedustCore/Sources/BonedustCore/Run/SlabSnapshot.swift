import Foundation

/// A dig in progress, small enough to write on every app background.
///
/// §5 requires that killing the app mid-slab restores the slab with daylight paused.
/// Three things make that safe:
///
/// 1. **Only the mutable part is stored.** The slab is regenerated from its seed on
///    restore, which brings back the bone mask, the nodules, the gem clusters and the
///    cosmetic noise field for free. Six bytes per cell go to disk instead of twelve,
///    and the texture comes back looking identical rather than merely similar.
/// 2. **The PRNG position is stored.** Without it, relaunching re-rolls every
///    subsequent crack, which is a save-scum hole dressed up as a restore.
/// 3. **The regenerated bone mask is checked against the saved one.** If a content
///    update retuned a fossil's shape, the masks disagree, the save is refused, and
///    the player gets a fresh slab — instead of a dig whose `boneCells` no longer
///    matches the bone actually on screen, which would quietly corrupt every payout.
public struct SlabSnapshot: Sendable, Codable, Equatable {

    public static let currentSchema = 1
    /// depth (1) + flags (1) + wear (4).
    public static let bytesPerCell = 6

    public var schema: Int
    public var seed: UInt64
    public var siteID: String
    public var randomState: UInt64
    public var daylightRemaining: Float
    public var toolID: String
    public var day: Int
    public var cells: Data

    public enum Failure: Error, Equatable {
        case schemaMismatch(found: Int, expected: Int)
        case unknownSite(String)
        case truncated(found: Int, expected: Int)
        /// The slab no longer generates the same fossil. A content update landed.
        case contentChanged
    }

    // MARK: Capture

    public static func capture(
        _ sim: SlabSimulation,
        daylightRemaining: Float,
        toolID: String,
        day: Int
    ) -> SlabSnapshot {
        var bytes = Data(capacity: SlabGrid.cellCount * bytesPerCell)
        for cell in sim.grid.cells {
            bytes.append(cell.depth)
            bytes.append(cell.flags)
            var pattern = cell.wear.bitPattern.littleEndian
            withUnsafeBytes(of: &pattern) { bytes.append(contentsOf: $0) }
        }
        return SlabSnapshot(
            schema: currentSchema,
            seed: sim.layout.seed,
            siteID: sim.layout.siteID,
            randomState: sim.randomState,
            daylightRemaining: daylightRemaining,
            toolID: toolID,
            day: day,
            cells: bytes
        )
    }

    // MARK: Restore

    public struct Restored: Sendable {
        public var simulation: SlabSimulation
        public var tool: BrushTool
        public var daylightRemaining: Float
        public var day: Int
    }

    public func restore(
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) throws -> Restored {
        guard schema == SlabSnapshot.currentSchema else {
            throw Failure.schemaMismatch(found: schema, expected: SlabSnapshot.currentSchema)
        }
        let expectedBytes = SlabGrid.cellCount * SlabSnapshot.bytesPerCell
        guard cells.count == expectedBytes else {
            throw Failure.truncated(found: cells.count, expected: expectedBytes)
        }
        guard let site = catalog.site(siteID) else { throw Failure.unknownSite(siteID) }

        var generated = SlabGenerator.generate(
            seed: seed, site: site, catalog: catalog, tuning: tuning
        )

        // Everything except `cracked` is a product of generation, so it must still
        // match. If it does not, the content changed under the save.
        let structural = ~SlabGrid.Flag.cracked
        // Returning a Bool rather than throwing from inside the closure: Data's
        // throwing and non-throwing withUnsafeBytes overloads are ambiguous when the
        // body throws and the result type has to be inferred.
        let structureMatches = cells.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            for index in 0..<SlabGrid.cellCount {
                let offset = index * SlabSnapshot.bytesPerCell
                let savedFlags = raw[offset + 1]
                if savedFlags & structural != generated.grid.cells[index].flags & structural {
                    return false
                }
            }
            return true
        }
        guard structureMatches else { throw Failure.contentChanged }

        cells.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<SlabGrid.cellCount {
                let offset = index * SlabSnapshot.bytesPerCell
                generated.grid.cells[index].depth = raw[offset]
                generated.grid.cells[index].flags = raw[offset + 1]
                var pattern: UInt32 = 0
                withUnsafeMutableBytes(of: &pattern) { destination in
                    for byte in 0..<4 { destination[byte] = raw[offset + 2 + byte] }
                }
                generated.grid.cells[index].wear = Float(bitPattern: UInt32(littleEndian: pattern))
            }
        }

        var simulation = SlabSimulation(
            grid: generated.grid,
            layout: generated.layout,
            tuning: tuning,
            randomState: randomState
        )
        // Modifiers are composed by the run layer and are not part of the grid, so
        // the site and fossil contributions have to be re-applied here. Forgetting
        // this changes the physics of a restored dig silently.
        let fossilCrack = catalog.fossil(generated.layout.fossilID)?.crackMultiplier ?? 1
        simulation.crackMultiplier = site.modifiers.crackMultiplier * fossilCrack

        let tool = BrushTool.all.first { $0.id == toolID } ?? .brush
        return Restored(
            simulation: simulation,
            tool: tool,
            daylightRemaining: daylightRemaining,
            day: day
        )
    }
}
