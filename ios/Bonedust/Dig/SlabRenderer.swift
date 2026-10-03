import BonedustCore
import Foundation

/// Turns the cell grid into a 96x128 RGBA buffer.
///
/// The buffer is CPU-side and persistent: only cells inside the dirty rectangle are
/// recomputed, then the whole 48 KB is memcpy'd into the SpriteKit texture. Copying
/// all of it every frame costs a few microseconds and avoids having to reason about
/// whether `SKMutableTexture` preserved our previous contents.
///
/// All colour decisions live here and all colour *values* live in `SlabPalette`,
/// which is content data. This file decides how layers blend; the site decides what
/// colour its clay is.
struct SlabRenderer {

    static let width = SlabGrid.width
    static let height = SlabGrid.height
    static let bytesPerPixel = 4

    var palette: SlabPalette
    var tuning: SimTuning
    /// Night digs dim everything. 1.0 is full daylight.
    var lightLevel: Float = 1
    /// X-ray goggles: shows buried bone through the matrix for a few seconds.
    var revealBuriedBone = false

    private(set) var pixels: [UInt8]

    init(palette: SlabPalette = .standard, tuning: SimTuning = .standard) {
        self.palette = palette
        self.tuning = tuning
        self.pixels = [UInt8](
            repeating: 255,
            count: SlabRenderer.width * SlabRenderer.height * SlabRenderer.bytesPerPixel
        )
    }

    /// The colour inputs, bundled so the pixel loop can take them as a value.
    ///
    /// This exists because `redraw` holds exclusive access to `self.pixels` for the
    /// duration of the loop, and calling *any* method on `self` inside that closure is
    /// an overlapping access. Passing the style through explicitly is what makes the
    /// per-cell work callable from in there.
    private struct Style {
        let palette: SlabPalette
        let tuning: SimTuning
        let lightLevel: Float
        let revealBuriedBone: Bool
    }

    private var style: Style {
        Style(
            palette: palette,
            tuning: tuning,
            lightLevel: lightLevel,
            revealBuriedBone: revealBuriedBone
        )
    }

    /// Recomputes the dirty rectangle, inflated by one cell.
    ///
    /// The inflation is not paranoia: bone edge shading reads the cells above and
    /// below, so clearing cell *y* changes the appearance of *y-1* and *y+1* too.
    /// Without it, digging leaves a one-pixel stale seam along every edge.
    mutating func redraw(_ grid: SlabGrid, region: DirtyRegion) {
        guard !region.isEmpty else { return }
        let x0 = max(0, region.minX - 1)
        let x1 = min(SlabRenderer.width - 1, region.maxX + 1)
        let y0 = max(0, region.minY - 1)
        let y1 = min(SlabRenderer.height - 1, region.maxY + 1)
        guard x0 <= x1, y0 <= y1 else { return }
        let style = self.style

        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in y0...y1 {
                for x in x0...x1 {
                    let colour = SlabRenderer.colour(grid, x, y, style)
                    let offset = (y * SlabRenderer.width + x) * SlabRenderer.bytesPerPixel
                    buffer[offset] = colour.r
                    buffer[offset + 1] = colour.g
                    buffer[offset + 2] = colour.b
                    buffer[offset + 3] = 255
                }
            }
        }
    }

    mutating func redrawEverything(_ grid: SlabGrid) {
        redraw(grid, region: .everything)
    }

    // MARK: - Per-cell colour

    private static func colour(
        _ grid: SlabGrid, _ x: Int, _ y: Int, _ style: Style
    ) -> RGB8 {
        let index = SlabGrid.index(x, y)
        let cell = grid.cells[index]

        var result = surface(cell, depth: cell.depth, style)

        // Wear lerps toward whatever is one layer down, so scraping *shows* before
        // it breaks through. Without this the slab only ever changes in steps and
        // brushing feels unresponsive even though it is working.
        if cell.depth > 0, cell.wear > 0 {
            result = result.lerp(
                to: surface(cell, depth: cell.depth - 1, style),
                cell.wear * style.tuning.wearColorBlend
            )
        }

        // Bone edge shading: a lit top edge and a shadowed bottom edge give the
        // fossil relief at 96x128, where there is no room for an outline.
        if cell.depth == 0, cell.flags & SlabGrid.Flag.bone != 0 {
            let boneAbove = y > 0 && grid.isBone(SlabGrid.index(x, y - 1))
            let boneBelow = y < SlabRenderer.height - 1
                && grid.isBone(SlabGrid.index(x, y + 1))
            if !boneAbove { result = result.scaled(1.12) }
            if !boneBelow { result = result.scaled(0.86) }
        }

        if style.revealBuriedBone, cell.depth > 0, cell.flags & SlabGrid.Flag.bone != 0 {
            result = result.lerp(to: style.palette.bone, 0.5)
        }

        result = result.scaled(1 + cell.noise * style.tuning.cellNoise)
        if style.lightLevel != 1 { result = result.scaled(style.lightLevel) }
        return result
    }

    /// What a cell looks like once cleared to `depth`, before wear and noise.
    private static func surface(
        _ cell: SlabGrid.Cell, depth: UInt8, _ style: Style
    ) -> RGB8 {
        let palette = style.palette
        guard depth > 0 else {
            if cell.flags & SlabGrid.Flag.bone != 0 {
                return cell.flags & SlabGrid.Flag.cracked != 0
                    ? palette.crackedBone
                    : palette.bone
            }
            if cell.flags & SlabGrid.Flag.gem != 0 { return palette.gem }
            var matrix = palette.matrix
            if cell.flags & SlabGrid.Flag.rock != 0 {
                matrix = matrix.lerp(to: palette.rock, 0.5)
            }
            return matrix
        }

        var layer = palette.layerColor(depth: depth)
        if cell.flags & SlabGrid.Flag.rock != 0 {
            layer = layer.lerp(to: palette.rock, 0.45)
        }
        // The tell, from §3: depth-1 sandstone sitting on bone is tinted 20% toward
        // bone. It is the only legitimate way to read the fossil before exposing it,
        // and learning to see it is the difference between a careful player and a
        // fast one.
        if depth == 1, cell.flags & SlabGrid.Flag.bone != 0 {
            layer = layer.lerp(to: palette.bone, style.tuning.boneTellTint)
        }
        return layer
    }

    /// Dust colour for the layer currently being removed.
    func dustColour(forLayer depth: UInt8) -> RGB8 {
        palette.layerColor(depth: depth).scaled(lightLevel)
    }
}
