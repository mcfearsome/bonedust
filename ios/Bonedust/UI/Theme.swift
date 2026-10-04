import SwiftUI

/// Holds the palette the whole page is currently drawn in.
///
/// Night digs used to dim only the slab. Against a cream page that reads as a
/// rendering bug, so one `lightLevel` now drives both surfaces: the page darkens
/// toward lamplight as the slab does. The pleasant side effect is a real dark mode.
@Observable
final class Theme {

    /// Where the page stops getting darker. Below this the slab keeps dimming but
    /// the page does not, because a notebook under a headlamp is not black.
    static let nightFloor: Float = 0.35

    /// Where the palette flips. A switch, not a blend: see spec §6. Blending two
    /// inverted palettes drives text and page together — ink-on-page is 1.09:1 at
    /// the midpoint, and night_dig's lightLevel 0.55 lands at t=0.69, i.e. 2.52:1.
    static let switchPoint: Double = 0.5

    var lightLevel: Float = 1 {
        didSet { ink = Theme.nightFraction(for: lightLevel) >= Theme.switchPoint ? .night : .day }
    }

    private(set) var ink: Ink = .day

    init() {}

    /// How far toward the night palette a given light level sits, 0...1.
    ///
    /// Pure and static so the clamping can be tested without a view. NaN maps to
    /// daylight rather than propagating: an unreadable page is worse than a page
    /// that ignores a bad input.
    ///
    /// `Theme` is deliberately not `@MainActor`: `EnvironmentValues` builds its
    /// default value outside any actor, and isolating the class makes `@Entry`
    /// fail to compile.
    static func nightFraction(for lightLevel: Float) -> Double {
        guard lightLevel.isFinite else { return lightLevel < 0 ? 1 : 0 }
        let span = 1 - nightFloor
        let raw = (1 - lightLevel) / span
        return Double(min(max(raw, 0), 1))
    }
}

extension Theme {
    /// What `EnvironmentValues` hands out when nothing was injected.
    ///
    /// One shared instance, not an inline `Theme()`: `@Entry` expands its initial
    /// value into a computed `defaultValue`, so an inline initialiser builds a new
    /// object on every read. Anything set on one read is gone on the next, and every
    /// dependent view sees a different value each time. The app root still injects
    /// its own with `.environment(\.theme, theme)`; this is only what an un-injected
    /// view gets.
    fileprivate static let environmentDefault = Theme()
}

extension EnvironmentValues {
    @Entry var theme = Theme.environmentDefault
}
