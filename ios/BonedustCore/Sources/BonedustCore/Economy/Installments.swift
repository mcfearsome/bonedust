import Foundation

/// What the Collector wants, run after run. This curve *is* the difficulty ramp:
/// there is no enemy scaling in Bonedust, only a rising number.
///
/// Hand-authored for the first eight tiers so the early ramp can be shaped by feel
/// rather than by a formula, then geometric so it never runs out. The acceptance
/// target in §9 is a ~70% win rate at tier 1 falling to ~30% by tier 5, which is
/// what `bonedust-tool simulate` measures against this table.
public enum Installments {
    public static let table = [350, 450, 600, 800, 1050, 1400, 1850, 2450]
    public static let growth: Float = 1.32

    /// `tier` is 1-based: tier 1 is a player's first run.
    public static func amount(tier: Int) -> Int {
        let t = max(1, tier)
        if t <= table.count { return table[t - 1] }
        var value = Float(table[table.count - 1])
        for _ in table.count..<t { value *= growth }
        return Int((value / 25).rounded()) * 25
    }

    /// Leftover cash becomes Reputation at 10:1 (§4).
    public static func reputation(fromLeftoverCash cash: Int) -> Int {
        max(0, cash / 10)
    }
}
