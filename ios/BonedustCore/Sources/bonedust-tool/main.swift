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

/// Writes a scaled PPM, for the `shapes` command.
func writeShapePPM(_ pixels: [UInt8], to path: String, scale: Int) throws {
    let w = SlabGrid.width, h = SlabGrid.height
    var out = Data("P6\n\(w * scale) \(h * scale)\n255\n".utf8)
    out.reserveCapacity(out.count + w * h * scale * scale * 3)
    for y in 0..<h {
        var row = Data()
        row.reserveCapacity(w * scale * 3)
        for x in 0..<w {
            let o = (y * w + x) * 4
            for _ in 0..<scale {
                row.append(pixels[o]); row.append(pixels[o + 1]); row.append(pixels[o + 2])
            }
        }
        for _ in 0..<scale { out.append(row) }
    }
    try out.write(to: URL(fileURLWithPath: path))
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

case "golden":
    // Emits the cross-language fixture for §6's golden test: the server's Ruby port
    // reads this and must reach identical values from the same seeds.
    let path = arguments.count > 1 ? arguments[1] : "shared/golden/derivations.json"
    var derivations: [ServerCeiling.SlabDerivation] = []
    for site in ContentCatalog.shared.sites {
        for index in 0..<50 {
            let seed: UInt64 = 0x901D_E000 ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            derivations.append(ServerCeiling.derive(seed: seed, site: site))
        }
    }
    let goldenEncoder = JSONEncoder()
    goldenEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let goldenData = try goldenEncoder.encode(derivations)
    try goldenData.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write(
        Data("wrote \(derivations.count) derivations to \(path)\n".utf8)
    )

case "shapes":
    // One PNG per species, the fossil centred and alone.
    //
    // `render` draws site scenes, which show whatever the seed happened to pick -- fine for
    // checking a palette, useless for checking that a shape reads as a skull. This draws
    // every species in the catalogue, which is the only way to know that 117 hand-written
    // parameter sets all produce something worth digging up. The first run of the
    // equivalent test found nine that did not.
    let shapesDir = arguments.count > 1 ? arguments[1] : "build/shapes"
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: shapesDir), withIntermediateDirectories: true
    )
    let shapeScale = Int(arguments.count > 2 ? arguments[2] : "4") ?? 4
    let shapeCatalog = ContentCatalog.shared
    var rendered = 0
    for fossil in shapeCatalog.fossils {
        var grid = SlabGrid()
        for i in 0..<SlabGrid.cellCount { grid.cells[i].depth = 0 }
        let centred = ShapeTransform(
            scale: fossil.shape.spanCells / 2,
            rotation: 0,
            center: Vec2(Float(SlabGrid.width) / 2, Float(SlabGrid.height) / 2)
        )
        let cells = ShapeRasterizer.rasterize(
            fossil.shape.expand(), transform: centred,
            flag: SlabGrid.Flag.bone, into: &grid
        )
        var renderer = SlabRenderer()
        renderer.redrawEverything(grid)
        try writeShapePPM(
            renderer.pixels,
            to: "\(shapesDir)/\(fossil.shape.kind.rawValue)-\(fossil.id).ppm",
            scale: shapeScale
        )
        rendered += 1
        if cells < 60 { print("  WARNING \(fossil.id) is only \(cells) cells") }
    }
    print("wrote \(rendered) shapes to \(shapesDir)")

case "render":
    // Renders slabs to PNG, headlessly.
    //
    // This exists so the rendering can be *looked at*. The palette, the depth-1 bone tell
    // and the bone edge shading are judgements the eye makes; a unit test can only confirm
    // that some pixel got brighter. It doubles as the source of App Store screenshots
    // (§9), which are then reproducible from a seed rather than captured by hand.
    let outDir = arguments.count > 1 ? arguments[1] : "build/render"
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: outDir), withIntermediateDirectories: true
    )
    let scale = Int(arguments.count > 2 ? arguments[2] : "4") ?? 4

    /// Writes a scaled PPM. Nearest-neighbour, because that is what the game does and a
    /// smoothed screenshot would misrepresent it.
    func writePPM(_ pixels: [UInt8], to path: String, scale: Int) throws {
        let w = SlabGrid.width, h = SlabGrid.height
        var out = Data("P6\n\(w * scale) \(h * scale)\n255\n".utf8)
        out.reserveCapacity(out.count + w * scale * h * scale * 3)
        for y in 0..<(h * scale) {
            let sourceY = y / scale
            for x in 0..<(w * scale) {
                let offset = (sourceY * w + x / scale) * 4
                out.append(pixels[offset])
                out.append(pixels[offset + 1])
                out.append(pixels[offset + 2])
            }
        }
        try out.write(to: URL(fileURLWithPath: path))
    }

    /// Sweeps the slab, optionally fast enough to wreck it.
    func dig(_ sim: inout SlabSimulation, tool: BrushTool, passes: Int, cellsPerSample: Float) {
        let rowStep = max(1.2, tool.radius * 0.85)
        sim.beginStroke(at: Vec2(3, 3), tool: tool)
        for _ in 0..<passes {
            var y: Float = 3
            var row = 0
            while y < Float(SlabGrid.height) - 3 {
                let forward = row % 2 == 0
                let xs = forward
                    ? stride(from: Float(3), through: Float(SlabGrid.width) - 3, by: cellsPerSample)
                    : stride(from: Float(SlabGrid.width) - 3, through: 3, by: -cellsPerSample)
                for x in xs {
                    sim.moveStroke(to: Vec2(x, y), deltaMillis: 16.67, tool: tool)
                }
                y += rowStep
                row += 1
                // Lift between passes rather than dragging back across the slab.
                sim.endStroke()
                sim.beginStroke(at: Vec2(forward ? Float(SlabGrid.width) - 3 : 3, y), tool: tool)
            }
        }
        sim.endStroke()
    }

    var written: [String] = []
    for site in ContentCatalog.shared.sites {
        // A seed per site that turns up a recognisable fossil.
        let seed: UInt64 = 0x5CE_0000 ^ UInt64(abs(site.id.hashValue % 9_973))
        let states: [(String, (inout SlabSimulation) -> Void)] = [
            ("1-untouched", { _ in }),
            ("2-started", { dig(&$0, tool: .brush, passes: 1, cellsPerSample: 2.0) }),
            ("3-exposed", { dig(&$0, tool: .fineBrush, passes: 9, cellsPerSample: 1.0) }),
            ("4-wrecked", { dig(&$0, tool: .airBlower, passes: 6, cellsPerSample: 14) }),
            // Cleared to sandstone and no further. This is the only state in which §3's
            // tell is doing its job, and the only way to know whether a player can
            // actually see bone coming is to look at it.
            ("5-tell", { sim in
                for index in 0..<SlabGrid.cellCount {
                    sim.setDepthForRendering(index, depth: 1)
                }
            }),
        ]
        for (label, action) in states {
            var sim = SlabSimulation(seed: seed, site: site)
            sim.crackMultiplier = site.modifiers.crackMultiplier
            action(&sim)
            var renderer = SlabRenderer(palette: site.palette)
            renderer.lightLevel = site.modifiers.lightLevel
            renderer.redrawEverything(sim.grid)
            let name = "\(site.id)-\(label)"
            try writePPM(renderer.pixels, to: "\(outDir)/\(name).ppm", scale: scale)
            written.append(name)
            print(name.padding(toLength: 26, withPad: " ", startingAt: 0)
                + sim.layout.fossilID.padding(toLength: 20, withPad: " ", startingAt: 0)
                + String(format: "exposure %.2f  intact %.2f", sim.exposure, sim.intact))
        }
    }

    // An X-ray view, to check the reveal tint reads at all.
    if let site = ContentCatalog.shared.site("charmouth") {
        var sim = SlabSimulation(seed: 0x5CE_0000, site: site)
        var renderer = SlabRenderer(palette: site.palette)
        renderer.revealBuriedBone = true
        renderer.redrawEverything(sim.grid)
        try writePPM(renderer.pixels, to: "\(outDir)/charmouth-5-xray.ppm", scale: scale)
        written.append("charmouth-5-xray")
        _ = sim
    }

    FileHandle.standardError.write(
        Data("wrote \(written.count) frames to \(outDir)\n".utf8)
    )

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
