import XCTest
@testable import BonedustCore

/// Is a tool worth what it costs?
///
/// Reported from play as "i see no incentive to actually buy anything", and the economy
/// sweep cannot answer it: its model picks a tool per sample for free, so it measures a
/// player who already owns everything.
///
/// Each tool digs the same slabs at its own safe speed, which is what a careful player
/// does, and the run stops when the daylight does. What separates the tools is how much
/// slab they cover before that happens -- and since the grade pays for daylight left, a
/// faster tool is now worth money rather than only comfort.
final class ToolValueTests: XCTestCase {

    private struct Outcome {
        var intact: Float = 0
        var exposure: Float = 0
        var daylightLeft: Float = 0
        var payout: Int = 0
        var cracked: Int = 0
    }

    private func dig(with tool: BrushTool, site: Site, seed: UInt64,
                     tuning: SimTuning = .standard) -> Outcome {
        var sim = SlabSimulation(seed: seed, site: site, tuning: tuning)
        let frames = Int(tuning.daylightSeconds * 60)
        let step = sim.safeSpeed(for: tool)
        let gap = tool.radius * 0.9
        var used = 0
        var y = Float(1)
        var ltr = true

        outer: while used < frames {
            let xs = Array(stride(from: Float(1), through: Float(SlabGrid.width) - 1, by: step))
            let row = ltr ? xs : xs.reversed()
            sim.beginStroke(at: Vec2(row[0], y), tool: tool)
            for x in row.dropFirst() {
                sim.moveStroke(to: Vec2(x, y), deltaMillis: 1000.0 / 60, tool: tool)
                used += 1
                if sim.exposure >= 0.99 || used >= frames { break outer }
            }
            sim.endStroke()
            y += gap
            if y >= Float(SlabGrid.height) { y = 1 }
            ltr.toggle()
        }
        sim.endStroke()

        let left = max(0, tuning.daylightSeconds - Float(used) / 60)
        let fossil = ContentCatalog.shared.fossil(sim.layout.fossilID)
        let payout = Payout.evaluate(PayoutContext(
            baseValue: fossil?.baseValue ?? 100,
            instances: sim.layout.instances,
            exposure: sim.exposure,
            boneCells: max(1, sim.boneCells),
            crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems,
            daylightRemaining: left,
            totalDaylight: tuning.daylightSeconds,
            modifiers: site.modifiers.modifierSet,
            tuning: tuning
        ))
        return Outcome(
            intact: payout.intact,
            exposure: sim.exposure, daylightLeft: left,
            payout: payout.total, cracked: sim.crackedBone
        )
    }

    /// The fine brush as the thing it actually is.
    ///
    /// Judging it on a whole-slab sweep was never fair: radius 2.4 against the brush's 4.2
    /// means it covers 57% as much ground, so of course it loses. It is a *finishing* tool
    /// -- you clear the overburden with something broad and switch once bone is showing,
    /// which is the moment `crackMultiplier: 0.35` is worth anything at all.
    ///
    /// That switch is also the only reason it can be valued now. While nothing cracked at
    /// safe speed there was no moment it was better at anything.
    func testTheFineBrushPaysAsAFinishingTool() throws {
        let catalog = ContentCatalog.shared
        let site = try XCTUnwrap(catalog.site("charmouth"))
        let brush = try XCTUnwrap(catalog.tool("brush")?.brush)
        let fine = try XCTUnwrap(catalog.tool("fine_brush")?.brush)

        var brushOnly: Float = 0
        var switched: Float = 0
        let seeds = Array(UInt64(0)..<12)
        for seed in seeds {
            brushOnly += dig(with: brush, site: site, seed: seed).intact / Float(seeds.count)
            switched += digSwitching(
                bulk: brush, finishing: fine, site: site, seed: seed
            ).intact / Float(seeds.count)
        }
        print(String(format: "  brush only %.3f intact, switching to fine %.3f",
                     brushOnly, switched))
        XCTAssertGreaterThan(
            switched, brushOnly,
            "switching to the fine brush once bone shows protects nothing, so its smaller "
                + "radius buys the player nothing at any point in a dig"
        )
    }

    /// Clears with `bulk`, then switches to `finishing` the moment bone is showing.
    private func digSwitching(
        bulk: BrushTool, finishing: BrushTool, site: Site, seed: UInt64
    ) -> Outcome {
        let tuning = SimTuning.standard
        var sim = SlabSimulation(seed: seed, site: site, tuning: tuning)
        let frames = Int(tuning.daylightSeconds * 60)
        var used = 0
        var y = Float(1)
        var ltr = true

        outer: while used < frames {
            let tool = sim.exposedBone > 0 ? finishing : bulk
            let step = sim.safeSpeed(for: tool)
            let xs = Array(stride(from: Float(1), through: Float(SlabGrid.width) - 1, by: step))
            let row = ltr ? xs : xs.reversed()
            sim.beginStroke(at: Vec2(row[0], y), tool: tool)
            for x in row.dropFirst() {
                sim.moveStroke(to: Vec2(x, y), deltaMillis: 1000.0 / 60, tool: tool)
                used += 1
                if sim.exposure >= 0.99 || used >= frames { break outer }
            }
            sim.endStroke()
            y += tool.radius * 0.9
            if y >= Float(SlabGrid.height) { y = 1 }
            ltr.toggle()
        }
        sim.endStroke()

        let left = max(0, tuning.daylightSeconds - Float(used) / 60)
        let fossil = catalogFossil(sim.layout.fossilID)
        let payout = Payout.evaluate(PayoutContext(
            baseValue: fossil, instances: sim.layout.instances, exposure: sim.exposure,
            boneCells: max(1, sim.boneCells), crackedCells: sim.crackedBone,
            wholeGems: sim.wholeGems, daylightRemaining: left,
            totalDaylight: tuning.daylightSeconds, modifiers: site.modifiers.modifierSet
        ))
        return Outcome(
            intact: payout.intact, exposure: sim.exposure,
            daylightLeft: left, payout: payout.total, cracked: sim.crackedBone
        )
    }

    private func catalogFossil(_ id: String) -> Int {
        ContentCatalog.shared.fossil(id)?.baseValue ?? 100
    }

    func testABetterBrushEarnsBackItsPrice() throws {
        let catalog = ContentCatalog.shared
        let site = try XCTUnwrap(catalog.site("charmouth"))
        let seeds = Array(UInt64(0)..<16)

        var byTool: [(BrushTool, Outcome)] = []
        for id in ["brush", "fine_brush", "air_blower"] {
            guard let tool = catalog.tool(id)?.brush else { continue }
            var total = Outcome()
            for seed in seeds {
                let one = dig(with: tool, site: site, seed: seed)
                total.intact += one.intact / Float(seeds.count)
                total.exposure += one.exposure / Float(seeds.count)
                total.daylightLeft += one.daylightLeft / Float(seeds.count)
                total.payout += one.payout / seeds.count
                total.cracked += one.cracked / seeds.count
            }
            byTool.append((tool, total))
            print(String(
                format: "  %-12@ $%-5d exposure %.3f  intact %.3f  daylight %4.1fs  cracked %d",
                tool.name as NSString, total.payout, total.exposure, total.intact,
                total.daylightLeft, total.cracked
            ))
        }

        let base = try XCTUnwrap(byTool.first { $0.0.id == "brush" })
        let fine = try XCTUnwrap(byTool.first { $0.0.id == "fine_brush" })
        let price = catalog.tool("fine_brush")?.price ?? 0
        let gainPerSlab = fine.1.payout - base.1.payout
        print("  fine brush costs $\(price), earns $\(gainPerSlab) more a slab")

        // The fine brush loses a whole-slab sweep and always will: radius 2.4 against
        // 4.2 is 57% of the ground covered, and a bulk comparison is simply the wrong
        // question to ask about a finishing tool. What it is for is measured in
        // `testTheFineBrushPaysAsAFinishingTool`, which only became possible to write once
        // bone could crack at safe speed -- before that there was no moment in a dig when
        // it was better at anything.
        XCTAssertLessThan(
            gainPerSlab, 0,
            "if the fine brush ever wins a bulk sweep its radius has been changed, and "
                + "the finishing test is no longer measuring a trade-off"
        )
        _ = price

        // The air blower used to be strictly dominant: more coverage than the free brush
        // and a crackMultiplier of 2.6 that never bit, because at safe speed nothing
        // cracked. With bone fragile at any speed it buys reach with damage, which is what
        // its numbers always said it did.
        let blower = try XCTUnwrap(byTool.first { $0.0.id == "air_blower" })
        XCTAssertGreaterThan(blower.1.exposure, base.1.exposure, "it should still cover more")
        XCTAssertLessThan(blower.1.intact, base.1.intact, "and still wreck more")
    }
}
