/// Deterministic PRNG for everything the simulation randomises.
///
/// Two rules make this port-able to Ruby for the server-side plausibility check
/// in §6, and both are load-bearing:
///
/// 1. `nextUnit()` takes the top 24 bits and divides by 2^24. Ruby's Integer
///    arithmetic reproduces that exactly; converting the full 64 bits to a
///    `Double` and dividing would not round identically across languages.
/// 2. `nextInt(below:)` uses plain modulo. It has the usual modulo bias, which is
///    irrelevant for picking a fossil out of a table of six, and it is one line in
///    any language. Rejection sampling would be "better" and would be a parity bug
///    waiting to happen.
///
/// Never call `random()`, `Int.random`, or `SystemRandomNumberGenerator` anywhere
/// in this module. The replay test in `DeterminismTests` is what catches it.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)` with 24 bits of precision.
    public mutating func nextUnit() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// Uniform in `[lower, upper)`.
    public mutating func nextFloat(_ lower: Float, _ upper: Float) -> Float {
        lower + nextUnit() * (upper - lower)
    }

    /// Uniform in `0 ..< bound`. Returns 0 for a non-positive bound.
    public mutating func nextInt(below bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    /// Uniform in `lower ... upper`, inclusive of both ends.
    public mutating func nextInt(_ lower: Int, through upper: Int) -> Int {
        guard upper > lower else { return lower }
        return lower + nextInt(below: upper - lower + 1)
    }

    /// Derives an independent stream from this one. Used so that gameplay
    /// randomness (crack walks) cannot desynchronise generation randomness.
    public mutating func fork() -> SplitMix64 {
        SplitMix64(seed: next())
    }
}
