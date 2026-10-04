import XCTest
@testable import BonedustCore

/// Is there any reason to go slowly?
///
/// Reported from play: "the game now is basically expose the bone to speed run for gems,
/// time is of no concern, there is no tension". That is a statement about payoffs, so it is
/// answerable: play the same slabs carefully and carelessly and compare what they pay.
///
/// If rushing pays as well as care, the whole premise is gone -- §3 is "brushing faster
/// clears more rock but cracks exposed bone", and that is only a tension if the cracking
/// costs more than the speed gains.
final class TensionTests: XCTestCase {

    private struct Result {
        var payout = 0.0
        var gems = 0.0
        var fossil = 0.0
        var intact = 0.0
        var seconds = 0.0
    }

    private func play(_ policy: PlayerPolicy, site: String, seeds: Int = 24) -> Result {
        var out = Result()
        let catalog = ContentCatalog.shared
        guard let s = catalog.site(site) else { return out }
        for seed in 0..<seeds {
            let record = EconomySimulator.playSlab(
                seed: UInt64(seed) &* 2_654_435_761, day: 1, site: s,
                policy: policy, catalog: catalog
            )
            let n = Double(seeds)
            out.payout += Double(record.payout.total) / n
            out.gems += Double(record.payout.gems) / n
            out.fossil += Double(record.payout.fossil) / n
            out.intact += Double(record.payout.intact) / n
            out.seconds += Double(record.durationMillis) / 1000 / n
        }
        return out
    }

    func testRushingShouldPayLessThanCare() {
        print("")
        var results: [(String, Result)] = []
        for (name, policy) in [
            ("careful", PlayerPolicy.careful),
            ("average", PlayerPolicy.average),
            ("reckless", PlayerPolicy.reckless),
        ] {
            let r = play(policy, site: "charmouth")
            results.append((name, r))
            print(String(
                format: "  %-9@ $%-5.0f  fossil $%-5.0f  gems $%-4.0f (%2.0f%%)  intact %.3f  %4.1fs",
                name as NSString, r.payout, r.fossil, r.gems,
                r.payout > 0 ? r.gems / r.payout * 100 : 0, r.intact, r.seconds
            ))
        }

        let careful = results[0].1
        let reckless = results[2].1
        XCTAssertGreaterThan(
            careful.payout, reckless.payout,
            "rushing pays at least as well as care, so there is no tension in the one "
                + "decision the whole game is built on"
        )
    }

    /// What a *partial* dig pays, which is the case the sweep never sees.
    ///
    /// Its model reaches 0.96 exposure on every slab, so a flat gem payout is 8% of a slab
    /// to it and a third to a half to someone still learning. Reported from play as "gems
    /// are the only way to get enough money to actually make the payment, its impossible
    /// just on fossil values" — true, and invisible to every measurement taken until this
    /// one.
    func testAPartialDigIsStillPaidForTheFossil() {
        let tuning = SimTuning.standard
        let catalog = ContentCatalog.shared
        print("")
        for exposure in [Float(0.5), 0.6, 0.7, 0.8, 0.9] {
            var fossilTotal = 0.0
            var gemTotal = 0.0
            var n = 0.0
            for id in ["ammonite", "belemnite", "crinoid", "nautilus"] {
                guard let fossil = catalog.fossil(id) else { continue }
                // Two gems whole, which is the middle of the one-to-four range.
                let payout = Payout.evaluate(PayoutContext(
                    baseValue: fossil.baseValue, exposure: exposure, boneCells: 600,
                    crackedCells: 12, wholeGems: 2, daylightRemaining: 6,
                    totalDaylight: tuning.daylightSeconds
                ))
                fossilTotal += Double(payout.fossil)
                gemTotal += Double(payout.gems)
                n += 1
            }
            let share = gemTotal / max(1, fossilTotal + gemTotal)
            print(String(format: "  exposure %.0f%%  fossil $%.0f  gems $%.0f  gems are %.0f%%",
                         exposure * 100, fossilTotal / n, gemTotal / n, share * 100))
            // Checked from 70% up. A poor dig leaning on gems is reasonable -- they are
            // the consolation for a slab that went badly. A *competent* dig paid mostly in
            // gems means the fossil is optional, which is the whole game being optional.
            guard exposure >= 0.7 else { continue }
            XCTAssertLessThan(
                share, 0.3,
                "at \(Int(exposure * 100))% exposure gems are \(Int(share * 100))% of the "
                    + "slab, so the fossil is optional and the dig is a gem hunt"
            )
        }
    }

    /// Gems should be a bonus for noticing something, not the reason to dig.
    func testGemsAreNotMostOfASlab() {
        let r = play(.average, site: "charmouth")
        let share = r.gems / max(1, r.payout)
        XCTAssertLessThan(
            share, 0.25,
            "gems are \(Int(share * 100))% of a slab, so the fossil is a side quest"
        )
    }
}
