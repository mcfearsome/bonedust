import Foundation

/// Who you sell a specimen to, and what it costs you to sell it to them.
///
/// The premise already had this in it: a *disgraced* paleontologist, in debt to a *private
/// collector*. Wheeler was never a museum. Making the sale a choice gives the week a second
/// decision that is not a brush stroke, and every option is compromised — which is the only
/// thing that makes a choice between three numbers a puzzle rather than a menu.
///
/// The three pressures do not reduce to one another:
///
/// - **Money** pays the installment, which is the only thing keeping you digging.
/// - **Heat** is attention. It accumulates across weeks and gets specimens seized, so the
///   dealer who pays best is also the one who eventually costs you a Tyrannosaurus.
/// - **Reputation** is your name back on a label, which is what "disgraced" means and the
///   only thing here that is not money. The museum pays worst and is the only one selling
///   it.
public struct Buyer: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var blurb: String
    /// Multiplies what the specimen is worth.
    public var priceMultiplier: Float
    /// Heat added per sale, before the specimen's own notoriety.
    public var heat: Int
    /// Reputation earned. Only the legitimate buyer offers any.
    public var reputation: Int
    /// Whether the money reaches the crew debt (§6). The fence's does not.
    public var paysDebt: Bool

    public init(
        id: String, name: String, blurb: String = "",
        priceMultiplier: Float, heat: Int, reputation: Int = 0, paysDebt: Bool = true
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.priceMultiplier = priceMultiplier
        self.heat = heat
        self.reputation = reputation
        self.paysDebt = paysDebt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, blurb, priceMultiplier, heat, reputation, paysDebt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        priceMultiplier = try c.decode(Float.self, forKey: .priceMultiplier)
        heat = try c.decode(Int.self, forKey: .heat)
        reputation = try c.decodeIfPresent(Int.self, forKey: .reputation) ?? 0
        paysDebt = try c.decodeIfPresent(Bool.self, forKey: .paysDebt) ?? true
    }
}

/// What a sale actually does.
///
/// Every number here is derived before the player commits, and the results screen shows all
/// of them. A seizure that could not be seen coming is a tax rather than a decision — the
/// puzzle is reading the risk, so the risk has to be legible.
public enum Sale: Sendable {

    /// What a specimen fetches from this buyer.
    public static func price(of value: Int, from buyer: Buyer) -> Int {
        max(0, Int((Float(value) * buyer.priceMultiplier).rounded()))
    }

    /// How conspicuous a specimen is on its own, 0 to 1.
    ///
    /// A crinoid is one of thousands and nobody asks. A Tyrannosaurus is on a list before it
    /// leaves the county. So the 120-species roster now matters a second way: what a fossil
    /// is worth and how hard it is to move quietly are the same number.
    public static func notoriety(of value: Int, tuning: SimTuning = .standard) -> Float {
        guard tuning.notorietyFullValue > tuning.notorietyFloorValue else { return 0 }
        let span = Float(tuning.notorietyFullValue - tuning.notorietyFloorValue)
        let over = Float(value - tuning.notorietyFloorValue)
        return min(max(over / span, 0), 1)
    }

    /// Heat a sale adds: the buyer's own, scaled by how conspicuous the specimen is.
    public static func heatAdded(
        value: Int, buyer: Buyer, tuning: SimTuning = .standard
    ) -> Int {
        guard buyer.heat > 0 else { return buyer.heat }
        let scale = 1 + notoriety(of: value, tuning: tuning) * tuning.notorietyHeatScale
        return max(1, Int((Float(buyer.heat) * scale).rounded()))
    }

    /// The chance a sale ends with the specimen taken, 0 to 1.
    ///
    /// Zero below a threshold, so early weeks are never a coin flip, and zero for a buyer
    /// who draws no heat at all — Wheeler is always safe, which is exactly why he can pay
    /// the least and still be worth choosing.
    public static func seizureChance(
        heat: Int, value: Int, buyer: Buyer, tuning: SimTuning = .standard
    ) -> Float {
        guard buyer.heat > 0 else { return 0 }
        let over = Float(heat - tuning.heatSafeBelow)
        guard over > 0 else { return 0 }
        let span = Float(max(1, tuning.heatMaximum - tuning.heatSafeBelow))
        let pressure = min(over / span, 1)
        let exposure = 1 + notoriety(of: value, tuning: tuning)
        return min(pressure * tuning.seizureChanceAtMaxHeat * exposure, 0.95)
    }

    /// Whether a sale is seized.
    ///
    /// Drawn from the run's own PRNG, so the outcome is part of the save. Force-quitting to
    /// re-roll a seizure fails for the same reason it fails on a crack: the roll already
    /// happened to that seed.
    public static func isSeized(
        heat: Int, value: Int, buyer: Buyer,
        rng: inout SplitMix64, tuning: SimTuning = .standard
    ) -> Bool {
        let chance = seizureChance(heat: heat, value: value, buyer: buyer, tuning: tuning)
        guard chance > 0 else { return false }
        return rng.nextUnit() < chance
    }

    /// Heat shed between weeks. Attention fades if you stop giving it reasons.
    public static func cooled(_ heat: Int, tuning: SimTuning = .standard) -> Int {
        max(0, heat - tuning.heatCooledPerRun)
    }
}
