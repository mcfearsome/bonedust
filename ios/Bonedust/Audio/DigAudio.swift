import AVFoundation
import BonedustCore
import Foundation

/// The dig's sound, synthesized at runtime. No sample files.
///
/// That is a design choice, not a shortcut (see DECISIONS.md). A brush scrape is
/// filtered noise; a looped *recording* of filtered noise audibly loops, and this
/// loop would run for sixty seconds a slab, five slabs a run. Driving a band-pass
/// filter from the brush's speed EMA instead gives a scrape that genuinely follows
/// the finger, costs no bundle size, and has no licensing question attached to a
/// paid app.
///
/// - The **scrape** is white noise through a band-pass whose centre frequency tracks
///   both brush speed and the layer being removed: topsoil is low and dull,
///   sandstone is bright and grainy.
/// - The **bed** is the same noise under a heavy low-pass at low volume — wind over
///   an open dig.
/// - **Crack**, **gem** and **bone** are short buffers built once at startup.
@MainActor
final class DigAudio {

    private let engine = AVAudioEngine()
    private let scrapeEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let scrapeMixer = AVAudioMixerNode()
    private let bedEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let bedMixer = AVAudioMixerNode()
    private let transients = AVAudioPlayerNode()

    private var scrapeSource: AVAudioSourceNode?
    private var bedSource: AVAudioSourceNode?
    private var noiseSeeds: [UnsafeMutablePointer<UInt64>] = []

    private var crackBuffer: AVAudioPCMBuffer?
    private var gemBuffer: AVAudioPCMBuffer?
    private var boneBuffer: AVAudioPCMBuffer?

    private var isRunning = false
    private let sampleRate: Double = 44_100

    /// Smoothed on the main thread, once per frame. Per-sample smoothing would need
    /// shared state across the audio thread; at 60 Hz this is enough to avoid the
    /// zipper noise that stepping a filter frequency outright would cause.
    private var currentGain: Float = 0
    private var targetGain: Float = 0
    private var currentFrequency: Float = 1_200
    private var targetFrequency: Float = 1_200

    var isEnabled = true {
        didSet {
            if !isEnabled { stopScrape() }
            engine.mainMixerNode.outputVolume = isEnabled ? 1 : 0
        }
    }

    // MARK: Lifecycle

    func prepare() {
        guard !isRunning else { return }
        configureSession()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return }

        let scrape = makeNoiseSource(format: format)
        let bed = makeNoiseSource(format: format)
        scrapeSource = scrape
        bedSource = bed

        engine.attach(scrape)
        engine.attach(bed)
        engine.attach(scrapeEQ)
        engine.attach(scrapeMixer)
        engine.attach(bedEQ)
        engine.attach(bedMixer)
        engine.attach(transients)

        configureScrapeFilter()
        configureBedFilter()

        engine.connect(scrape, to: scrapeEQ, format: format)
        engine.connect(scrapeEQ, to: scrapeMixer, format: format)
        engine.connect(scrapeMixer, to: engine.mainMixerNode, format: format)

        engine.connect(bed, to: bedEQ, format: format)
        engine.connect(bedEQ, to: bedMixer, format: format)
        engine.connect(bedMixer, to: engine.mainMixerNode, format: format)

        engine.connect(transients, to: engine.mainMixerNode, format: format)

        scrapeMixer.outputVolume = 0
        bedMixer.outputVolume = 0.035

        crackBuffer = makeCrackBuffer(format: format)
        gemBuffer = makeGemBuffer(format: format)
        boneBuffer = makeBoneBuffer(format: format)

        do {
            engine.prepare()
            try engine.start()
            transients.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func teardown() {
        transients.stop()
        engine.stop()
        isRunning = false
        for seed in noiseSeeds { seed.deallocate() }
        noiseSeeds.removeAll()
    }

    private func configureSession() {
        // Ambient and mixable: a premium single-player game has no business
        // interrupting the player's podcast.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func configureScrapeFilter() {
        let band = scrapeEQ.bands[0]
        band.filterType = .bandPass
        band.frequency = currentFrequency
        band.bandwidth = 2.2
        band.bypass = false
        scrapeEQ.globalGain = 6
    }

    private func configureBedFilter() {
        let band = bedEQ.bands[0]
        band.filterType = .lowPass
        band.frequency = 320
        band.bypass = false
    }

    // MARK: Noise source

    /// White noise at unit amplitude. The only state is one 64-bit seed on the heap,
    /// touched exclusively by the audio thread, so there is nothing to synchronise.
    private func makeNoiseSource(format: AVAudioFormat) -> AVAudioSourceNode {
        let seed = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        seed.initialize(to: 0x9E37_79B9_7F4A_7C15 ^ UInt64(noiseSeeds.count + 1) &* 0x2545_F491)
        noiseSeeds.append(seed)

        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // xorshift64*, inlined: cheap, and the audio thread must not allocate.
                var state = seed.pointee
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                seed.pointee = state
                let sample = Float(Int32(truncatingIfNeeded: state &* 0x2545_F491_4F6C_DD1D))
                    / Float(Int32.max)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
    }

    // MARK: Scrape control

    func startScrape() {
        guard isEnabled, isRunning else { return }
        targetGain = 0.2
    }

    func stopScrape() {
        targetGain = 0
    }

    /// Called once per frame with the current brush state.
    ///
    /// `layer` is the depth being removed, which sets the base timbre. Speed scales
    /// it, so a fast sweep is both louder and brighter — the two cues a player reads
    /// as "you are going quickly" before they ever look at the meter.
    func update(speed: Float, safeSpeed: Float, layer: UInt8?, isBrushing: Bool, working: Bool) {
        guard isEnabled, isRunning else { return }

        let ratio = safeSpeed > 0 ? min(speed / safeSpeed, 2.2) : 0
        targetGain = isBrushing && working ? 0.08 + ratio * 0.17 : 0

        let base: Float
        switch layer {
        case 3: base = 900       // topsoil: low, loose, dull
        case 2: base = 1_400     // clay: packed
        case 1: base = 2_600     // sandstone: bright and grainy
        default: base = 3_400    // matrix and bone: a hard, fine hiss
        }
        targetFrequency = base * (0.75 + ratio * 0.45)

        // One-pole smoothing per frame. Fast enough to feel immediate, slow enough
        // that stepping the filter does not click.
        currentGain += (targetGain - currentGain) * 0.35
        currentFrequency += (targetFrequency - currentFrequency) * 0.25

        scrapeMixer.outputVolume = max(0, min(1, currentGain))
        scrapeEQ.bands[0].frequency = max(60, min(Float(sampleRate / 2.2), currentFrequency))
        scrapeEQ.bands[0].bandwidth = 1.6 + ratio * 1.1
    }

    // MARK: Transients

    func playCrack() { play(crackBuffer) }
    func playGem() { play(gemBuffer) }
    func playBoneRevealed() { play(boneBuffer) }

    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard isEnabled, isRunning, let buffer, transients.engine != nil else { return }
        transients.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !transients.isPlaying { transients.play() }
    }

    // MARK: Buffer synthesis

    private func makeBuffer(
        format: AVAudioFormat, seconds: Double, _ fill: (Int, Double, UnsafeMutablePointer<Float>) -> Void
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        fill(Int(frames), sampleRate, channel)
        return buffer
    }

    /// A dry snap: noise burst with an instant attack and a fast decay, plus a low
    /// thump underneath so it carries on a phone speaker.
    private func makeCrackBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        makeBuffer(format: format, seconds: 0.16) { frames, rate, channel in
            var state: UInt64 = 0xDEAD_BEEF_CAFE_F00D
            var lowPass: Float = 0
            for frame in 0..<frames {
                let t = Double(frame) / rate
                state ^= state >> 12; state ^= state << 25; state ^= state >> 27
                let noise = Float(Int32(truncatingIfNeeded: state &* 0x2545_F491_4F6C_DD1D))
                    / Float(Int32.max)
                // Resonant-ish body from a one-pole on the noise.
                lowPass += (noise - lowPass) * 0.45
                let envelope = Float(exp(-t * 46))
                let thump = Float(sin(2 * .pi * 118 * t)) * Float(exp(-t * 28)) * 0.5
                channel[frame] = (lowPass * 1.4 + thump) * envelope * 0.85
            }
        }
    }

    /// Two partials a fifth apart, long decay. Reads as glass rather than a bell.
    private func makeGemBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        makeBuffer(format: format, seconds: 0.55) { frames, rate, channel in
            for frame in 0..<frames {
                let t = Double(frame) / rate
                let attack = Float(min(1, t * 400))
                let first = Float(sin(2 * .pi * 2_093 * t)) * Float(exp(-t * 7.5))
                let second = Float(sin(2 * .pi * 3_136 * t)) * Float(exp(-t * 11)) * 0.55
                channel[frame] = (first + second) * attack * 0.22
            }
        }
    }

    /// Bone appearing: a soft, short knock. Quiet enough to happen often.
    private func makeBoneBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        makeBuffer(format: format, seconds: 0.12) { frames, rate, channel in
            for frame in 0..<frames {
                let t = Double(frame) / rate
                let envelope = Float(exp(-t * 34))
                channel[frame] = Float(sin(2 * .pi * 420 * t)) * envelope * 0.16
            }
        }
    }
}
