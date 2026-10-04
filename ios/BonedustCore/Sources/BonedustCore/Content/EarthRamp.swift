import Foundation

/// The one colour ramp. Chrome takes the light end, the slab takes the dark end.
///
/// This lives in Core, not the app, for one reason: it must be testable without a
/// simulator. The contrast guarantees in `EarthRampTests` are the whole point of
/// the ramp, and they would be untestable sitting next to SwiftUI.
///
/// Values are the spec's hex table verbatim. If you change one, the tests tell you
/// which guarantee you broke.
public enum Earth {
    /// Pasted-label / raised surface.
    public static let s0 = RGB8(0xF6, 0xEF, 0xDE)
    /// The page.
    public static let s1 = RGB8(0xED, 0xE4, 0xCF)
    /// Ruled box fill.
    public static let s2 = RGB8(0xDF, 0xD4, 0xBB)
    /// Grid, dividers, hairlines.
    public static let s3 = RGB8(0xC4, 0xB5, 0x96)
    /// Decorative and disabled only. Never text — see `testDecorativeStopsCannotCarryBodyText`.
    public static let s4 = RGB8(0x9C, 0x8A, 0x6E)
    /// Secondary text. The first stop dark enough to carry it on `s1`.
    public static let s5 = RGB8(0x6E, 0x5E, 0x48)
    /// The specimen mount.
    public static let s6 = RGB8(0x4A, 0x3D, 0x2E)
    public static let s7 = RGB8(0x2E, 0x26, 0x19)
    /// Ink. Primary text.
    public static let s8 = RGB8(0x1C, 0x1A, 0x17)

    public static let all: [RGB8] = [s0, s1, s2, s3, s4, s5, s6, s7, s8]

    /// The single accent. Flat for actions, animated for damage — see spec §5.
    public static let stamp = RGB8(0xB0, 0x3A, 0x2B)
    /// Gems only.
    public static let gem = RGB8(0x17, 0x65, 0x74)
    /// Speed and intact semantics only.
    public static let safe = RGB8(0x41, 0x64, 0x2F)

    /// The slab sits on this. Without it a cleared slab vanishes into the page.
    public static let mount = s6
    /// The page at full dark. Not black: a notebook under a work lamp.
    public static let nightPage = RGB8(0x2A, 0x26, 0x20)
}

extension RGB8 {

    /// WCAG 2.1 relative luminance, 0 for black to 1 for white.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG 2.1 contrast ratio, 1 (identical) to 21 (black on white).
    public func contrastRatio(against other: RGB8) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
