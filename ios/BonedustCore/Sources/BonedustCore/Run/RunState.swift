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
    public var cash: Int
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
    public mutating func completeSlab(_ record: SlabRecord) {
        guard case .digging(let day) = phase, day == record.day else { return }
        slabs.append(record)
        cash += record.payout.total
        phase = .results(day: day)
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
        return tool.resaleValue
    }

    @discardableResult
    public mutating func sellCharm(_ id: String, catalog: ContentCatalog = .shared) -> Int {
        guard let charm = catalog.charm(id), charmIDs.contains(id) else { return 0 }
        charmIDs.removeAll { $0 == id }
        cash += charm.resaleValue
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
    /// Lifetime dollars contributed to the crew debt.
    public var lifetimeContribution: Int
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
        self.collection = Collection()
        self.completedSetIDs = []
        self.reportedAchievementIDs = []
        self.highestTierCleared = 0
        self.hasFlawlessSlab = false
        self.brushTrailID = nil
        self.claimedPersonalMilestoneIDs = []
        self.outfit = nil
        self.carriedToolIDs = [BrushTool.brush.id]
        self.carriedCharmIDs = []
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
            carriedToolIDs = run.toolIDs
            carriedCharmIDs = run.charmIDs
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
