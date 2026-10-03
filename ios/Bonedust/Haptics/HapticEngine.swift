import CoreHaptics
import Foundation
import UIKit

/// The brush's sense of touch. §3 calls this non-negotiable, and it is the single
/// biggest contributor to the slab feeling like rock rather than a progress bar.
///
/// Three distinct sensations, deliberately not variations of one:
/// - a **continuous texture** under the finger whose intensity tracks brush speed,
/// - a **sharp transient** on a crack, so the player feels the mistake before they
///   read the meter,
/// - a soft two-tap **clink** when a gem comes free.
///
/// Everything here fails soft. A device without haptics, a player with them off, or
/// an engine the system reset mid-dig all end up silently doing nothing rather than
/// taking the dig down with them.
@MainActor
final class HapticEngine {

    private var engine: CHHapticEngine?
    private var texturePlayer: CHHapticAdvancedPatternPlayer?
    private var textureIsPlaying = false
    private var engineIsRunning = false

    var isEnabled = true {
        didSet { if !isEnabled { stopTexture() } }
    }

    private var isSupported: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: Lifecycle

    func prepare() {
        guard isSupported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            // A dig is a long session of near-continuous haptics; letting the engine
            // shut itself down between strokes would add start-up latency to the
            // first contact of every stroke, which reads as the brush not working.
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.engineIsRunning = false
                    self?.textureIsPlaying = false
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.engineIsRunning = false
                    self?.textureIsPlaying = false
                    self?.texturePlayer = nil
                    self?.start()
                }
            }
            self.engine = engine
            start()
        } catch {
            engine = nil
        }
    }

    private func start() {
        guard let engine, !engineIsRunning else { return }
        do {
            try engine.start()
            engineIsRunning = true
        } catch {
            engineIsRunning = false
        }
    }

    func teardown() {
        stopTexture()
        engine?.stop()
        engineIsRunning = false
        engine = nil
        texturePlayer = nil
    }

    // MARK: Continuous brushing texture

    func startTexture() {
        guard isEnabled, isSupported else { return }
        start()
        guard engineIsRunning, !textureIsPlaying else { return }
        do {
            let player = try texturePlayer ?? makeTexturePlayer()
            texturePlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            textureIsPlaying = true
        } catch {
            textureIsPlaying = false
        }
    }

    /// `speed` is the simulation's EMA in cells per frame; `safeSpeed` is the current
    /// tool's threshold. Mapping intensity to the *ratio* rather than the raw speed
    /// means the fine brush and the air blower both feel like they are working hard
    /// at the point where they are about to start breaking bone.
    func updateTexture(speed: Float, safeSpeed: Float, overBone: Bool) {
        guard isEnabled, textureIsPlaying, let player = texturePlayer else { return }
        let ratio = safeSpeed > 0 ? speed / safeSpeed : speed
        let intensity = min(1, 0.12 + min(ratio, 1.6) * 0.45)
        // Sharpness is the grain. Bone is a harder, brighter scrape than soil.
        let sharpness = min(1, (overBone ? 0.55 : 0.2) + min(ratio, 1.5) * 0.25)
        do {
            try player.sendParameters([
                CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0
                ),
                CHHapticDynamicParameter(
                    parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0
                ),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            // A failed parameter send is not worth interrupting the dig over.
        }
    }

    func stopTexture() {
        guard textureIsPlaying, let player = texturePlayer else { return }
        try? player.stop(atTime: CHHapticTimeImmediate)
        textureIsPlaying = false
    }

    private func makeTexturePlayer() throws -> CHHapticAdvancedPatternPlayer {
        guard let engine else { throw HapticFailure.noEngine }
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0,
            // Long enough that a stroke never outlives it; the player is stopped on
            // touch-up, and looping handles anything longer.
            duration: 60
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        return player
    }

    // MARK: Transients

    /// A crack. Sharp and unmistakable — §3 requires the player to understand *why*
    /// within a second, and feeling it is faster than reading it.
    func crack() {
        playTransient(intensity: 1.0, sharpness: 0.95)
        // A second, softer tap a beat later reads as the fracture running.
        playTransient(intensity: 0.45, sharpness: 0.7, delay: 0.055)
    }

    /// A gem coming free: soft, bright, two taps.
    func gemFreed() {
        playTransient(intensity: 0.5, sharpness: 0.2)
        playTransient(intensity: 0.75, sharpness: 0.85, delay: 0.09)
    }

    /// Bone first appearing from under the matrix.
    func boneRevealed() {
        playTransient(intensity: 0.3, sharpness: 0.45)
    }

    private func playTransient(intensity: Float, sharpness: Float, delay: TimeInterval = 0) {
        guard isEnabled, isSupported else { return }
        start()
        guard engineIsRunning, let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: delay
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Fall back to nothing rather than to a wrong sensation.
        }
    }

    private enum HapticFailure: Error { case noEngine }
}
