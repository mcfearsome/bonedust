import Foundation

/// The most a slab could possibly pay, computed the way the server computes it.
///
/// This is deliberately separate from `Payout.maxPayout`, and it exists because of one
/// constraint: §6 requires Ruby to reach the *same integer* from the same seed, and Ruby
/// has no 32-bit float. Every arithmetic step here is in `Double`, which Ruby's `Float`
/// is, so the two agree exactly rather than approximately.
///
/// Three things it deliberately does not try to reproduce:
///
/// - **Bone, rock and gem cell counts.** They come out of the rasterizer, which runs on
///   `Float` and on platform `libm`; `sin` and `exp` can differ in the last bit between
///   the client's macOS and the server's Linux, which would flip a cell on a boundary and
///   fail an exact test for no benefit. The ceiling does not need them.
/// - **The actual gem count**, which depends on finding clear 2x2 space in the generated
///   grid. It assumes the maximum, which keeps this an upper bound.
/// - **The actual nodule count**, for the same reason.
///
/// A ceiling that is too generous rejects no honest player and still makes inventing
/// money impossible, which is the whole job. A ceiling that is too tight accuses real
/// players of cheating, which is unforgivable.
public enum ServerCeiling {

    /// What the server needs to know about a slab, derived from its seed alone.
    public struct SlabDerivation: Sendable, Equatable, Codable {
        public var seed: UInt64
        public var siteID: String
        public var fossilID: String
        public var instances: Int
        /// The ceiling with no charms claimed.
        public var baseCeiling: Int

        public init(
            seed: UInt64, siteID: String, fossilID: String,
            instances: Int, baseCeiling: Int
        ) {
            self.seed = seed
            self.siteID = siteID
            self.fossilID = fossilID
            self.instances = instances
            self.baseCeiling = baseCeiling
        }
    }

    /// Replays only the first two PRNG draws of generation: the fossil and how many of
    /// it there are. Both are integer operations, so they port exactly.
    ///
    /// This mirrors `SlabGenerator.generate` and will silently disagree with it if the
    /// draw order there changes, which is what `ServerCeilingTests` is for.
    public static func derive(
        seed: UInt64,
        site: Site,
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) -> SlabDerivation {
        var rng = SplitMix64(seed: seed)

        // Draw 1: the fossil, from the site's weight table in sorted-id order.
        let table = site.weightedTable
        var fossilID = table.last?.fossilID ?? ""
        if !table.isEmpty {
            let total = table.reduce(0) { $0 + $1.weight }
            var roll = rng.nextInt(below: total)
            for entry in table {
                roll -= entry.weight
                if roll < 0 {
                    fossilID = entry.fossilID
                    break
                }
            }
        }
        let fossil = catalog.fossil(fossilID) ?? catalog.fossils[0]

        // Draw 2: how many copies.
        let instances = rng.nextInt(
            fossil.instancesMin,
            through: max(fossil.instancesMin, fossil.instancesMax + site.modifiers.extraInstances)
        )

        return SlabDerivation(
            seed: seed,
            siteID: site.id,
            fossilID: fossil.id,
            instances: instances,
            baseCeiling: ceiling(
                fossil: fossil, instances: instances, site: site,
                claimedCharms: [], catalog: catalog, tuning: tuning
            )
        )
    }

    /// The ceiling for a derived slab, given the charms the client claims to hold.
    ///
    /// Claimed charms are taken at face value and capped at the number of charm slots.
    /// A client could claim charms it does not own, which raises its own ceiling — but it
    /// cannot invent money, and verifying ownership would mean the server tracking every
    /// run. §6 asks for proportionate, not paranoid.
    public static func ceiling(
        fossil: Fossil,
        instances: Int,
        site: Site,
        claimedCharms: [String],
        catalog: ContentCatalog = .shared,
        tuning: SimTuning = .standard
    ) -> Int {
        let charms = claimedCharms
            .prefix(RunState.charmSlots)
            .compactMap { catalog.charm($0) }

        // Every value is widened to Double *before* any arithmetic, and nothing here
        // goes through ModifierSet.combining.
        //
        // That is not fussiness. ModifierSet stores Float, so folding four multipliers
        // together in Float and widening the result afterwards lands on a different
        // number than doing the same arithmetic in Double — and a product that straddles
        // a rounding boundary then differs by a dollar between client and server.
        // Widening a *stored* Float is exact; widening the *result* of Float arithmetic
        // is not. Ruby narrows each constant to 32 bits as it loads, so its doubles start
        // identical to these and stay identical through the same operations.
        var payoutMultiplier = 1.0
        var gemMultiplier = 1.0
        var rushMultiplier = 1.0
        var rockNodulePayout = 0
        var flatBonus = 0

        func fold(_ set: ModifierSet) {
            payoutMultiplier *= Double(set.payoutMultiplier)
            gemMultiplier *= Double(set.gemMultiplier)
            rushMultiplier *= Double(set.rushMultiplier)
            rockNodulePayout += set.rockNodulePayout
            flatBonus += set.flatBonus
        }

        fold(site.modifiers.modifierSet)
        for charm in charms {
            fold(charm.modifiers)
            // Scaling resolved here rather than via Charm.resolve, which computes in
            // Float. Taken at its most generous: full charm slots, the last day, every
            // gem banked.
            switch charm.scaling {
            case .payoutPerCharm(let step):
                payoutMultiplier *= 1 + Double(step) * Double(RunState.charmSlots)
            case .payoutPerTool(let step):
                payoutMultiplier *= 1 + Double(step) * Double(RunState.toolSlots)
            case .payoutPerBankedGem(let step):
                payoutMultiplier *= 1 + Double(step) * Double(tuning.gemsMax * 5)
            case .safeSpeedPerDay, .none:
                break
            }
        }
        // Assume every skeleton set the game has is complete.
        for set in catalog.sets {
            fold(set.perk.modifiers(forSite: site.id))
        }

        let fossilPay = Double(fossil.baseValue * max(1, instances))
        let gems = Double(tuning.gemsMax * tuning.gemValue) * gemMultiplier
        // The rush bonus is assumed to have landed.
        // The best possible grade is assumed, as everything else here is. A slab cleared,
        // unbroken and bagged early earns gradeBonusS on top of fossil and gem money, so a
        // ceiling that ignored it would reject the exact slab a player is proudest of --
        // and would do it the moment the dig went perfectly, which is the worst possible
        // time to accuse somebody of cheating.
        //
        // 0.25 is exactly representable in binary, so Float -> Double here and Ruby's own
        // 0.25 are the same number. A rate that is not exact would have to go through the
        // same f32 narrowing the other constants do.
        let multiplier = payoutMultiplier * rushMultiplier * (1 + Double(tuning.gradeBonusS))
        let scaled = ((fossilPay + gems) * multiplier).rounded()

        let nodules = tuning.rockNodulesMax + site.modifiers.extraRockNodules
        let flat = Double(nodules * rockNodulePayout + flatBonus)
        return max(0, Int(scaled + flat))
    }

    /// How much slack the server allows above the ceiling before rejecting.
    ///
    /// One percent plus a dollar. The client computes its payout in `Float` and the server
    /// in `Double`, and a product of four multipliers can land either side of a rounding
    /// boundary. A dollar of slack costs nothing; wrongly rejecting a legitimate payment
    /// tells a paying customer they are a cheat.
    public static func allows(amount: Int, ceiling: Int) -> Bool {
        amount <= Int((Double(ceiling) * 1.01).rounded()) + 1
    }
}
