import BonedustCore
import XCTest

@testable import Bonedust

/// Brushes a slab the way a careful player would, for the tests that need material off
/// before they can assert anything.
///
/// This replaced four hand-written copies of the same loop, each of which had quietly
/// picked its own wrong constants. Three mistakes are worth recording, because each one
/// made a test assert something other than what it claimed:
///
/// **1. The stroke speed was picked by eye.** `speed` is cells per 60 Hz frame and the
/// standard brush's `safeSpeed` is 1.4, so a sweep written `by: 1.5` with
/// `deltaMillis: 16.67` is 1.5 cells per frame — over the line, and it cracks. It reads as
/// slow because 1.5 is a small number. The step comes from `engine.safeSpeed`, which
/// already folds in the tool and charms like Steady Hands, so this stays right for the air
/// blower at 0.75 and for a loadout that raises the limit. No constant survives both.
///
/// **2. The brush teleported between rows.** Sweeping left to right and restarting the next
/// row at x = 6 with the finger still down is an 84-cell jump in one frame — 60 times the
/// safe speed. It was the entire measured cause of cracking in a sweep otherwise under the
/// limit, and the same defect once suppressed the economy sweep's income by about 25%.
///
/// **3. Removing the teleport removed work the tests were relying on.** The jump was not
/// just a speed spike: `moveStroke` interpolates along it, so every wrap brushed a full
/// diagonal stripe across the slab. Lifting the brush was correct and made three tests fail,
/// because they had been getting a third of their coverage from a bug. Rows are now spaced
/// by the brush radius and a *covering* means the whole slab, so coverage is a property of
/// the geometry rather than a side effect.
///
/// The row count is derived, not chosen: `% 116` with rows 4 apart silently visits only 29
/// distinct rows however high the pass limit goes, which is how "40 passes" came to mean
/// "29 rows, 11 of them twice".
///
/// `publish()` is called before each check of `isDone`, because most of what a test wants to
/// wait on — `isIdentified`, `exposurePercent`, `intactPercent` — is a HUD scalar that the
/// engine only refreshes there, once per frame. Reading one of those without publishing gets
/// the value from before the sweep started, forever, and a `sweepUntil…` built on it runs to
/// its cap and reports failure on a slab it has in fact cleared.
@MainActor
@discardableResult
func sweepSlab(
    _ engine: DigEngine, coverings: Int, until isDone: () -> Bool = { false }
) -> Bool {
    // 70% of the limit. The EMA lags a change in velocity, so a step sitting exactly on the
    // line crosses it on the rounding; the margin is what makes "this sweep cracks nothing"
    // a property of the helper instead of a coin flip.
    let step = max(0.1, engine.safeSpeed * 0.7)
    // 80% of the brush radius, so consecutive rows overlap rather than leaving unbrushed
    // stripes between them.
    let rowGap = max(1, engine.tool.radius * 0.8)
    let margin: Float = 2
    let lastX = Float(SlabGrid.width) - margin
    let lastY = Float(SlabGrid.height) - margin

    for _ in 0..<coverings {
        var y = margin
        while y <= lastY {
            engine.publish()
            if isDone() { return true }
            engine.brushBegan(at: Vec2(margin, y))
            for x in stride(from: margin + step, through: lastX, by: step) {
                engine.brushMoved(to: Vec2(x, y), deltaMillis: 16.67)
            }
            // Lifted before the jump back to the left edge. This is mistake 2 above, and
            // what a hand does anyway.
            engine.brushEnded()
            y += rowGap
        }
    }
    engine.publish()
    return isDone()
}

/// Brushes until bone is showing. Returns false if it never got there, which is a real
/// failure rather than something for a test to shrug at: every fixed pass count in these
/// tests has at some point silently asserted against an untouched slab.
@MainActor
@discardableResult
func sweepUntilBoneShows(_ engine: DigEngine, coverings: Int = 8) -> Bool {
    sweepSlab(engine, coverings: coverings, until: { engine.exposedBoneCells > 0 })
}

/// Brushes until there is enough of the fossil showing to name it.
@MainActor
@discardableResult
func sweepUntilIdentified(_ engine: DigEngine, coverings: Int = 12) -> Bool {
    sweepSlab(engine, coverings: coverings, until: { engine.specimenName != "Unidentified" })
}
