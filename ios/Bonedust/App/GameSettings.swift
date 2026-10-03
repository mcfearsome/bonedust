import BonedustCore
import Foundation
import SwiftUI

/// Player settings from §7. Persisted in UserDefaults — these are preferences, not
/// save data, so they do not belong in SwiftData with the run.
@Observable
final class GameSettings {

    enum Key: String {
        case haptics = "settings.haptics"
        case sound = "settings.sound"
        case reducedMotion = "settings.reducedMotion"
        case leftHandedTray = "settings.leftHandedTray"
        case gentleMode = "settings.gentleMode"
    }

    var hapticsEnabled: Bool { didSet { store(.haptics, hapticsEnabled) } }
    var soundEnabled: Bool { didSet { store(.sound, soundEnabled) } }
    /// Player's own override. The system setting is honoured separately and either
    /// one being on suppresses shake and particle bursts.
    var reducedMotion: Bool { didSet { store(.reducedMotion, reducedMotion) } }
    var leftHandedTray: Bool { didSet { store(.leftHandedTray, leftHandedTray) } }

    /// §7: crack chance x0.5, payouts x0.8, no leaderboards. Payments still count
    /// toward the crew debt in full — see docs/CREW_LEDGER.md.
    var gentleMode: Bool { didSet { store(.gentleMode, gentleMode) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Haptics and sound default on: §3 calls the feel non-negotiable, and a
        // player who wants silence will find the switch.
        self.hapticsEnabled = defaults.object(forKey: Key.haptics.rawValue) as? Bool ?? true
        self.soundEnabled = defaults.object(forKey: Key.sound.rawValue) as? Bool ?? true
        self.reducedMotion = defaults.bool(forKey: Key.reducedMotion.rawValue)
        self.leftHandedTray = defaults.bool(forKey: Key.leftHandedTray.rawValue)
        self.gentleMode = defaults.bool(forKey: Key.gentleMode.rawValue)
    }

    private func store(_ key: Key, _ value: Bool) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Gentle mode's contribution to the composed modifiers.
    var gentleModeModifiers: ModifierSet {
        var set = ModifierSet()
        guard gentleMode else { return set }
        set.crackMultiplier = 0.5
        set.payoutMultiplier = 0.8
        return set
    }
}
