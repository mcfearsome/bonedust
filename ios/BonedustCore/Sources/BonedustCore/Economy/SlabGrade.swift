import Foundation

/// How well a slab was dug, as one letter.
///
/// Three numbers already described a finished slab — how much fossil was uncovered, how
/// much of it survived, and how much daylight was left — and the player had to hold all
/// three at once to know whether they had done well. The grade collapses them into the
/// judgement the game is actually making.
///
/// **Care outweighs speed, deliberately.** Exposure and intactness carry 40% each; the
/// clock carries 20%. A grade that paid mostly for speed would argue against the one thing
/// the whole game is about, which is that brushing faster cracks bone.
///
/// **The clock is what actually discriminates.** A competent dig finishes near 0.97
/// exposure and 0.99 intact whatever else happened, so those two are nearly constant across
/// good play and cannot separate it. Daylight left is the term that moves, which is why 20%
/// is enough weight to matter: an S needs a slab cleared *and* unbroken *and* finished with
/// time to spare, which is a genuinely hard thing to do.
///
/// **The bonus multiplies fossil and gem money rather than adding a flat sum.** A flat
/// bonus is worth proportionally more on a cheap slab, so the best way to farm it would be
/// to dig the least valuable fossil available — the exact opposite of the intended lesson.
public struct SlabGrade: Sendable, Equatable {

    public enum Letter: String, Sendable, Codable, CaseIterable {
        case s = "S", a = "A", b = "B", c = "C", d = "D"
    }

    /// 0 to 1: the weighted blend of exposure, intactness and daylight saved.
    public var score: Float
    public var letter: Letter
    /// What fossil and gem money is multiplied by. 1.0 means no bonus.
    public var bonusMultiplier: Float

    public init(score: Float, letter: Letter, bonusMultiplier: Float) {
        self.score = score
        self.letter = letter
        self.bonusMultiplier = bonusMultiplier
    }

    /// Grades a finished slab.
    ///
    /// `daylightRemaining` and `totalDaylight` are taken separately rather than as a ratio
    /// because the total moves with charms and with the night-dig twist. Scoring against a
    /// fixed sixty seconds would mark down every night dig, which starts with less daylight
    /// and has not been dug any worse for it.
    public static func of(
        exposure: Float,
        intact: Float,
        daylightRemaining: Float,
        totalDaylight: Float,
        tuning: SimTuning = .standard
    ) -> SlabGrade {
        let exposure = min(max(exposure, 0), 1)
        let intact = min(max(intact, 0), 1)
        let speed = totalDaylight > 0
            ? min(max(daylightRemaining / totalDaylight, 0), 1)
            : 0

        // A slab with nothing showing is a D however fast it was abandoned. Without this,
        // bagging immediately scores the whole speed weight for having done nothing.
        let score = exposure <= 0
            ? 0
            : exposure * tuning.gradeExposureWeight
                + intact * tuning.gradeIntactWeight
                + speed * tuning.gradeSpeedWeight

        let letter: Letter
        switch score {
        case tuning.gradeThresholdS...: letter = .s
        case tuning.gradeThresholdA...: letter = .a
        case tuning.gradeThresholdB...: letter = .b
        case tuning.gradeThresholdC...: letter = .c
        default: letter = .d
        }
        return SlabGrade(
            score: score,
            letter: letter,
            bonusMultiplier: 1 + bonusRate(letter, tuning: tuning)
        )
    }

    public static func bonusRate(_ letter: Letter, tuning: SimTuning = .standard) -> Float {
        switch letter {
        case .s: return tuning.gradeBonusS
        case .a: return tuning.gradeBonusA
        case .b: return tuning.gradeBonusB
        case .c, .d: return 0
        }
    }

    /// Wheeler's opinion, printed under the letter.
    public var blurb: String {
        switch letter {
        case .s: return "A museum would take that."
        case .a: return "Good clean work."
        case .b: return "It will sell."
        case .c: return "Rough. But it is bone."
        case .d: return "He has seen better in a gift shop."
        }
    }
}
