import Foundation

/// How wide the finger is on the glass, turned into a brush.
///
/// iOS gives exactly one number about the shape of a touch: `UITouch.majorRadius`, in
/// points. There is no orientation and no minor axis — `azimuthAngle` and `altitudeAngle`
/// are documented as stylus-only — so a fingertip cannot be told from the side of a finger
/// by direction. It can be told by *size*, because the side of a finger lays down a much
/// larger patch than the tip does.
///
/// That one scalar is enough for the thing worth having: brush with the tip for detail
/// around exposed bone, lay the flat of a finger down to sweep overburden. It is the real
/// motion of the job, with no button for it.
///
/// **Self-calibrating, because the absolute numbers are not documented.** Apple states the
/// units and an error bar and nothing about what a finger produces, and the answer varies
/// by device and by how hard somebody presses. So this learns instead: the smallest patch
/// it has seen is taken to be that player's fingertip, and everything is measured against
/// it. A hardcoded "a fingertip is 10 points" would be wrong on some hardware and for some
/// hands, and wrong in a way nobody could diagnose.
public struct ContactScale: Sendable, Equatable {

    /// The smallest radius seen so far, taken to be the player's fingertip.
    public private(set) var tipRadius: Float
    /// What the last sample worked out to, for the debug overlay.
    public private(set) var lastScale: Float = 1
    public private(set) var lastRadius: Float = 0

    private let tuning: SimTuning

    public init(tuning: SimTuning = .standard) {
        self.tuning = tuning
        // Starts at the largest plausible fingertip rather than at infinity, so the first
        // stroke of a dig is already scaled sensibly instead of reading as a tip merely
        // because it is the first thing seen.
        self.tipRadius = tuning.contactAssumedTipPoints
    }

    /// Folds in a sample and returns the multiplier for the brush.
    ///
    /// Clamped at both ends. Below 1 would make a careful touch *worse* than the tool its
    /// owner paid for, which is punishing somebody for being delicate; the ceiling stops a
    /// palm resting on the glass from clearing a slab in one stroke.
    @discardableResult
    public mutating func accept(radius: Float) -> Float {
        guard radius > 0 else { return lastScale }
        lastRadius = radius

        // The baseline only ever shrinks, and slowly, so one unusually light touch cannot
        // recalibrate everything after it. It never grows: a player whose tip reads smaller
        // once their hand settles keeps the better number.
        if radius < tipRadius {
            tipRadius = max(
                tuning.contactMinTipPoints,
                tipRadius + (radius - tipRadius) * tuning.contactCalibrationRate
            )
        }

        let ratio = radius / max(0.001, tipRadius)
        lastScale = min(max(ratio, 1), tuning.contactMaxScale)
        return lastScale
    }

    /// The tool as the finger is currently holding it.
    ///
    /// Radius grows with the contact patch and safe speed falls as its square root. That
    /// second part is the whole trade: a broad contact covers ground quickly and is harder
    /// to place, so the flat of a finger is for overburden and the tip is for anything near
    /// bone. Without it, pressing harder would be strictly better and there would be no
    /// reason ever to use the tip.
    public func applied(to tool: BrushTool) -> BrushTool {
        guard lastScale > 1 else { return tool }
        var scaled = tool
        scaled.radius *= lastScale
        scaled.safeSpeed /= lastScale.squareRoot()
        return scaled
    }
}
