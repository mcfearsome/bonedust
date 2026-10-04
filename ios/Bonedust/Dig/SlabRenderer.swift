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

    /// Recomputes the dirty rectangle, inflated by one cell back and two forward.
    ///
    /// The inflation is not paranoia: the ink edge decides a cell from its neighbours,
    /// two behind it (the length of its run) and one ahead (the far side). So clearing
    /// cell *p* changes the appearance of *p-1* and *p+1*, and of *p+2*, whose run it
    /// has just joined, on both axes. Without it, digging leaves a stale seam along
    /// every edge.
    mutating func redraw(_ grid: SlabGrid, region: DirtyRegion) {
        guard !region.isEmpty else { return }
        let x0 = max(0, region.minX - 1)
        let x1 = min(SlabRenderer.width - 1, region.maxX + 2)
        let y0 = max(0, region.minY - 1)
        let y1 = min(SlabRenderer.height - 1, region.maxY + 2)
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

    /// Whether a cell falls on a hatch stripe.
    ///
    /// `(x + y)` is what makes it diagonal; `% 4 < 2` is what makes it 2 on, 2 off.
    /// Internal rather than private so the pattern can be tested directly — the
    /// alternative is reconstructing it from pixel bytes, which tests the test.
    static func isHatched(x: Int, y: Int) -> Bool {
        (x + y) % 4 < 2
    }

    /// Darkens a cell that sits on a hatch stripe, leaves the rest alone.
    static func hatched(_ colour: RGB8, x: Int, y: Int) -> RGB8 {
        isHatched(x: x, y: y) ? colour.lerp(to: Earth.s8, 0.5) : colour
    }

    /// The tell's dot grid: 1 in 4, no two orthogonally adjacent.
    ///
    /// Isolated dots matter. A 50% checkerboard averages back into a flat tint at
    /// this cell size, which is the problem the stipple exists to solve.
    static func isStippled(x: Int, y: Int) -> Bool {
        x % 2 == 0 && y % 2 == 0
    }

    /// Per-cell noise as a stepped shade multiplier rather than a continuous one.
    ///
    /// Returns a multiplier, never a colour, because quantizing colour channels
    /// shifts hue: topsoil (74,52,40) posterized at 8 levels lands on (73,36,36).
    ///
    /// `amount` is the live `SimTuning.cellNoise`. It is passed in rather than read
    /// from `SimTuning.standard` so that the debug overlay's slider reaches it.
    static func celShade(_ noise: Float, amount: Float) -> Float {
        if noise > 0.33 { return 1 - amount }
        if noise < -0.33 { return 1 + amount }
        return 1
    }

    /// Whether this cell takes an ink edge.
    ///
    /// `runBehind` is the length of the run of this material that ends at the cell,
    /// the cell itself included, counted up to 3. Under 3 and the edge is skipped,
    /// so a paper-thin fossil keeps an interior instead of becoming solid outline.
    static func inkEdge(runBehind: Int, neighbourDiffers: Bool) -> Bool {
        neighbourDiffers && runBehind >= 3
    }

    /// A cell on an ink edge: its own colour, most of the way to ink.
    ///
    /// 0.80, not the 0.72 the spec first drew. The edge is drawn before the light level, so on
    /// night_dig it reaches the screen at 0.55 beside a matrix at 0.55, and at 0.72 that pair is
    /// 2.78:1, under the 3:1 `testInkEdgeMakesBoneSeparateFromMatrixOnEverySite` holds it to. At
    /// 0.80 it is 3.14:1, and the day sites go from 4.1-5.5 to 5.4-7.1.
    static func inked(_ colour: RGB8) -> RGB8 {
        colour.lerp(to: Earth.s8, 0.80)
    }

    private static func colour(
        _ grid: SlabGrid, _ x: Int, _ y: Int, _ style: Style
    ) -> RGB8 {
        let index = SlabGrid.index(x, y)
        let cell = grid.cells[index]

        var result = surface(cell, depth: cell.depth, x: x, y: y, style)

        // Wear lerps toward whatever is one layer down, so scraping *shows* before
        // it breaks through. Without this the slab only ever changes in steps and
        // brushing feels unresponsive even though it is working.
        if cell.depth > 0, cell.wear > 0 {
            // Cel: wear advances in four visible steps rather than a gradient. The
            // note above still holds, so the blend stays; only its resolution changes.
            let wear = (cell.wear * 4).rounded() / 4
            result = result.lerp(
                to: surface(cell, depth: cell.depth - 1, x: x, y: y, style),
                wear * style.tuning.wearColorBlend
            )
        }

        // A semantic edge, drawn from flags rather than colour difference — which is
        // why this is on the CPU. A fragment shader cannot tell gem-on-matrix from a
        // noise boundary. Right and bottom only: two sides read as ink without eating
        // a thin specimen from both ends. This replaced a lit top edge and a shadowed
        // bottom edge, which gave the fossil relief at 96x128 but never separated
        // pale bone from a pale matrix. It draws before the hatch below, so a cracked
        // cell on an edge carries both marks.
        if cell.depth == 0, cell.flags & (SlabGrid.Flag.bone | SlabGrid.Flag.gem) != 0 {
            let mine = cell.flags & SlabGrid.Flag.bone != 0
                ? SlabGrid.Flag.bone : SlabGrid.Flag.gem
            func same(_ dx: Int, _ dy: Int) -> Bool {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < SlabRenderer.width, ny >= 0, ny < SlabRenderer.height
                else { return false }
                let neighbour = grid.cells[SlabGrid.index(nx, ny)]
                return neighbour.depth == 0 && neighbour.flags & mine != 0
            }
            let right = SlabRenderer.inkEdge(
                runBehind: same(-1, 0) ? (same(-2, 0) ? 3 : 2) : 1,
                neighbourDiffers: !same(1, 0)
            )
            let down = SlabRenderer.inkEdge(
                runBehind: same(0, -1) ? (same(0, -2) ? 3 : 2) : 1,
                neighbourDiffers: !same(0, 1)
            )
            if right || down { result = SlabRenderer.inked(result) }
        }

        // Fracture leaves a permanent record on the page. The transient red bloom is
        // the alarm; this is the annotation that stays. See spec §5.
        if cell.flags & SlabGrid.Flag.cracked != 0 {
            result = SlabRenderer.hatched(result, x: x, y: y)
        }

        if style.revealBuriedBone, cell.depth > 0, cell.flags & SlabGrid.Flag.bone != 0 {
            result = result.lerp(to: style.palette.bone, 0.5)
        }

        // The live tuning, not `SimTuning.standard`: the debug overlay's Cell noise
        // slider has to reach this.
        result = result.scaled(
            SlabRenderer.celShade(cell.noise, amount: style.tuning.cellNoise)
        )
        if style.lightLevel != 1 { result = result.scaled(style.lightLevel) }
        return result
    }

    /// What a cell looks like once cleared to `depth`, before wear and noise. `x` and
    /// `y` place the cell on the tell's dot grid.
    private static func surface(
        _ cell: SlabGrid.Cell, depth: UInt8, x: Int, y: Int, _ style: Style
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
        // The tell, from §3: the only legitimate way to read the fossil before
        // exposing it, and learning to see it is the difference between a careful
        // player and a fast one. Depth-1 sandstone sitting on bone goes toward bone.
        // It ships as a tint, which keeps the specimen's internal structure readable
        // (a fin's rays); the stipple is the alternative, one slider away. Both
        // constants stay live so the debug overlay can A/B them. See spec §7a.
        if depth == 1, cell.flags & SlabGrid.Flag.bone != 0 {
            if style.tuning.boneTellTint > 0 {
                layer = layer.lerp(to: palette.bone, style.tuning.boneTellTint)
            }
            if style.tuning.boneTellStipple > 0, SlabRenderer.isStippled(x: x, y: y) {
                layer = layer.lerp(to: palette.bone, style.tuning.boneTellStipple)
            }
        }
        return layer
    }

    /// Dust colour for the layer currently being removed.
    func dustColour(forLayer depth: UInt8) -> RGB8 {
        palette.layerColor(depth: depth).scaled(lightLevel)
    }
}
