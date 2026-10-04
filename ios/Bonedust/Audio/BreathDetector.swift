import AVFoundation
import Foundation
import Observation

/// Listens for someone blowing on the phone.
///
/// **Nothing is recorded.** Each buffer is reduced to two scalars — loudness and how noisy
/// the waveform is — inside the audio callback, and the samples are gone when it returns.
/// No audio is written to disk, kept beyond that callback, or sent anywhere; the app has no
/// network path for it to take. That is the only basis on which a game promising no
/// analytics should be asking for a microphone at all.
///
/// **Breath is told from speech by noisiness, not loudness.** Blowing is broadband noise:
/// the waveform crosses zero constantly and at no particular rate. Speech and music are
/// pitched, so they cross far less often for the same energy. A loudness threshold alone
/// would fire on a cough, a passing car, or someone talking over your shoulder — which, in
/// a game where a gust can shatter an exposed fossil, is a way to lose a specimen to a bus.
///
/// The spectral test is a zero-crossing rate rather than an FFT. Over 0.1 s of mono audio
/// it separates breath from voice well enough, costs one pass over the buffer, and keeps
/// this off the list of things that could ever cost a frame on the dig screen.
@MainActor
@Observable
final class BreathDetector {

    /// 0 when nothing is happening, rising toward 1 while someone blows.
    private(set) var strength: Float = 0
    private(set) var isListening = false
    /// Set when the microphone was refused, so the caller stops asking.
    private(set) var permissionDenied = false

    /// Fires on the main actor when a sustained breath has built up, with its strength.
    var onGust: ((Float) -> Void)?

    // MARK: Thresholds
    //
    // Tuned for a phone held at normal distance. Deliberately not in `SimTuning`: they
    // describe a microphone rather than the game, and nothing in the server's
    // re-derivation of a slab depends on them.

    /// RMS a buffer must exceed to count as breath at all.
    private let loudnessFloor: Float = 0.045
    /// RMS treated as a full-strength gust.
    private let loudnessCeiling: Float = 0.33
    /// Zero crossings per sample below which a sound is pitched, and so not breath.
    private let noisinessFloor: Float = 0.22
    /// Consecutive qualifying buffers before a gust fires. At 0.1 s each that is about a
    /// third of a second — long enough that a door slam or one consonant cannot trigger it.
    private let sustainedBuffers = 3

    private let engine = AVAudioEngine()
    private var qualifyingBuffers = 0
    private var peakStrength: Float = 0
    private var hasInstalledTap = false

    // MARK: Lifecycle

    /// Asks for the microphone and starts listening. Safe to call repeatedly.
    func start() async {
        guard !isListening, !permissionDenied else { return }
        guard await Self.requestPermission() else {
            permissionDenied = true
            return
        }
        configureSession()
        installTapIfNeeded()
        do {
            engine.prepare()
            try engine.start()
            isListening = true
        } catch {
            // Losing breath is not losing the game. Every part of this is optional, so a
            // failure makes the mechanic quietly unavailable rather than raising an error
            // the player has to dismiss mid-dig.
            isListening = false
        }
    }

    func stop() {
        guard isListening else { return }
        engine.pause()
        isListening = false
        strength = 0
        qualifyingBuffers = 0
        peakStrength = 0
    }

    /// Releases the tap and the engine. Call when leaving the dig entirely.
    func teardown() {
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        engine.stop()
        isListening = false
        strength = 0
    }

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` is the point of this line. Recording normally stops whatever the
        // player was listening to, and silencing someone's music to add a hidden mechanic
        // they did not ask for is not a trade worth making. `.defaultToSpeaker` keeps
        // playback out of the earpiece, where `.playAndRecord` otherwise sends it.
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try? session.setActive(true)
    }

    private func installTapIfNeeded() {
        guard !hasInstalledTap else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        let frames = AVAudioFrameCount(format.sampleRate / 10)   // 0.1 s
        input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
            // The buffer is reduced here, on the audio thread, and never leaves it. What
            // crosses to the main actor is two floats.
            guard let measurement = BreathDetector.measure(buffer) else { return }
            Task { @MainActor [weak self] in self?.consume(measurement) }
        }
        hasInstalledTap = true
    }

    // MARK: Measurement

    struct Measurement: Sendable {
        let loudness: Float
        let noisiness: Float
    }

    /// Reduces a buffer to two numbers and discards it. Runs on the audio thread, so it
    /// allocates nothing and touches no shared state.
    nonisolated static func measure(_ buffer: AVAudioPCMBuffer) -> Measurement? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 1 else { return nil }

        var sumSquares: Float = 0
        var crossings = 0
        var previous = channel[0]
        for i in 0..<count {
            let sample = channel[i]
            sumSquares += sample * sample
            if (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = sample
        }
        return Measurement(
            loudness: (sumSquares / Float(count)).squareRoot(),
            noisiness: Float(crossings) / Float(count)
        )
    }

    /// Folds one measurement in, and fires `onGust` once a breath has been sustained.
    ///
    /// Separated from the audio callback so it is a pure function of its input and can be
    /// tested without a microphone, which is the only way any of this gets tested at all.
    func consume(_ measurement: Measurement) {
        let isBreath = measurement.loudness >= loudnessFloor
            && measurement.noisiness >= noisinessFloor

        guard isBreath else {
            // Decays rather than snapping to zero, so the reading does not flicker while
            // someone draws breath for another go.
            strength *= 0.5
            if strength < 0.01 { strength = 0 }
            qualifyingBuffers = 0
            peakStrength = 0
            return
        }

        let span = max(0.0001, loudnessCeiling - loudnessFloor)
        let scaled = min(1, (measurement.loudness - loudnessFloor) / span)
        strength = max(strength, scaled)
        peakStrength = max(peakStrength, scaled)
        qualifyingBuffers += 1

        guard qualifyingBuffers >= sustainedBuffers else { return }
        qualifyingBuffers = 0
        let fired = peakStrength
        peakStrength = 0
        onGust?(fired)
    }
}
