import Foundation

/// What one finished slab contributed to the run. Also the payload the crew ledger
/// payment is built from (§6), which is why it carries duration and metrics rather
/// than just a number.
public struct SlabRecord: Sendable, Codable, Equatable {
    public var day: Int
    public var seed: UInt64
    public var siteID: String
    public var fossilID: String
    public var payout: PayoutBreakdown
    public var durationMillis: Int
    /// False when the daylight ran out instead.
    public var bagged: Bool
    public var wholeGems: Int
    public var daylightLeft: Float
    /// Issued by the server, when the slab was started online. Nil for an offline
    /// slab, which the ledger credits at 50% (see docs/CREW_LEDGER.md).
    public var serverSlabID: String?

    public init(
        day: Int, seed: UInt64, siteID: String, fossilID: String,
        payout: PayoutBreakdown, durationMillis: Int, bagged: Bool,
        wholeGems: Int, daylightLeft: Float, serverSlabID: String? = nil
    ) {
        self.day = day
        self.seed = seed
        self.siteID = siteID
        self.fossilID = fossilID
        self.payout = payout
        self.durationMillis = durationMillis
        self.bagged = bagged
        self.wholeGems = wholeGems
        self.daylightLeft = daylightLeft
        self.serverSlabID = serverSlabID
    }
}

public enum RunPhase: Sendable, Codable, Equatable {
    /// A slab is in progress, or about to be.
    case digging(day: Int)
    /// The slab is done and the results card is up.
    case results(day: Int)
    /// Day five paid the installment.
    case succeeded(reputationEarned: Int, leftover: Int)
    /// Day five did not.
    case failed(shortfall: Int)

    public var day: Int? {
        switch self {
        case .digging(let day), .results(let day): return day
        case .succeeded, .failed: return nil
        }
    }

    public var isOver: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .digging, .results: return false
        }
    }
}

/// One run: five days, five slabs, one installment due at the end of it.
///
/// A pure value type with the whole state machine on it, so the five-day arc can be
/// unit-tested and run ten thousand times in the economy simulation without a view,
/// a database or a clock anywhere near it.
public struct RunState: Sendable, Codable, Equatable {

    public static let currentSchema = 1

    public var schema: Int
    /// Slab seeds derive from this, so a whole run is reproducible from one number.
    public var seed: UInt64
    public var siteID: String
    /// 1-based. Drives the installment.
    public var tier: Int
    public var installment: Int
    public var totalDays: Int
    public var cash: Int
    public var slabs: [SlabRecord]
    public var phase: RunPhase
    /// Tool ids the player owns. Three slots (§4).
    public var toolIDs: [String]
    /// Charm ids the player owns. Four slots (§4).
    public var charmIDs: [String]
    public var startedAt: Date

    public static let toolSlots = 3
    public static let charmSlots = 4

    public init(
        seed: UInt64,
        siteID: String,
        tier: Int = 1,
        totalDays: Int = 5,
        toolIDs: [String] = [BrushTool.brush.id],
        charmIDs: [String] = [],
        startedAt: Date = Date()
    ) {
        self.schema = RunState.currentSchema
        self.seed = seed
        self.siteID = siteID
        self.tier = max(1, tier)
        self.installment = Installments.amount(tier: max(1, tier))
        self.totalDays = max(1, totalDays)
        self.cash = 0
        self.slabs = []
        self.phase = .digging(day: 1)
        self.toolIDs = toolIDs
        self.charmIDs = charmIDs
        self.startedAt = startedAt
    }

    // MARK: Derived

    public var currentDay: Int { phase.day ?? totalDays }

    public var isOver: Bool { phase.isOver }

    /// How far short of the installment the run currently is. Zero once covered.
    public var shortfall: Int { max(0, installment - cash) }

    public var isInstallmentCovered: Bool { cash >= installment }

    public var totalEarned: Int { slabs.reduce(0) { $0 + $1.payout.total } }

    /// What this run has contributed to the crew debt. Every dollar earned counts,
    /// including the dollars that then went to the Collector.
    public var crewContribution: Int { totalEarned }

    /// The seed for a given day's slab.
    ///
    /// Derived rather than drawn one at a time so that a run is fully determined by
    /// its own seed: restoring a save, replaying a run in the economy simulation, and
    /// the server re-deriving a slab all land on the same number without having to
    /// persist a list.
    public func slabSeed(forDay day: Int) -> UInt64 {
        var rng = SplitMix64(seed: seed ^ (UInt64(max(1, day)) &* 0x9E37_79B9_7F4A_7C15))
        return rng.next()
    }

    public func record(forDay day: Int) -> SlabRecord? {
        slabs.first { $0.day == day }
    }

    // MARK: Transitions

    /// Banks a finished slab and shows its results.
    public mutating func completeSlab(_ record: SlabRecord) {
        guard case .digging(let day) = phase, day == record.day else { return }
        slabs.append(record)
        cash += record.payout.total
        phase = .results(day: day)
    }

    /// Leaves the results card: on to the next day, or settle up.
    public mutating func advance() {
        guard case .results(let day) = phase else { return }
        if day < totalDays {
            phase = .digging(day: day + 1)
        } else {
            settle()
        }
    }

    /// Day five is done. Either the Collector is paid or he is not.
    ///
    /// On success the installment is deducted and *all* leftover cash converts to
    /// Reputation at 10:1 (§4) — nothing carries into the next run. That is what makes
    /// a shop purchase on day four a real gamble instead of a deferred saving.
    private mutating func settle() {
        if cash >= installment {
            let leftover = cash - installment
            cash = 0
            phase = .succeeded(
                reputationEarned: Installments.reputation(fromLeftoverCash: leftover),
                leftover: leftover
            )
        } else {
            phase = .failed(shortfall: installment - cash)
        }
    }

    /// Ends the run early, as a failure. For "abandon run" in settings.
    public mutating func abandon() {
        guard !isOver else { return }
        phase = .failed(shortfall: shortfall)
    }
}

/// Progress that outlives a run. M4 grows this into the Collection and unlocks; for
/// now it carries the installment tier forward, which is the whole difficulty ramp.
public struct MetaProgress: Sendable, Codable, Equatable {

    public static let currentSchema = 1

    public var schema: Int
    public var reputation: Int
    /// Tier the next run starts at.
    public var nextTier: Int
    public var runsCompleted: Int
    public var runsFailed: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var bestSlabPayout: Int
    /// Lifetime dollars contributed to the crew debt.
    public var lifetimeContribution: Int

    public init() {
        self.schema = MetaProgress.currentSchema
        self.reputation = 0
        self.nextTier = 1
        self.runsCompleted = 0
        self.runsFailed = 0
        self.currentStreak = 0
        self.longestStreak = 0
        self.bestSlabPayout = 0
        self.lifetimeContribution = 0
    }

    /// Folds a finished run in.
    ///
    /// Failure resets the tier to 1 — the Collector took the tools, so the next run
    /// starts from the bottom — but keeps Reputation, because meta progression that
    /// can be destroyed by one bad run makes the game hostile rather than tense.
    public mutating func absorb(_ run: RunState) {
        lifetimeContribution += run.crewContribution
        bestSlabPayout = max(bestSlabPayout, run.slabs.map(\.payout.total).max() ?? 0)

        switch run.phase {
        case .succeeded(let reputationEarned, _):
            reputation += reputationEarned
            runsCompleted += 1
            currentStreak += 1
            longestStreak = max(longestStreak, currentStreak)
            nextTier = run.tier + 1
        case .failed:
            runsFailed += 1
            currentStreak = 0
            nextTier = 1
        case .digging, .results:
            break
        }
    }

    public var nextInstallment: Int { Installments.amount(tier: nextTier) }
}
