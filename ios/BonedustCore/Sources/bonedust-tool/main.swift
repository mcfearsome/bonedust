import BonedustCore
import Foundation

// A tiny CLI for the two jobs that need to run outside the app:
//   dump-constants  — writes shared/constants.json for the Rails service (§6)
//   simulate        — runs the economy sim from §9's acceptance criteria

extension String {
    /// Right-aligns in a field of `width`. Used instead of printf padding so that no
    /// Swift String ever reaches a %s conversion.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

switch command {
case "dump-constants":
    let path = arguments.count > 1
        ? arguments[1]
        : "shared/constants.json"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = SharedConstants(tuning: .standard, catalog: .shared)
    let data = try encoder.encode(payload)
    try data.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write(
        Data("wrote \(data.count) bytes to \(path)\n".utf8)
    )

case "bench":
    // §9 wants 60 fps on an iPhone 12 while brushing with the air blower. This
    // measures the simulation half of that budget: the worst realistic frame is a
    // fast swipe with the 7.5-cell blower, which splits into ~8 steps of ~176 cells.
    // A Mac is not an iPhone 12, but a regression here is a regression there.
    //
    // The slab is regenerated every `framesPerSlab` frames. Without that, the slab
    // clears after a few hundred frames and the rest of the run measures the cheap
    // already-at-depth-zero path, which flatters the result by an order of magnitude.
    guard let site = ContentCatalog.shared.site("hell_creek") else { exit(1) }
    let framesPerSlab = 220
    let slabs = 40
    let tool = BrushTool.airBlower
    var cellsTouched = 0
    var worst: Double = 0
    var worstAt = (slab: -1, frame: -1)
    var spikes: [(Int, Int, Double)] = []
    var totalNanos: UInt64 = 0

    for slab in 0..<slabs {
        var sim = SlabSimulation(seed: UInt64(20_260_102 + slab), site: site)
        var x: Float = 10
        var direction: Float = 1
        sim.beginStroke(at: Vec2(x, 64), tool: tool)
        for frame in 0..<framesPerSlab {
            x += direction * 20
            if x > 86 { x = 86; direction = -1 }
            if x < 10 { x = 10; direction = 1 }
            let y = 8 + Float((frame * 5) % 112)
            let started = DispatchTime.now().uptimeNanoseconds
            let result = sim.moveStroke(to: Vec2(x, y), deltaMillis: 16.67, tool: tool)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            totalNanos += elapsed
            cellsTouched += result.cellsWorn
            let micros = Double(elapsed) / 1_000
            if micros > worst { worst = micros; worstAt = (slab, frame) }
            if micros > 1_000 { spikes.append((slab, frame, micros)) }
        }
        sim.endStroke()
    }

    let frames = framesPerSlab * slabs
    let perFrameMicros = Double(totalNanos) / Double(frames) / 1_000
    let budget = 16_666.0
    print(String(
        format: "air blower, %d frames over %d slabs:", frames, slabs
    ))
    print(String(
        format: "  mean  %6.1f us/frame  (%.2f%% of a 60 Hz frame)",
        perFrameMicros, perFrameMicros / budget * 100
    ))
    print(String(format: "  worst %6.1f us/frame  (%.2f%%) at slab %d frame %d",
                 worst, worst / budget * 100, worstAt.slab, worstAt.frame))
    print("  frames over 1 ms: \(spikes.count)"
        + (spikes.isEmpty ? "" : " -> " + spikes.prefix(6).map {
            "slab \($0.0)/frame \($0.1) \(Int($0.2))us"
          }.joined(separator: ", ")))
    print(String(
        format: "  %d cells worn, %.1fM cell-visits/s",
        cellsTouched,
        Double(cellsTouched) / (Double(totalNanos) / 1_000_000_000) / 1_000_000
    ))
    if perFrameMicros > budget * 0.25 {
        print("FAIL: simulation is using more than a quarter of the frame budget")
        exit(1)
    }

case "simulate":
    // §9: 10,000 runs with a scripted average player, win rate per installment tier.
    // Target is ~70% at tier 1 falling to ~30% by tier 5.
    var runsPerTier = 2_000
    var siteID = "charmouth"
    var policy = PlayerPolicy.average
    var policyName = "average"
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--runs" where index + 1 < arguments.count:
            // The brief states 10,000 runs total, spread across the tiers.
            runsPerTier = max(1, (Int(arguments[index + 1]) ?? 10_000) / 5)
            index += 2
        case "--site" where index + 1 < arguments.count:
            siteID = arguments[index + 1]
            index += 2
        case "--policy" where index + 1 < arguments.count:
            policyName = arguments[index + 1]
            switch policyName {
            case "careful": policy = .careful
            case "reckless": policy = .reckless
            default: policy = .average
            }
            index += 2
        default:
            index += 1
        }
    }

    guard ContentCatalog.shared.site(siteID) != nil else {
        print("unknown site \(siteID)")
        exit(1)
    }

    let started = Date()
    // Careers, not independent runs: a tier 5 attempt made with nothing but the
    // starting brush is not a situation any player is ever in.
    let reports = EconomySimulator.careers(
        count: runsPerTier, siteID: siteID, policy: policy
    )
    let elapsed = Date().timeIntervalSince(started)

    print("site \(siteID), policy \(policyName), \(runsPerTier) careers "
        + "in \(String(format: "%.1f", elapsed))s")
    print("")
    print("tier  owed   win%   target  mean $  mean slab  exposure  intact")
    // The §9 curve, in the table rather than from memory.
    let targets: [Int: Double] = [1: 0.70, 2: 0.60, 3: 0.48, 4: 0.38, 5: 0.30]
    for report in reports {
        // Built by interpolation, not String(format:). Passing a Swift String to a
        // %s conversion hands printf something that is not a C string, and it
        // segfaults rather than printing wrong.
        let target = targets[report.tier].map { String(format: "%.0f%%", $0 * 100) } ?? "-"
        let row = [
            String(report.tier).leftPadded(to: 4),
            String(report.installment).leftPadded(to: 6),
            String(format: "%.1f%%", report.winRate * 100).leftPadded(to: 7),
            target.leftPadded(to: 7),
            String(format: "%.0f", report.meanEarned).leftPadded(to: 8),
            String(format: "%.0f", report.meanSlabPayout).leftPadded(to: 11),
            String(format: "%.3f", report.meanExposure).leftPadded(to: 10),
            String(format: "%.3f", report.meanIntact).leftPadded(to: 8),
        ]
        print(row.joined())
    }
    print("")
    // Report, do not fail: this baseline has no shop, and §4's economy assumes the
    // player is buying tools and charms. The number to hold to the target is the one
    // measured once M3 lands.
    let tier1 = reports.first { $0.tier == 1 }?.winRate ?? 0
    let tier5 = reports.first { $0.tier == 5 }?.winRate ?? 0
    print(String(format: "tier 1 %.0f%% -> tier 5 %.0f%%", tier1 * 100, tier5 * 100))

case "sites":
    // Income per site for the same player and kit. The Reputation-gated sites have to
    // actually be richer, or unlocking them is a downgrade and the installment ramp
    // has nothing to keep up with it.
    let seeds: [UInt64] = (0..<300).map { 0xD1A6_0000 + UInt64($0) * 7919 }
    print("  site                income/slab  exposure  intact  instances  unlock")
    for site in ContentCatalog.shared.sites {
        var total = 0.0, exposure = 0.0, intact = 0.0, instances = 0.0
        for seed in seeds {
            let record = EconomySimulator.playSlab(
                seed: seed, day: 1, site: site, policy: .average,
                loadout: Loadout.resolve(toolIDs: ["brush"], charmIDs: [])
            )
            total += Double(record.payout.total)
            exposure += Double(record.payout.exposure)
            intact += Double(record.payout.intact)
            instances += Double(SlabGenerator.generate(seed: seed, site: site).layout.instances)
        }
        let n = Double(seeds.count)
        print("  " + site.id.padding(toLength: 18, withPad: " ", startingAt: 0)
            + String(format: "    $%6.1f     %6.3f   %5.3f    %5.2f    ",
                     total / n, exposure / n, intact / n, instances / n)
            + site.unlock.label)
    }

case "speeds":
    // What survey speed would a sensible person converge on? Defining the "average"
    // player as a speed plucked out of the air is how a balance tool lies to you.
    let site = ContentCatalog.shared.site(arguments.count > 1 ? arguments[1] : "charmouth")!
    let seeds: [UInt64] = (0..<220).map { 0xD1A6_0000 + UInt64($0) * 7919 }
    print("\(site.name) — survey speed vs income, starting brush only")
    print("  cells/frame   exposure  intact   $/slab   s left")
    for speed in [Float(1.2), 1.6, 2.0, 2.4, 2.8, 3.2, 4.0, 5.0] {
        var policy = PlayerPolicy.average
        policy.clearingSpeed = speed
        var exposure = 0.0, intact = 0.0, total = 0.0, left = 0.0
        for seed in seeds {
            let record = EconomySimulator.playSlab(
                seed: seed, day: 1, site: site, policy: policy,
                loadout: Loadout.resolve(toolIDs: ["brush"], charmIDs: [])
            )
            exposure += Double(record.payout.exposure)
            intact += Double(record.payout.intact)
            total += Double(record.payout.total)
            left += Double(record.daylightLeft)
        }
        let n = Double(seeds.count)
        print(String(format: "  %11.1f   %6.3f   %5.3f   %6.1f   %5.1f",
                     speed, exposure / n, intact / n, total / n, left / n))
    }

case "content-check":
    let problems = ContentCatalog.shared.validate()
    if problems.isEmpty {
        let catalog = ContentCatalog.shared
        print("content ok: \(catalog.fossils.count) fossils, \(catalog.sites.count) sites, "
            + "\(catalog.sets.count) sets, \(catalog.tools.count) tools, "
            + "\(catalog.charms.count) charms, \(catalog.achievements.count) achievements, "
            + "\(catalog.trails.count) trails")
    } else {
        for problem in problems { print("content problem: \(problem)") }
        exit(1)
    }

default:
    print("""
    bonedust-tool <command>

      dump-constants [path]   write the Swift/Ruby shared constants file
      content-check           validate content.json references
      bench                   worst-case frame time for the brush loop
      simulate [--runs 10000] [--site charmouth] [--policy average|careful|reckless]
                              win rate per installment tier
    """)
}
