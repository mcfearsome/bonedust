import Foundation

/// How many days a week is, and how one more gets earned.
///
/// Five was a constant for six milestones and it was too short to acquire anything: the
/// tent opens four times, kit is lost on a failed run, and most of what a player bought
/// they barely got to use. Length now rises with the tier, so the ramp gives time as well
/// as taking money, and the two move together instead of difficulty only ever going up.
///
/// The base stays 5 at tier 1 on purpose. A first run has to be short, because the thing a
/// new player most needs is to find out quickly that they lost and start again — and §9's
/// 8-to-10 minute target is about the first run, not the twentieth.
public enum RunLength {

    /// Days at each tier. Grows by a day every two tiers, which is slow enough that no
    /// single promotion changes what a run *is*.
    public static let table = [5, 5, 6, 6, 7, 7, 8, 8]
    /// Days added per two tiers beyond the table.
    public static let growthPerTwoTiers = 1
    /// The longest a week can get, earned days included.
    ///
    /// Without a ceiling an extra day is pure profit — more income at no extra cost — so a
    /// good enough player extends forever and the installment stops being a deadline. The
    /// cap is what keeps a week a week.
    public static let maximumDays = 12

    /// `tier` is 1-based.
    public static func days(tier: Int) -> Int {
        let t = max(1, tier)
        if t <= table.count { return table[t - 1] }
        let beyond = t - table.count
        let extra = (beyond + 1) / 2 * growthPerTwoTiers
        return min(maximumDays, table[table.count - 1] + extra)
    }

    /// Extra days a single run can earn on top of its length.
    ///
    /// Three. Enough that a run of good digs is visibly longer and worth chasing; few
    /// enough that the week still ends.
    public static let maximumEarnedDays = 3

    /// Whether a slab's grade is good enough to buy another day.
    ///
    /// S only. A reward that lands most slabs is not a reward, it is inflation — and the
    /// grade is weighted so that an S needs a slab cleared *and* unbroken *and* finished
    /// with daylight to spare, which is the hardest thing the game asks for.
    public static func earnsADay(_ grade: SlabGrade.Letter) -> Bool { grade == .s }
}
