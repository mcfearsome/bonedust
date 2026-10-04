import AVFoundation
import BonedustCore
import XCTest

@testable import Bonedust

/// Breath detection, without a microphone.
///
/// `consume` is split out of the audio callback precisely so this is possible: it is a pure
/// function of two scalars, and every judgement the detector makes lives in it. A tap on a
/// real input node could only be tested by blowing on the CI machine.
@MainActor
final class BreathTests: XCTestCase {

    private func detector() -> BreathDetector { BreathDetector() }

    private func breath(_ loudness: Float) -> BreathDetector.Measurement {
        // Broadband: crossing zero on a third of samples is what blowing looks like.
        BreathDetector.Measurement(loudness: loudness, noisiness: 0.34)
    }

    private func speech(_ loudness: Float) -> BreathDetector.Measurement {
        // Pitched, so far fewer crossings for the same energy.
        BreathDetector.Measurement(loudness: loudness, noisiness: 0.06)
    }

    func testSustainedBreathFiresAGust() {
        let subject = detector()
        var fired: [Float] = []
        subject.onGust = { fired.append($0) }

        for _ in 0..<3 { subject.consume(breath(0.2)) }
        XCTAssertEqual(fired.count, 1, "three qualifying buffers should be one gust")
        XCTAssertGreaterThan(fired[0], 0)
        XCTAssertLessThanOrEqual(fired[0], 1)
    }

    func testOneLoudBurstIsNotABreath() {
        let subject = detector()
        var fired = 0
        subject.onGust = { _ in fired += 1 }

        // A door slam: loud, broadband, and over immediately.
        subject.consume(breath(0.9))
        subject.consume(speech(0.01))
        subject.consume(breath(0.9))
        XCTAssertEqual(fired, 0, "a gust should need breath held, not one spike")
    }

    /// The one that matters. A gust can shatter an exposed fossil, so a conversation near
    /// the phone must not be able to cost someone a specimen.
    func testTalkingNearThePhoneNeverFires() {
        let subject = detector()
        var fired = 0
        subject.onGust = { _ in fired += 1 }

        // Speech moves with every syllable, which is the property that separates it from
        // breath once the noisiness gate alone is not enough. A flat 0.6 forever is not
        // speech, it is a tone.
        let syllables: [Float] = [0.6, 0.12, 0.45, 0.05, 0.7, 0.2, 0.55, 0.08]
        for i in 0..<40 { subject.consume(speech(syllables[i % syllables.count])) }
        XCTAssertEqual(fired, 0, "loud speech triggered a gust")
    }

    func testQuietRoomToneNeverFires() {
        let subject = detector()
        var fired = 0
        subject.onGust = { _ in fired += 1 }
        for _ in 0..<40 { subject.consume(breath(0.004)) }
        XCTAssertEqual(fired, 0, "room tone triggered a gust")
    }

    func testStrengthScalesWithHowHardYouBlow() {
        func strength(of loudness: Float) -> Float {
            let subject = detector()
            var fired: Float = 0
            subject.onGust = { fired = $0 }
            for _ in 0..<3 { subject.consume(breath(loudness)) }
            return fired
        }
        XCTAssertLessThan(strength(of: 0.08), strength(of: 0.3))
        XCTAssertEqual(strength(of: 1.0), 1, accuracy: 0.001, "clamped at full strength")
    }

    func testABreakInTheBreathResetsTheRunUp() {
        let subject = detector()
        var fired = 0
        subject.onGust = { _ in fired += 1 }
        subject.consume(breath(0.3))
        subject.consume(breath(0.3))
        subject.consume(speech(0.01))          // stopped to inhale
        subject.consume(breath(0.3))
        subject.consume(breath(0.3))
        XCTAssertEqual(fired, 0, "the count should restart after a gap")
    }

    func testMeasureReducesABufferToLoudnessAndNoisiness() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        // Alternating sign every sample: maximally noisy, amplitude 0.5.
        for i in 0..<480 { channel[i] = i % 2 == 0 ? 0.5 : -0.5 }

        let measured = try XCTUnwrap(BreathDetector.measure(buffer))
        XCTAssertEqual(measured.loudness, 0.5, accuracy: 0.001)
        XCTAssertEqual(measured.noisiness, 1, accuracy: 0.01)
    }
}
