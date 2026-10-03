/// The slab: a 96 x 128 cell grid, stored as one contiguous array of structs.
///
/// Array-of-structs rather than struct-of-arrays is deliberate. Both the brush and
/// the renderer walk a small 2D neighbourhood and need `depth`, `flags`, `wear` and
/// `noise` for each cell they touch, so interleaving them means one cache line
/// fetch serves all four fields. It also means the hot loop needs exactly one
/// `withUnsafeMutableBufferPointer`, instead of nesting four of them and fighting
/// the exclusivity checker.
public struct SlabGrid: Sendable {

    public static let width = 96
    public static let height = 128
    public static let cellCount = width * height

    /// 12 bytes with padding; the whole grid is ~144 KB and stays in L2.
    public struct Cell: Sendable, Equatable {
        /// 3 = topsoil, 2 = clay, 1 = sandstone, 0 = exposed.
        public var depth: UInt8
        public var flags: UInt8
        /// Progress through the current layer, 0 ..< 1.
        public var wear: Float
        /// Cosmetic, -1 ... 1.
        public var noise: Float

        public init(depth: UInt8 = 3, flags: UInt8 = 0, wear: Float = 0, noise: Float = 0) {
            self.depth = depth
            self.flags = flags
            self.wear = wear
            self.noise = noise
        }
    }

    public enum Flag {
        public static let bone: UInt8 = 1 << 0
        public static let cracked: UInt8 = 1 << 1
        public static let rock: UInt8 = 1 << 2
        public static let gem: UInt8 = 1 << 3
    }

    public var cells: ContiguousArray<Cell>

    public init() {
        self.cells = ContiguousArray(repeating: Cell(), count: SlabGrid.cellCount)
    }

    @inline(__always)
    public static func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    @inline(__always)
    public static func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Cell {
        get { cells[SlabGrid.index(x, y)] }
        set { cells[SlabGrid.index(x, y)] = newValue }
    }

    @inline(__always)
    public func isBone(_ i: Int) -> Bool { cells[i].flags & Flag.bone != 0 }
    @inline(__always)
    public func isCracked(_ i: Int) -> Bool { cells[i].flags & Flag.cracked != 0 }
    @inline(__always)
    public func isRock(_ i: Int) -> Bool { cells[i].flags & Flag.rock != 0 }
    @inline(__always)
    public func isGem(_ i: Int) -> Bool { cells[i].flags & Flag.gem != 0 }
    @inline(__always)
    public func isExposed(_ i: Int) -> Bool { cells[i].depth == 0 }

    public func count(where predicate: (Cell) -> Bool) -> Int {
        var n = 0
        for cell in cells where predicate(cell) { n += 1 }
        return n
    }
}

/// An inclusive rectangle of cells that changed since the renderer last looked.
public struct DirtyRegion: Sendable, Equatable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public static let empty = DirtyRegion(minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var isEmpty: Bool { minX > maxX || minY > maxY }
    public var width: Int { isEmpty ? 0 : maxX - minX + 1 }
    public var height: Int { isEmpty ? 0 : maxY - minY + 1 }

    @inline(__always)
    public mutating func insert(x: Int, y: Int) {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }

    public static let everything = DirtyRegion(
        minX: 0, minY: 0, maxX: SlabGrid.width - 1, maxY: SlabGrid.height - 1
    )
}
