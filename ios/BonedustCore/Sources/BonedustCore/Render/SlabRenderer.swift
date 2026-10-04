import Foundation

/// Turns the cell grid into a 96x128 RGBA buffer.
///
/// Lives in the package rather than the app because it imports nothing but Foundation —
/// which means `bonedust-tool render` can produce actual slab images headlessly. Being
/// able to *look* at the output is worth more than any assertion about it: the palette, the
/// depth-1 bone tell and the edge shading are all judgements the eye makes and a test
/// cannot.
///
/// The buffer is CPU-side and persistent: only cells inside the dirty rectangle are
/// recomputed, then the whole 48 KB is memcpy'd into the SpriteKit texture. Copying
/// all of it every frame costs a few microseconds and avoids having to reason about
/// whether `SKMutableTexture` preserved our previous contents.
///
/// All colour decisions live here and all colour *values* live in `SlabPalette`,
/// which is content data. This file decides how layers blend; the site decides what
/// colour its clay is.
public struct SlabRenderer {

    public static let width = SlabGrid.width
    public static let height = SlabGrid.height
    public static let bytesPerPixel = 4

    public var palette: SlabPalette
    public var tuning: SimTuning
    /// Night digs dim everything. 1.0 is full daylight.
    public var lightLevel: Float = 1
    /// X-ray goggles: shows buried bone through the matrix for a few seconds.
    public var revealBuriedBone = false
    /// Debug: paints unmistakable markers so the slab's orientation on screen can be read
    /// at a glance.
    ///
    /// This exists because the orientation bug could not be settled from here. Whether
    /// `SKMutableTexture` treats the first row of data as the top or the bottom is a
    /// question about a framework, and `SKTexture.cgImage()` cannot answer it: row 0 landing
    /// at the CGImage's bottom is equally consistent with "the texture is bottom-up" and
    /// "the texture is top-up and cgImage flips it". Both hypotheses predicted the
    /// measurement, so the measurement decided nothing and a wrong fix shipped.
    ///
    /// Red across the top six rows, green down the left six columns. Where those land on a
    /// real screen is not ambiguous.
    public var orientationProbe = false
    /// Advances the gem shimmer. Seconds since the dig began.
    ///
    /// A gem is worth going carefully around, so it has to be *noticed* — and a static
    /// teal square at 96x128 reads as another mineral stain. Catching the light is what
    /// makes it read as a gem rather than a colour.
    public var sparkleTime: Float = 0

    public private(set) var pixels: [UInt8]

    public init(palette: SlabPalette = .standard, tuning: SimTuning = .standard) {
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
        let orientationProbe: Bool
        let sparkleTime: Float
    }

    private var style: Style {
        Style(
            palette: palette,
            tuning: tuning,
            lightLevel: lightLevel,
            revealBuriedBone: revealBuriedBone,
            orientationProbe: orientationProbe,
            sparkleTime: sparkleTime
        )
    }

    /// Recomputes the dirty rectangle, inflated by one cell.
    ///
    /// The inflation is not paranoia: bone edge shading reads the cells above and
    /// below, so clearing cell *y* changes the appearance of *y-1* and *y+1* too.
    /// Without it, digging leaves a one-pixel stale seam along every edge.
    public mutating func redraw(_ grid: SlabGrid, region: DirtyRegion) {
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

    public mutating func redrawEverything(_ grid: SlabGrid) {
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
            // A cell with bone on neither side is a one-cell-wide feature, not an edge.
            // Applying both adjustments to it multiplied out to 0.963 — slightly *darker*
            // than plain bone — which is exactly the fine ribs of a Knightia and the veins
            // of a leaf, the two most fragile things in the game, rendered at their least
            // visible on the darkest site. Shading needs a surface to shade.
            if boneAbove != boneBelow {
                result = result.scaled(boneAbove ? 0.86 : 1.12)
            }
        }

        if style.revealBuriedBone, cell.depth > 0, cell.flags & SlabGrid.Flag.bone != 0 {
            result = result.lerp(to: style.palette.bone, 0.5)
        }

        result = result.scaled(1 + cell.noise * style.tuning.cellNoise)
        if style.lightLevel != 1 { result = result.scaled(style.lightLevel) }

        // Only over rock that has not been dug, so a trench brushed through a band still
        // shows. That makes one gesture answer both halves of the question: where the grid
        // is drawn, and where a finger lands in it.
        if style.orientationProbe, cell.depth > 0 {
            // Drawn last so nothing can wash it out, and in grid coordinates, so it goes
            // through exactly the same upload path as the slab itself.
            if y < 6 { return RGB8(255, 32, 32) }
            if x < 6 { return RGB8(32, 255, 32) }
        }
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
            if cell.flags & SlabGrid.Flag.gem != 0 {
                // Each cell twinkles on its own schedule, phased by the noise field that
                // is already there. A cluster flashing in unison reads as a UI element
                // blinking; cells catching the light one after another reads as a facet.
                let phase = style.sparkleTime * 2.4 + cell.noise * 12
                let twinkle = sinf(phase)
                // Sharpened so it is dark most of the time and bright briefly, which is
                // what a facet does. A plain sine just looks like it is pulsing.
                let glint = max(0, twinkle * twinkle * twinkle)
                return palette.gem.scaled(1 + glint * 0.55)
            }
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

    /// Copies the buffer out with its rows reversed, for a GPU texture.
    ///
    /// Everything in Bonedust treats y as running *down*: grid row 0 is the top of the
    /// slab, `SlabGenerator` lays fossils out that way, `gridPoint` maps a touch near the
    /// top of the screen to row 0, and the edge shading lights bone from above. GPU
    /// textures inherited the opposite convention from OpenGL, and `SKMutableTexture` is no
    /// exception — `TextureOrientationTests` measures it rather than trusting anyone's
    /// memory of it.
    ///
    /// Reconciling the two here, in the one function that hands bytes to a framework, is
    /// what keeps that convention out of the simulation, the generator, the touch mapping
    /// and every test. The alternative — `node.yScale = -1` — is one character shorter and
    /// makes the scene graph lie about which way up it is, so every child node added later
    /// has to know.
    ///
    /// Costs 128 memcpys of 384 bytes instead of one of 48 KB, which does not register
    /// against a 16 ms budget.
    public func copyRowsBottomUp(into destination: UnsafeMutableRawPointer, length: Int) {
        let rowBytes = SlabRenderer.width * SlabRenderer.bytesPerPixel
        let rows = min(SlabRenderer.height, length / rowBytes)
        guard rows > 0 else { return }
        let out = destination.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for y in 0..<rows {
                memcpy(
                    out + y * rowBytes,
                    base + (SlabRenderer.height - 1 - y) * rowBytes,
                    rowBytes
                )
            }
        }
    }

    /// Dust colour for the layer currently being removed.
    public func dustColour(forLayer depth: UInt8) -> RGB8 {
        palette.layerColor(depth: depth).scaled(lightLevel)
    }
}
