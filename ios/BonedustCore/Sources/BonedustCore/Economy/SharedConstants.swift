/// The payload of `shared/constants.json`, which the Rails service loads so that
/// its plausibility check uses the same numbers as the client (§6).
///
/// Swift is the single source of truth and this file is generated, never
/// hand-edited: `bonedust-tool dump-constants`. `SharedConstantsTests` fails if the
/// checked-in file has drifted, which is what stops a tuning change from silently
/// making the server reject honest payments.
public struct SharedConstants: Sendable, Codable, Equatable {
    public var schema: Int
    public var tuning: SimTuning
    /// Only what the server needs: id, base value and shape, to re-derive the bone,
    /// rock and gem counts from a seed.
    public var fossils: [Fossil]
    public var sites: [Site]
    public var tools: [Tool]
    public var charms: [Charm]
    /// Needed because a completed skeleton set raises the payout ceiling, so the server
    /// has to know the perks exist even though it never tracks who has earned them.
    public var sets: [SkeletonSet]
    /// The server's ceiling needs the best price any buyer pays.
    public var buyers: [Buyer]
    public var installments: [Int]
    public var installmentGrowth: Float
    /// How many charms and tools a belt holds.
    ///
    /// Exported rather than redeclared because the ceiling multiplies by them: a charm
    /// paying per charm carried is bounded by a full belt, so the server needs the same
    /// number the client does. Ruby had `CHARM_SLOTS = 4` written out by hand beside
    /// Swift's `RunState.charmSlots = 4`, which is a trap of exactly the kind this file
    /// exists to prevent — widening the belt in Swift alone would have made an honest
    /// five-charm run read as forgery, with the ledger rejecting the payment and no
    /// error pointing at the cause.
    public var charmSlots: Int
    public var toolSlots: Int

    public init(tuning: SimTuning, catalog: ContentCatalog) {
        self.schema = 1
        self.tuning = tuning
        self.fossils = catalog.fossils
        self.sites = catalog.sites
        self.tools = catalog.tools
        self.charms = catalog.charms
        self.sets = catalog.sets
        self.buyers = catalog.buyers
        self.installments = Installments.table
        self.installmentGrowth = Installments.growth
        self.charmSlots = RunState.charmSlots
        self.toolSlots = RunState.toolSlots
    }
}
