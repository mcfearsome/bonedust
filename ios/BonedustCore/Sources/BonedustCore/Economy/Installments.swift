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
    /// Re-fitted after `removalRate` doubled. The old ramp was measured against a
    /// simulated player who could not be matched by hand, so it was simultaneously too
    /// hard to actually play and too easy for the model once the brush worked.
    ///
    /// The ramp has to cross the mean income per tier: below it early, above it later,
    /// which is what turns a 70% week into a 30% one.
    ///
    /// It climbs much faster than it used to because a week is no longer a fixed five days.
    /// `RunLength` gives later tiers more of them, and run income scales with days while
    /// the money per slab stays roughly flat -- so the amount owed has to scale with days
    /// too, or the extra time is a pure gift and the difficulty curve inverts.
    /// Fitted to §9's two stated numbers — tier 1 near 70%, tier 5 near 30% — and
    /// geometric in between rather than fitted tier by tier.
    ///
    /// The middle stays lumpy on purpose. Mean income jumps from about $720 at tier 3 to
    /// $1,170 at tier 4 because a site unlocks there, so smooth win rates would need a
    /// ramp that jumps to match. A difficulty curve that lurches to flatten a graph is
    /// fitting the model player rather than the game.
    public static let table = [450, 550, 1150, 1825, 2900, 3150, 3700, 4000]
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
