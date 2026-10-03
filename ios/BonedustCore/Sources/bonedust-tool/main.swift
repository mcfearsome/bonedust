import BonedustCore
import Foundation

// A tiny CLI for the two jobs that need to run outside the app:
//   dump-constants  — writes shared/constants.json for the Rails service (§6)
//   simulate        — runs the economy sim from §9's acceptance criteria

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

case "content-check":
    let problems = ContentCatalog.shared.validate()
    if problems.isEmpty {
        print("content ok: \(ContentCatalog.shared.fossils.count) fossils, "
            + "\(ContentCatalog.shared.sites.count) sites, "
            + "\(ContentCatalog.shared.sets.count) sets")
    } else {
        for problem in problems { print("content problem: \(problem)") }
        exit(1)
    }

default:
    print("""
    bonedust-tool <command>

      dump-constants [path]   write the Swift/Ruby shared constants file
      content-check           validate content.json references
    """)
}
