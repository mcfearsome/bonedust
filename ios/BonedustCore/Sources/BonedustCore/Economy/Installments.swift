import Foundation

/// What the Collector wants, run after run. This curve *is* the difficulty ramp:
/// there is no enemy scaling in Bonedust, only a rising number.
///
/// Hand-authored for the first eight tiers so the early ramp can be shaped by feel
/// rather than by a formula, then geometric so it never runs out. The acceptance
/// target in §9 is a ~70% win rate at tier 1 falling to ~30% by tier 5, which is
/// what `bonedust-tool simulate` measures against this table.
///
/// The brief offered `350, 450, 600, 800, 1050` as a sample and marked the exact curve
/// `[DECIDE]`. That ramp climbs about 30% a tier, and measured income climbs nowhere
/// near that fast, so it put tier 3 at a 5% win rate against a 48% target. This curve
/// climbs about 22%, which is what the economy can actually support.
public enum Installments {
    public static let table = [350, 450, 575, 725, 900, 1100, 1350, 1650]
    public static let growth: Float = 1.22

    /// `tier` is 1-based: tier 1 is a player's first run.
    public static func amount(tier: Int) -> Int {
        let t = max(1, tier)
        if t <= table.count { return table[t - 1] }
        var value = Float(table[table.count - 1])
        for _ in table.count..<t { value *= growth }
        return Int((value / 25).rounded()) * 25
    }

    /// Leftover cash becomes Reputation at 10:1 (§4), plus a flat award for clearing
    /// the tier at all.
    ///
    /// The 10:1 rate alone made the site gates unreachable: a tier 1 win leaves about
    /// $110 over, so ten Reputation a run, so twenty successful runs to see Wheeler
    /// Shale and sixty to see Green River. The flat component scales with the tier, so
    /// surviving a harder week is what actually opens the map — which is also the thing
    /// the player is proud of.
    public static func reputation(fromLeftoverCash cash: Int, tier: Int = 1) -> Int {
        max(0, cash / 10) + 15 * max(1, tier)
    }
}
