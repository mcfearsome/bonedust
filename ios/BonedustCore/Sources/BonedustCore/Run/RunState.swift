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
    /// Whether the specimen was identified before the slab ended.
    ///
    /// Stored rather than re-derived from exposure, because the threshold moves with the
    /// loadout — "Collector's eye" identifies at a tenth. You cannot catalogue a fossil
    /// the game never named for you.
    public var identified: Bool
    /// Issued by the server, when the slab was started online. Nil for an offline
    /// slab, which the ledger credits at 50% (see docs/CREW_LEDGER.md).
    public var serverSlabID: String?
    /// Who bought it, when a sale happened. Optional on the wire for older saves.
    public var buyerID: String?

    public init(
        day: Int, seed: UInt64, siteID: String, fossilID: String,
        payout: PayoutBreakdown, durationMillis: Int, bagged: Bool,
        wholeGems: Int, daylightLeft: Float, identified: Bool = false,
        serverSlabID: String? = nil
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
        self.identified = identified
        self.serverSlabID = serverSlabID
    }
}

public enum RunPhase: Sendable, Codable, Equatable {
    /// A slab is in progress, or about to be.
    case digging(day: Int)
    /// The slab is done and the results card is up.
    case results(day: Int)
    /// Between slabs, in the supply tent. Carries the day just finished.
    case supplyTent(day: Int)
    /// Day five paid the installment.
    case succeeded(reputationEarned: Int, leftover: Int)
    /// Day five did not.
    case failed(shortfall: Int)

    public var day: Int? {
        switch self {
        case .digging(let day), .results(let day), .supplyTent(let day): return day
        case .succeeded, .failed: return nil
        }
    }

    public var isOver: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .digging, .results, .supplyTent: return false
        }
    }
}

/// An outfit: a handful of diggers who pool what they pay.
///
/// "Crew" already means every player alive against one debt, so the smaller group needed
/// its own word. An outfit is what a survey party was called, and it leaves "crew"
/// unambiguous everywhere it already appears.
public struct OutfitMembership: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var paidTotal: Int
    public var memberCount: Int
    /// Reward identifiers for every outfit rung reached, as the server reported them.
    public var reachedUnlocks: [String]
    /// Shown so a member can bring someone in. Nil once they have left.
    public var joinCode: String?

    public init(
        id: String, name: String, paidTotal: Int = 0, memberCount: Int = 1,
        reachedUnlocks: [String] = [], joinCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.paidTotal = paidTotal
        self.memberCount = memberCount
        self.reachedUnlocks = reachedUnlocks
        self.joinCode = joinCode
    }
}

/// A slab the server issued, remembered so its payment can be matched to it.
public struct IssuedSlabRef: Sendable, Codable, Equatable {
    public var slabID: String
    public var seed: UInt64

    public init(slabID: String, seed: UInt64) {
        self.slabID = slabID
        self.seed = seed
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
    /// Days this run has earned by digging an S-grade slab.
    ///
    /// Optional on the wire so a save written before days could be earned still decodes;
    /// `RunStore` discards anything the decoder throws on.
    private var earnedDaysRaw: Int?
    public var earnedDays: Int {
        get { earnedDaysRaw ?? 0 }
        set { earnedDaysRaw = newValue }
    }
    public var cash: Int
    /// What tools, charms and restocks have cost this run, net of anything sold back.
    ///
    /// Stored rather than derived, because `cash` nets purchases against earnings and then
    /// the installment is taken out of it at settle, so by the time anyone asks there is no
    /// way to separate "spent on a pick" from "handed to the Collector".
    ///
    /// Optional on the wire so a save written before this existed still decodes.
    /// `RunStore.loadMeta` discards anything `JSONDecoder` throws on, which makes a new
    /// non-optional field indistinguishable from a corrupt save -- it would silently wipe a
    /// run in progress. Same reason `currentSchema` does not move: the store compares it for
    /// equality and throws the save away on a mismatch, so a bump is a wipe unless a
    /// migration is written first.
    private var spentOnKitRaw: Int?
    public var spentOnKit: Int {
        get { spentOnKitRaw ?? 0 }
        set { spentOnKitRaw = newValue }
    }
    /// Kit bought that no slab payment has covered yet.
    ///
    /// Payments go to the server one slab at a time, the moment a slab is bagged, so that a
    /// run abandoned on day three still credits the two days that were dug. The supply tent
    /// opens *after* that, which means a week's spending cannot be netted off the payment it
    /// belongs to -- it has to be carried and taken out of the next one.
    private var unsettledKitRaw: Int?
    public var unsettledKit: Int {
        get { unsettledKitRaw ?? 0 }
        set { unsettledKitRaw = max(0, newValue) }
    }
    /// What this run has actually sent to the crew debt, summed as it went.
    ///
    /// Recorded rather than derived because carried kit can be left stranded: buy a pick on
    /// day four costing more than day five earns, and there is no later payment to take the
    /// remainder out of. `totalEarned - spentOnKit` would then disagree with the sum of what
    /// was really paid, and the number on the results screen has to be the true one.
    /// Attention, carried across weeks. See `Buyer`.
    private var heatRaw: Int?
    public var heat: Int {
        get { heatRaw ?? 0 }
        set { heatRaw = max(0, newValue) }
    }
    /// Specimens taken before you were paid, this run.
    private var seizedRaw: Int?
    public var seized: Int {
        get { seizedRaw ?? 0 }
        set { seizedRaw = newValue }
    }

    private var paidToCrewRaw: Int?
    public var paidToCrew: Int {
        get { paidToCrewRaw ?? 0 }
        set { paidToCrewRaw = newValue }
    }
    public var slabs: [SlabRecord]
    public var phase: RunPhase
    /// Tool ids the player owns. Three slots (§4).
    public var toolIDs: [String]
    /// Charm ids the player owns. Four slots (§4).
    public var charmIDs: [String]
    /// What the tent is offering on this visit. Part of the save so a relaunch cannot
    /// be used as a free reroll.
    /// Server-issued slabs by day. Empty for a run dug entirely offline.
    public var issuedSlabs: [Int: IssuedSlabRef]
    public var shop: ShopStock
    public var startedAt: Date

    public static let toolSlots = 3
    public static let charmSlots = 4

    public init(
        seed: UInt64,
        siteID: String,
        tier: Int = 1,
        /// Defaults to the tier's own length. Passing it explicitly is for tests.
        totalDays: Int? = nil,
        toolIDs: [String] = [BrushTool.brush.id],
        charmIDs: [String] = [],
        startedAt: Date = Date()
    ) {
        self.schema = RunState.currentSchema
        self.seed = seed
        self.siteID = siteID
        self.tier = max(1, tier)
        self.installment = Installments.amount(tier: max(1, tier))
        self.totalDays = max(1, totalDays ?? RunLength.days(tier: max(1, tier)))
        self.cash = 0
        self.earnedDaysRaw = 0
        self.spentOnKitRaw = 0
        self.unsettledKitRaw = 0
        self.paidToCrewRaw = 0
        self.heatRaw = 0
        self.seizedRaw = 0
        self.slabs = []
        self.phase = .digging(day: 1)
        self.toolIDs = toolIDs
        self.charmIDs = charmIDs
        self.issuedSlabs = [:]
        self.shop = ShopStock()
        self.startedAt = startedAt
    }

    // MARK: Derived

    public var currentDay: Int { phase.day ?? totalDays }

    public var isOver: Bool { phase.isOver }

    /// How far short of the installment the run currently is. Zero once covered.
    public var shortfall: Int { max(0, installment - cash) }

    public var isInstallmentCovered: Bool { cash >= installment }

    public var totalEarned: Int { slabs.reduce(0) { $0 + $1.payout.total } }

    /// What this run has contributed to the crew debt: what came out of the ground, less
    /// what went back over the counter at the supply tent.
    ///
    /// Kit spending used to count. Every dollar earned paid the debt even if it immediately
    /// bought a pick, which made "total earned" and "total paid to the debt" the same number
    /// by construction and left the player no way to see what their tools had cost them.
    ///
    /// Buying a tool is now a real decision against the debt rather than a free one, and the
    /// run's *difficulty* is untouched: whether a week is survived is `cash >= installment`,
    /// which this is not part of. It only changes how fast the debt comes down.
    ///
    /// Floored at zero. Selling back more than a run earned is possible with kit carried in
    /// from a previous week, and a run that hands money *back* to the crew debt is not a
    /// thing the ledger can represent.
    public var crewContribution: Int { paidToCrew }

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

    /// The seed a day's slab is actually dug from.
    ///
    /// The server's one when there is one, because that is what makes the payment
    /// checkable (§6); otherwise the locally derived one, and the payment is credited at a
    /// fraction. The dig itself cannot tell the difference.
    public func effectiveSeed(forDay day: Int) -> UInt64 {
        issuedSlabs[day]?.seed ?? slabSeed(forDay: day)
    }

    public func serverSlabID(forDay day: Int) -> String? {
        issuedSlabs[day]?.slabID
    }

    public mutating func noteIssued(_ reference: IssuedSlabRef, forDay day: Int) {
        issuedSlabs[day] = reference
    }

    public func record(forDay day: Int) -> SlabRecord? {
        slabs.first { $0.day == day }
    }

    // MARK: Transitions

    /// Banks a finished slab and shows its results.
    ///
    /// Returns what the crew debt should be paid for it: the slab's payout less any kit
    /// still owed from earlier in the week. The caller sends that, not `payout.total`, or
    /// the server's debt and the player's own total disagree about the same dollars.
    /// Set by `completeSlab` when the slab just bagged bought another day, so the results
    /// card can say so. Cleared on the next slab.
    public private(set) var lastSlabEarnedADay = false
    /// Set when the last sale was taken, so the results card can say *that*.
    public private(set) var lastSaleWasSeized = false

    /// What a sale to this buyer would do, with nothing committed.
    ///
    /// The results screen shows all of it before the player picks, because a seizure they
    /// could not see coming is a tax rather than a decision.
    public func quote(
        _ record: SlabRecord, buyer: Buyer, tuning: SimTuning = .standard
    ) -> (price: Int, heat: Int, risk: Float) {
        (
            Sale.price(of: record.payout.total, from: buyer),
            Sale.heatAdded(value: record.payout.total, buyer: buyer, tuning: tuning),
            Sale.seizureChance(
                heat: heat, value: record.payout.total, buyer: buyer, tuning: tuning
            )
        )
    }

    /// Banks a finished slab, sold to `buyer`.
    ///
    /// Returns what the crew debt should be paid for it, which is zero if the specimen was
    /// taken or if it went to someone who does not report sales.
    @discardableResult
    public mutating func completeSlab(
        _ record: SlabRecord, buyer: Buyer? = nil, tuning: SimTuning = .standard
    ) -> Int {
        guard case .digging(let day) = phase, day == record.day else { return 0 }
        var record = record
        lastSaleWasSeized = false

        if let buyer {
            // Rolled from the run's own seed and the day, so the outcome is fixed for this
            // slab. Re-rolling it by force-quitting fails exactly as it does for a crack.
            var rng = SplitMix64(
                seed: seed ^ (UInt64(day) &* 0x9E37_79B9_7F4A_7C15) ^ 0x5EED_5A1E
            )
            if Sale.isSeized(
                heat: heat, value: record.payout.total, buyer: buyer,
                rng: &rng, tuning: tuning
            ) {
                lastSaleWasSeized = true
                seized += 1
                // Still catalogued: the Collection records what came out of the ground,
                // whether or not anybody got paid for it.
                slabs.append(record)
                heat += Sale.heatAdded(value: record.payout.total, buyer: buyer, tuning: tuning)
                phase = .results(day: day)
                return 0
            }
            record.payout.total = Sale.price(of: record.payout.total, from: buyer)
            record.buyerID = buyer.id
            heat += Sale.heatAdded(value: record.payout.total, buyer: buyer, tuning: tuning)
        }
        slabs.append(record)

        // A museum-quality specimen buys another day's light. Checked before the phase
        // moves, so the day it adds is one the run can actually reach.
        lastSlabEarnedADay = false
        if RunLength.earnsADay(record.payout.grade),
           earnedDays < RunLength.maximumEarnedDays,
           totalDays < RunLength.maximumDays {
            earnedDays += 1
            totalDays += 1
            lastSlabEarnedADay = true
        }
        cash += record.payout.total
        let paysDebt = buyer?.paysDebt ?? true
        let payment = paysDebt ? max(0, record.payout.total - unsettledKit) : 0
        unsettledKit -= record.payout.total
        paidToCrew += payment
        phase = .results(day: day)
        return payment
    }

    /// Leaves the results card: into the tent, or settle up.
    ///
    /// There is no tent after day five. The installment falls due the moment the last
    /// slab is bagged, so letting the player shop first would just be a way to convert
    /// cash they owe into tools they are about to lose.
    public mutating func advance() {
        guard case .results(let day) = phase else { return }
        if day < totalDays {
            phase = .supplyTent(day: day)
        } else {
            settle()
        }
    }

    /// Leaves the tent for the next day's slab.
    public mutating func leaveShop() {
        guard case .supplyTent(let day) = phase else { return }
        shop = ShopStock()
        phase = .digging(day: day + 1)
    }

    // MARK: Shopping

    public enum PurchaseFailure: Error, Equatable {
        case notOffered
        case alreadyOwned
        case noSlot
        case tooExpensive(price: Int, cash: Int)
        case notShopping
    }

    public var hasToolSlot: Bool { toolIDs.count < RunState.toolSlots }
    public var hasCharmSlot: Bool { charmIDs.count < RunState.charmSlots }

    /// Rolls the tent's stock for this visit, if it has not been rolled yet.
    public mutating func openShop(reputation: Int, pools: Set<ItemPool> = [.shop],
                                  catalog: ContentCatalog = .shared) {
        guard case .supplyTent(let day) = phase, shop.isEmpty else { return }
        shop = Shop.stock(
            runSeed: seed, day: day, restocks: 0,
            ownedToolIDs: toolIDs, ownedCharmIDs: charmIDs,
            reputation: reputation, pools: pools, catalog: catalog
        )
    }

    public mutating func restock(reputation: Int, pools: Set<ItemPool> = [.shop],
                                 catalog: ContentCatalog = .shared) throws {
        guard case .supplyTent(let day) = phase else { throw PurchaseFailure.notShopping }
        guard cash >= Shop.restockPrice else {
            throw PurchaseFailure.tooExpensive(price: Shop.restockPrice, cash: cash)
        }
        cash -= Shop.restockPrice
        spentOnKit += Shop.restockPrice
        unsettledKit += Shop.restockPrice
        shop = Shop.stock(
            runSeed: seed, day: day, restocks: shop.restocks + 1,
            ownedToolIDs: toolIDs, ownedCharmIDs: charmIDs,
            reputation: reputation, pools: pools, catalog: catalog
        )
    }

    public mutating func buyTool(_ id: String, catalog: ContentCatalog = .shared) throws {
        guard case .supplyTent = phase else { throw PurchaseFailure.notShopping }
        guard shop.toolIDs.contains(id) else { throw PurchaseFailure.notOffered }
        guard !toolIDs.contains(id) else { throw PurchaseFailure.alreadyOwned }
        guard hasToolSlot else { throw PurchaseFailure.noSlot }
        guard let tool = catalog.tool(id) else { throw PurchaseFailure.notOffered }
        guard cash >= tool.price else {
            throw PurchaseFailure.tooExpensive(price: tool.price, cash: cash)
        }
        cash -= tool.price
        spentOnKit += tool.price
        unsettledKit += tool.price
        toolIDs.append(id)
        shop.toolIDs.removeAll { $0 == id }
    }

    public mutating func buyCharm(_ id: String, catalog: ContentCatalog = .shared) throws {
        guard case .supplyTent = phase else { throw PurchaseFailure.notShopping }
        guard shop.charmIDs.contains(id) else { throw PurchaseFailure.notOffered }
        guard !charmIDs.contains(id) else { throw PurchaseFailure.alreadyOwned }
        guard hasCharmSlot else { throw PurchaseFailure.noSlot }
        guard let charm = catalog.charm(id) else { throw PurchaseFailure.notOffered }
        guard cash >= charm.price else {
            throw PurchaseFailure.tooExpensive(price: charm.price, cash: cash)
        }
        cash -= charm.price
        spentOnKit += charm.price
        unsettledKit += charm.price
        charmIDs.append(id)
        shop.charmIDs.removeAll { $0 == id }
    }

    /// Selling returns half price (§4). The starting brush cannot be sold, because a
    /// run with no brush is a run you cannot play.
    @discardableResult
    public mutating func sellTool(_ id: String, catalog: ContentCatalog = .shared) -> Int {
        guard id != BrushTool.brush.id, let tool = catalog.tool(id),
              toolIDs.contains(id) else { return 0 }
        toolIDs.removeAll { $0 == id }
        cash += tool.resaleValue
        spentOnKit -= tool.resaleValue
        unsettledKit -= tool.resaleValue
        return tool.resaleValue
    }

    @discardableResult
    public mutating func sellCharm(_ id: String, catalog: ContentCatalog = .shared) -> Int {
        guard let charm = catalog.charm(id), charmIDs.contains(id) else { return 0 }
        charmIDs.removeAll { $0 == id }
        cash += charm.resaleValue
        spentOnKit -= charm.resaleValue
        unsettledKit -= charm.resaleValue
        return charm.resaleValue
    }

    /// The loadout, resolved from ids.
    public func loadout(catalog: ContentCatalog = .shared) -> Loadout {
        Loadout.resolve(toolIDs: toolIDs, charmIDs: charmIDs, catalog: catalog)
    }

    /// Everything the player's kit and the site contribute, for a given day.
    public func modifiers(
        forDay day: Int, extra: ModifierSet = ModifierSet(), catalog: ContentCatalog = .shared
    ) -> ModifierSet {
        let context = CharmContext(
            day: day,
            siteID: siteID,
            tier: tier,
            bankedGems: slabs.reduce(0) { $0 + $1.wholeGems }
        )
        var sets = [loadout(catalog: catalog).modifiers(context: context), extra]
        if let site = catalog.site(siteForSlab(onDay: day, catalog: catalog)) {
            sets.append(site.modifiers.modifierSet)
        }
        return ModifierSet.combining(sets)
    }

    /// Which site a given day's slab comes from, honouring a charm override.
    public func siteForSlab(onDay day: Int, catalog: ContentCatalog = .shared) -> String {
        guard let override = loadout(catalog: catalog).siteOverride(onDay: day),
              catalog.site(override) != nil
        else { return siteID }
        return override
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
                reputationEarned: Installments.reputation(
                    fromLeftoverCash: leftover, tier: tier
                ),
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
    /// Lifetime dollars contributed to the crew debt, after kit spending is taken out.
    public var lifetimeContribution: Int
    /// Lifetime dollars dug out of the ground, before the supply tent takes its cut.
    ///
    /// Backed by an optional so a save written before this existed still decodes, and
    /// falling back to `lifetimeContribution` is exact rather than a guess: until kit
    /// spending stopped counting, every dollar earned went to the debt, so for those saves
    /// the two numbers *were* the same.
    private var lifetimeEarnedRaw: Int?
    public var lifetimeEarned: Int {
        get { lifetimeEarnedRaw ?? lifetimeContribution }
        set { lifetimeEarnedRaw = newValue }
    }
    /// Lifetime dollars spent on tools and charms, net of resales.
    ///
    /// Zero for an older save, and unrecoverable: nothing recorded it at the time. The gap
    /// between earned and contributed is the honest number for those weeks.
    private var lifetimeSpentOnKitRaw: Int?
    public var lifetimeSpentOnKit: Int {
        get { lifetimeSpentOnKitRaw ?? 0 }
        set { lifetimeSpentOnKitRaw = newValue }
    }
    /// Every species catalogued (§5).
    public var collection: Collection
    /// Skeleton sets finished, so a perk and its Reputation bonus are awarded once.
    public var completedSetIDs: [String]
    /// Achievement ids already reported to Game Center.
    public var reportedAchievementIDs: [String]
    /// Highest installment tier ever cleared.
    public var highestTierCleared: Int
    /// Whether any slab has ever come out fully exposed and uncracked.
    public var hasFlawlessSlab: Bool
    /// Chosen cosmetic brush trail, unlocked by Reputation.
    public var brushTrailID: String?
    /// Personal contribution rungs already reported, so one is announced once.
    public var claimedPersonalMilestoneIDs: [String]
    /// The outfit this digger belongs to, as the server last described it. Cached so the
    /// outfit's perks survive going offline, exactly as the crew's do.
    public var outfit: OutfitMembership?
    /// The kit the next run starts with.
    ///
    /// §4 says the Collector takes your tools as interest *when you fail*, which means
    /// they survive when you do not. Without this the installment ramp is unwinnable by
    /// construction: every run would begin with the starting brush, so income could
    /// never grow while the amount owed did.
    /// Permanent upgrades bought with Reputation. See `Upgrade`.
    ///
    /// Optional on the wire so a save written before the camp existed still decodes.
    private var ownedUpgradeIDsRaw: [String]?
    public var ownedUpgradeIDs: [String] {
        get { ownedUpgradeIDsRaw ?? [] }
        set { ownedUpgradeIDsRaw = newValue }
    }

    public var carriedToolIDs: [String]
    public var carriedCharmIDs: [String]

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
        self.lifetimeEarnedRaw = 0
        self.lifetimeSpentOnKitRaw = 0
        self.collection = Collection()
        self.completedSetIDs = []
        self.reportedAchievementIDs = []
        self.highestTierCleared = 0
        self.hasFlawlessSlab = false
        self.brushTrailID = nil
        self.claimedPersonalMilestoneIDs = []
        self.outfit = nil
        self.ownedUpgradeIDsRaw = []
        self.carriedToolIDs = [BrushTool.brush.id]
        self.carriedCharmIDs = []
    }

    public enum UpgradeFailure: Error, Equatable {
        case unknown
        case alreadyOwned
        case tooExpensive(cost: Int, reputation: Int)
    }

    /// Buys a permanent upgrade with Reputation.
    ///
    /// Reputation is *spent*, not merely required. A threshold would mean every upgrade
    /// arrives at once the moment the number is high enough, which is a notification rather
    /// than a decision -- and the whole point of this track is to give the player something
    /// to choose between while the tent is selling run-scoped kit.
    public mutating func buy(
        upgrade id: String, catalog: ContentCatalog = .shared
    ) throws {
        guard let upgrade = catalog.upgrade(id) else { throw UpgradeFailure.unknown }
        guard !ownedUpgradeIDs.contains(id) else { throw UpgradeFailure.alreadyOwned }
        guard reputation >= upgrade.reputation else {
            throw UpgradeFailure.tooExpensive(
                cost: upgrade.reputation, reputation: reputation
            )
        }
        reputation -= upgrade.reputation
        ownedUpgradeIDs.append(id)
    }

    /// Everything owned, as one modifier set to fold into a run.
    public func upgradeModifiers(catalog: ContentCatalog = .shared) -> ModifierSet {
        Upgrade.combined(ownedUpgradeIDs, catalog: catalog)
    }

    /// Days every week gets from owned upgrades.
    public func upgradeExtraDays(catalog: ContentCatalog = .shared) -> Int {
        Upgrade.extraDays(ownedUpgradeIDs, catalog: catalog)
    }

    /// What a finished run added, for the end screen to show.
    public struct Rewards: Sendable, Equatable {
        public var reputationFromCash = 0
        public var reputationFromSets = 0
        /// Species catalogued for the first time.
        public var newSpecies: [String] = []
        /// Skeleton sets finished by this run.
        public var completedSets: [String] = []
        /// Achievements newly qualified for.
        public var newAchievements: [String] = []
        /// Personal contribution rungs passed by this run.
        public var personalMilestones: [ContributionMilestone] = []

        public init() {}

        public var totalReputation: Int { reputationFromCash + reputationFromSets }
        public var isEmpty: Bool {
            totalReputation == 0 && newSpecies.isEmpty && completedSets.isEmpty
                && newAchievements.isEmpty && personalMilestones.isEmpty
        }
    }

    /// Folds a finished run in.
    ///
    /// Failure resets the tier to 1 — the Collector took the tools, so the next run
    /// starts from the bottom — but keeps Reputation and the Collection, because meta
    /// progression that one bad run can destroy makes the game hostile rather than tense.
    @discardableResult
    public mutating func absorb(
        _ run: RunState, catalog: ContentCatalog = .shared
    ) -> Rewards {
        var rewards = Rewards()
        // Measured before and after, so a rung passed mid-run is caught exactly once even
        // if the app dies between the slab and the results screen.
        let contributionBefore = lifetimeContribution
        lifetimeContribution += run.crewContribution
        lifetimeEarned += run.totalEarned
        lifetimeSpentOnKit += run.spentOnKit
        let claimed = Set(claimedPersonalMilestoneIDs)
        rewards.personalMilestones = ContributionPerks.newlyReached(
            catalog.personalMilestones,
            previous: contributionBefore,
            current: lifetimeContribution
        ).filter { !claimed.contains($0.id) }
        claimedPersonalMilestoneIDs.append(contentsOf: rewards.personalMilestones.map(\.id))
        bestSlabPayout = max(bestSlabPayout, run.slabs.map(\.payout.total).max() ?? 0)

        // The Collection records what came out of the ground, whether or not the week
        // was paid for. A fossil you dug is a fossil you dug.
        let runIndex = runsCompleted + runsFailed
        for slab in run.slabs {
            if collection.record(slab, runIndex: runIndex) {
                rewards.newSpecies.append(slab.fossilID)
            }
            if slab.payout.intact >= 0.999, slab.payout.exposure >= 0.999 {
                hasFlawlessSlab = true
            }
        }

        // Completing a set pays once. Comparing against the stored list rather than
        // firing an event means a set finished while the app was being killed is still
        // credited the next time this runs.
        let known = Set(completedSetIDs)
        for set in collection.completedSets(catalog: catalog) where !known.contains(set.id) {
            completedSetIDs.append(set.id)
            reputation += set.reputationBonus
            rewards.reputationFromSets += set.reputationBonus
            rewards.completedSets.append(set.id)
        }

        switch run.phase {
        case .succeeded(let reputationEarned, _):
            reputation += reputationEarned
            rewards.reputationFromCash = reputationEarned
            runsCompleted += 1
            currentStreak += 1
            longestStreak = max(longestStreak, currentStreak)
            highestTierCleared = max(highestTierCleared, run.tier)
            nextTier = run.tier + 1
            // Kit does not carry. Reported from play as "once i made my purchases i never
            // really looked at the store again" -- a tool bought in week one was still
            // doing its job in week nine, so the tent had nothing left to offer and the
            // whole middle of the game had no decisions in it.
            //
            // It was added for a real reason: without it the installment ramp is
            // unwinnable, because income could never grow while the amount owed did. What
            // replaces it is Reputation, which buys permanent upgrades and is kept whether
            // a week is survived or not -- so progression lives somewhere a single bad run
            // cannot take it, and the tent stays a weekly decision.
            carriedToolIDs = [BrushTool.brush.id]
            carriedCharmIDs = []
        case .failed:
            runsFailed += 1
            currentStreak = 0
            nextTier = 1
            // "The Collector takes your tools as interest."
            carriedToolIDs = [BrushTool.brush.id]
            carriedCharmIDs = []
        case .digging, .results, .supplyTent:
            break
        }

        let qualified = Achievements.earned(by: self, catalog: catalog)
        let reported = Set(reportedAchievementIDs)
        rewards.newAchievements = qualified.subtracting(reported).sorted()
        reportedAchievementIDs = qualified.sorted()
        return rewards
    }

    /// Everything the player's own lifetime contribution has earned.
    public func personalUnlocks(catalog: ContentCatalog = .shared) -> [String] {
        catalog.personalMilestones
            .filter { $0.reached(by: lifetimeContribution) }
            .flatMap { $0.unlocks + $0.cosmetics }
    }

    /// Modifiers from personal rungs and from the outfit, composed the usual way.
    public func contributionPerks(catalog: ContentCatalog = .shared) -> ModifierSet {
        ModifierSet.combining([
            ContributionPerks.modifiers(for: personalUnlocks(catalog: catalog)),
            ContributionPerks.modifiers(for: outfit?.reachedUnlocks ?? []),
        ])
    }

    /// Item pools opened by contribution, personal or shared.
    public func contributionPools(catalog: ContentCatalog = .shared) -> Set<ItemPool> {
        ContributionPerks.pools(
            for: personalUnlocks(catalog: catalog) + (outfit?.reachedUnlocks ?? [])
        )
    }

    /// Permanent modifiers from completed skeleton sets, for a given site.
    public func setPerks(
        forSite siteID: String, catalog: ContentCatalog = .shared
    ) -> ModifierSet {
        ModifierSet.combining(
            completedSetIDs
                .compactMap { catalog.setsByID[$0]?.perk }
                .map { $0.modifiers(forSite: siteID) }
        )
    }

    /// Which item pools are open. The vault opens either by personal contribution or by
    /// an outfit reaching its own rung.
    public func unlockedPools(catalog: ContentCatalog = .shared) -> Set<ItemPool> {
        contributionPools(catalog: catalog)
    }

    public var nextInstallment: Int { Installments.amount(tier: nextTier) }
}
