import BonedustCore
import SpriteKit
import UIKit

/// The slab, on screen and under the finger.
///
/// Rendering is a single `SKSpriteNode` showing a 96x128 `SKMutableTexture` with
/// nearest-neighbour filtering, which is what gives §3's chunky, tactile pixel look.
/// Scaling a tiny texture up is also why this holds 60 fps trivially: the GPU draws
/// one quad, and the only per-frame CPU work is recolouring the dirty rectangle.
///
/// Touch handling lives here rather than in SwiftUI because `UIEvent`'s coalesced
/// touches carry every sample the digitiser captured between frames, along with real
/// timestamps. A SwiftUI `DragGesture` hands over one position per frame with no
/// timing, which would make the speed EMA — and therefore cracking — a function of
/// the frame rate.
final class DigScene: SKScene {

    weak var engine: DigEngine?
    var haptics: HapticEngine?
    var audio: DigAudio?
    /// Suppresses particle bursts, per §7.
    var reducedMotion = false
    /// Cosmetic brush trail (§5). The default tints dust by the layer coming off, per §3;
    /// any earned trail overrides that with its own colour, which is the whole point of
    /// having chosen it.
    var trail: BrushTrail = .natural
    /// Fires on every crack. The view shows §9's one diegetic hint only the first time,
    /// but a VoiceOver announcement has to happen every time, because it is the only
    /// channel a player who cannot see the meter has.
    var onCrack: (() -> Void)?
    /// Debug only: paints orientation markers into the slab. See
    /// `SlabRenderer.orientationProbe` for why this is a thing you look at rather than
    /// something a test can settle.
    var orientationProbe = false

    private var renderer = SlabRenderer()
    private var slabNode: SKSpriteNode?
    private var slabTexture: SKMutableTexture?
    private var dust: SKEmitterNode?
    private var lastUpdateTime: TimeInterval = 0
    private var lastTouchTimestamp: TimeInterval?
    private var hasReportedCrack = false
    private var pendingFullRedraw = true

    // MARK: Setup

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        scaleMode = .resizeFill
        backgroundColor = SKColor(red: 0x22 / 255, green: 0x18 / 255, blue: 0x13 / 255, alpha: 1)
        view.isMultipleTouchEnabled = false
        configureRenderer()
        buildSlab()
    }

    func configureRenderer() {
        guard let engine else { return }
        renderer.palette = engine.site.palette
        renderer.tuning = engine.sim.tuning
        renderer.lightLevel = engine.site.modifiers.lightLevel
        renderer.orientationProbe = orientationProbe
        pendingFullRedraw = true
    }

    private func buildSlab() {
        slabNode?.removeFromParent()
        let texture = SKMutableTexture(
            size: CGSize(width: SlabGrid.width, height: SlabGrid.height)
        )
        texture.filteringMode = .nearest
        let node = SKSpriteNode(texture: texture)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        node.size = size
        node.zPosition = 0
        addChild(node)
        slabNode = node
        slabTexture = texture
        pendingFullRedraw = true
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        slabNode?.size = size
        slabNode?.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    // MARK: Frame

    override func update(_ currentTime: TimeInterval) {
        let delta = lastUpdateTime == 0 ? 1.0 / 60 : min(0.25, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        guard let engine else { return }

        engine.tick(delta: delta)
        engine.publish()

        // Gems shimmer, so their cells are repainted every frame regardless of whether the
        // brush touched them. At most four clusters of nine cells, which is nothing against
        // the 48 KB that goes up anyway.
        renderer.sparkleTime += Float(delta)
        for origin in engine.layout.gemClusters {
            let x = origin % SlabGrid.width
            let y = origin / SlabGrid.width
            let side = engine.sim.tuning.gemSize
            engine.markDirty(
                x0: x, y0: y, x1: x + side - 1, y1: y + side - 1
            )
        }
        // X-ray goggles. Flipping this forces a full redraw on the frame it changes,
        // which is why it is checked before the upload rather than inside it.
        if renderer.revealBuriedBone != engine.isRevealing {
            renderer.revealBuriedBone = engine.isRevealing
            pendingFullRedraw = true
        }
        uploadSlab(engine)
        updateContinuousFeedback(engine)
    }

    private func uploadSlab(_ engine: DigEngine) {
        guard let texture = slabTexture else { return }
        if pendingFullRedraw {
            renderer.redrawEverything(engine.grid)
            _ = engine.consumeDirtyRegion()
            pendingFullRedraw = false
        } else {
            let dirty = engine.consumeDirtyRegion()
            guard !dirty.isEmpty else { return }
            renderer.redraw(engine.grid, region: dirty)
        }

        // The whole 48 KB goes up each time anything changed. Copying it costs a few
        // microseconds and means we never have to assume SKMutableTexture preserved
        // our previous contents between calls.
        //
        // Rows go up reversed, because SpriteKit reads the first row as the bottom of the
        // texture. Uploading them in order drew the slab mirrored, which put every brush
        // stroke at the vertically reflected spot and made dragging down dig upwards --
        // invisible in the renderer's own PNGs, because those are written top row first and
        // a procedural fossil looks plausible either way up.
        let renderer = self.renderer
        texture.modifyPixelData { pointer, length in
            guard let pointer else { return }
            renderer.copyRowsBottomUp(into: pointer, length: length)
        }
    }

    private func updateContinuousFeedback(_ engine: DigEngine) {
        let brushing = engine.isBrushing && !engine.isFinished
        haptics?.updateTexture(
            speed: engine.speed,
            safeSpeed: engine.safeSpeed,
            overBone: lastBrushWasOverBone
        )
        audio?.update(
            speed: engine.speed,
            safeSpeed: engine.safeSpeed,
            layer: lastRemovedLayer,
            isBrushing: brushing,
            working: lastStrokeDidWork
        )
        if !brushing {
            dust?.particleBirthRate = 0
        }
    }

    // MARK: Touch

    private var lastBrushWasOverBone = false
    private var lastRemovedLayer: UInt8?
    private var lastStrokeDidWork = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine, !engine.isFinished, let touch = touches.first,
              let point = gridPoint(for: touch)
        else { return }
        lastTouchTimestamp = touch.timestamp
        engine.noteContact(radius: Float(touch.majorRadius))
        haptics?.startTexture()
        audio?.startScrape()
        apply(engine.brushBegan(at: point), at: point, engine: engine)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine, !engine.isFinished, let touch = touches.first else { return }
        // Every digitiser sample between frames, not just the latest one. On a fast
        // sweep this is the difference between a continuous trench and a dotted line.
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            guard let point = gridPoint(for: sample) else { continue }
            // Every coalesced sample, so laying a finger flat mid-stroke widens the brush
            // immediately rather than at the next touch-down.
            engine.noteContact(radius: Float(sample.majorRadius))
            let previous = lastTouchTimestamp ?? sample.timestamp
            let deltaMillis = Float(max(0.001, sample.timestamp - previous) * 1_000)
            lastTouchTimestamp = sample.timestamp
            apply(
                engine.brushMoved(to: point, deltaMillis: deltaMillis),
                at: point,
                engine: engine
            )
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endStroke()
    }

    private func endStroke() {
        engine?.brushEnded()
        lastTouchTimestamp = nil
        lastStrokeDidWork = false
        lastRemovedLayer = nil
        haptics?.stopTexture()
        audio?.stopScrape()
        dust?.particleBirthRate = 0
    }

    /// Converts a touch into grid coordinates. Deliberately unclamped: brushing past
    /// the edge should still erode the edge cells, and the simulation bounds-checks
    /// every cell it touches anyway.
    private func gridPoint(for touch: UITouch) -> Vec2? {
        guard let node = slabNode, node.size.width > 0, node.size.height > 0 else { return nil }
        let local = touch.location(in: node)
        let u = local.x / node.size.width + 0.5
        // SpriteKit's y runs up the screen; the grid's runs down it.
        let v = 0.5 - local.y / node.size.height
        return Vec2(Float(u) * Float(SlabGrid.width), Float(v) * Float(SlabGrid.height))
    }

    // MARK: Feedback routing

    private func apply(_ result: StrokeResult, at point: Vec2, engine: DigEngine) {
        lastStrokeDidWork = result.didAnything
        lastRemovedLayer = result.dominantLayer ?? lastRemovedLayer
        lastBrushWasOverBone = engine.isOverBone(point)

        if result.cracksStarted > 0 {
            haptics?.crack()
            audio?.playCrack()
            hasReportedCrack = true
            onCrack?()
            if let cell = result.firstCrackCell { emitCrackBurst(at: cell) }
        }
        if result.gemsCompleted > 0 { emitGemSparkle(at: point) }
        if result.gemsCompleted > 0 {
            haptics?.gemFreed()
            audio?.playGem()
        }
        if result.boneRevealed > 0 {
            // Only on a meaningful reveal, or this fires on every frame of a sweep
            // across the fossil and turns into a buzz.
            if result.boneRevealed > 6 {
                haptics?.boneRevealed()
                audio?.playBoneRevealed()
            }
        }
        emitDust(result, at: point)
    }

    private func emitDust(_ result: StrokeResult, at point: Vec2) {
        guard !reducedMotion, let node = slabNode else { return }
        guard result.layersRemoved > 0, let layer = result.dominantLayer else {
            dust?.particleBirthRate = 0
            return
        }
        let emitter = dust ?? makeDust()
        if emitter.parent == nil { node.addChild(emitter) }
        emitter.position = CGPoint(
            x: (CGFloat(point.x) / CGFloat(SlabGrid.width) - 0.5) * node.size.width,
            y: (0.5 - CGFloat(point.y) / CGFloat(SlabGrid.height)) * node.size.height
        )
        let tint = trail.id == BrushTrail.natural.id
            ? renderer.dustColour(forLayer: layer)
            : trail.colour
        emitter.particleColor = SKColor(
            red: CGFloat(tint.r) / 255,
            green: CGFloat(tint.g) / 255,
            blue: CGFloat(tint.b) / 255,
            alpha: 1
        )
        // Birth rate follows how much material actually came off, so a stroke over
        // bare matrix throws dust and a stroke over bone barely does.
        emitter.particleBirthRate = min(260, CGFloat(result.layersRemoved) * 9)
    }

    /// A short, sharp burst where bone broke.
    ///
    /// Separate from the dust emitter rather than a louder version of it: dust follows the
    /// finger continuously, and a crack is an event somewhere specific. Reusing one emitter
    /// would mean the burst drags along behind the brush.
    private func emitCrackBurst(at cellIndex: Int) {
        guard !reducedMotion, let node = slabNode else { return }
        let x = cellIndex % SlabGrid.width
        let y = cellIndex / SlabGrid.width
        let burst = SKEmitterNode()
        burst.particleTexture = DigScene.dustTexture
        burst.particleBirthRate = 900
        burst.numParticlesToEmit = 14
        burst.particleLifetime = 0.34
        burst.particleSpeed = 72
        burst.particleSpeedRange = 40
        burst.emissionAngleRange = .pi * 2
        burst.particleAlpha = 0.85
        burst.particleAlphaSpeed = -2.6
        burst.particleScale = 0.07
        burst.particleScaleSpeed = -0.12
        burst.particleColorBlendFactor = 1
        let tint = renderer.palette.crackedBone
        burst.particleColor = SKColor(
            red: CGFloat(tint.r) / 255, green: CGFloat(tint.g) / 255,
            blue: CGFloat(tint.b) / 255, alpha: 1
        )
        burst.position = CGPoint(
            x: (CGFloat(x) / CGFloat(SlabGrid.width) - 0.5) * node.size.width,
            y: (0.5 - CGFloat(y) / CGFloat(SlabGrid.height)) * node.size.height
        )
        burst.zPosition = 2
        burst.targetNode = self
        node.addChild(burst)
        burst.run(.sequence([.wait(forDuration: 0.9), .removeFromParent()]))
    }

    /// A gem coming free. Teal, and the only place that colour is ever used (§7).
    private func emitGemSparkle(at point: Vec2) {
        guard !reducedMotion, let node = slabNode else { return }
        let sparkle = SKEmitterNode()
        sparkle.particleTexture = DigScene.dustTexture
        sparkle.particleBirthRate = 600
        sparkle.numParticlesToEmit = 20
        sparkle.particleLifetime = 0.6
        sparkle.particleSpeed = 46
        sparkle.particleSpeedRange = 30
        sparkle.emissionAngleRange = .pi * 2
        sparkle.particleAlpha = 0.95
        sparkle.particleAlphaSpeed = -1.5
        sparkle.particleScale = 0.055
        sparkle.particleScaleSpeed = -0.05
        sparkle.particleColorBlendFactor = 1
        let tint = renderer.palette.gem
        sparkle.particleColor = SKColor(
            red: CGFloat(tint.r) / 255, green: CGFloat(tint.g) / 255,
            blue: CGFloat(tint.b) / 255, alpha: 1
        )
        sparkle.position = CGPoint(
            x: (CGFloat(point.x) / CGFloat(SlabGrid.width) - 0.5) * node.size.width,
            y: (0.5 - CGFloat(point.y) / CGFloat(SlabGrid.height)) * node.size.height
        )
        sparkle.zPosition = 2
        sparkle.targetNode = self
        node.addChild(sparkle)
        sparkle.run(.sequence([.wait(forDuration: 1.2), .removeFromParent()]))
    }

    private func makeDust() -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = DigScene.dustTexture
        emitter.particleBirthRate = 0
        emitter.particleLifetime = CGFloat(trail.lifetime)
        emitter.particleLifetimeRange = 0.25
        emitter.particleSpeed = 46
        emitter.particleSpeedRange = 34
        emitter.emissionAngle = 0
        emitter.emissionAngleRange = .pi * 2
        emitter.particleAlpha = 0.55
        emitter.particleAlphaRange = 0.2
        emitter.particleAlphaSpeed = -1.4
        emitter.particleScale = CGFloat(trail.scale)
        emitter.particleScaleRange = 0.05
        emitter.particleScaleSpeed = -0.1
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .alpha
        emitter.zPosition = 1
        emitter.targetNode = self
        dust = emitter
        return emitter
    }

    /// A soft 8x8 dot, built once. Shipping an asset for this would be silly.
    private static let dustTexture: SKTexture = {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }()
}
