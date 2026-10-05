/// What one touch-move did to the slab. The renderer turns this into dust, the
/// haptics engine into texture and transients, the audio engine into timbre.
///
/// Counters are flat scalars rather than arrays or dictionaries because this is
/// produced on every touch event, sixty times a second, and an allocation per
/// event is an allocation per frame.
public struct StrokeResult: Sendable, Equatable {
    /// Cells that gained any wear at all.
    public var cellsWorn = 0
    /// Total depth decrements across all cells.
    public var layersRemoved = 0
    public var removedTopsoil = 0
    public var removedClay = 0
    public var removedSandstone = 0
    public var boneRevealed = 0
    public var gemCellsRevealed = 0
    public var gemsCompleted = 0
    public var cracksStarted = 0
    public var cellsCracked = 0
    public var rockCellsCleared = 0
    /// The smoothed speed used for this stroke's crack rolls, in cells per frame.
    public var speed: Float = 0
    /// How far the finger moved, in cells.
    public var distance: Float = 0
    /// First cell index where a crack began this stroke, for a located haptic.
    public var firstCrackCell: Int?
    /// The sums of the x and y of every cell this stroke cracked. Two scalars for the same reason
    /// as the counters above: a list of positions would allocate on every touch event. Read them
    /// through `crackCentroid`.
    public var crackedCellSumX = 0
    public var crackedCellSumY = 0

    public init() {}

    /// The centre of every cell this stroke cracked, in grid units, or `nil` if it cracked none.
    ///
    /// One position per stroke however many cracks it started, so a single alarm can mark what
    /// broke rather than the finger that broke it: with the air blower the two can be most of a
    /// brush radius apart. The `+ 0.5` puts it in the middle of the cells, like a touch point,
    /// instead of on the corner of the cell an index names.
    public var crackCentroid: Vec2? {
        guard cellsCracked > 0 else { return nil }
        let count = Float(cellsCracked)
        return Vec2(Float(crackedCellSumX) / count + 0.5, Float(crackedCellSumY) / count + 0.5)
    }

    /// Which layer the dust should be tinted as: whichever gave up the most cells.
    public var dominantLayer: UInt8? {
        if removedTopsoil >= removedClay, removedTopsoil >= removedSandstone {
            return removedTopsoil > 0 ? 3 : nil
        }
        if removedClay >= removedSandstone {
            return removedClay > 0 ? 2 : nil
        }
        return removedSandstone > 0 ? 1 : nil
    }

    public var didAnything: Bool { cellsWorn > 0 || cellsCracked > 0 }
}
