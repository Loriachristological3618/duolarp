import AppKit

final class Controller: NSObject {
    private enum Phase { case idle, arming, holding, settling }

    private let sampler: HingeSampler
    private let overlay: Overlay
    var geometry: LaptopGeometry
    private var phase = Phase.idle
    private var link: CADisplayLink?

    private var restAngle: Double
    private var predictor = HingePredictor()
    private var history: [HingeSample] = []
    private var lidAngle = 0.0
    private var virtualAngle = 0.0
    private var settleFrom = 0.0
    private var settleStart = 0.0
    private var settleDuration = 0.5
    private var anchorAngle = 0.0
    private var lastMove = 0.0
    private var armedAt = 0.0
    var look = Look()

    private let wakeThreshold = 0.5
    private let moveThreshold = 0.45
    private let stillDelay = 0.125
    private let minimumLidAngle = 25.0

    var onFailure: (() -> Void)?

    var enabled = true {
        didSet { if !enabled { finish() } }
    }

    init(sampler: HingeSampler, overlay: Overlay, geometry: LaptopGeometry) {
        self.sampler = sampler
        self.overlay = overlay
        self.geometry = geometry
        restAngle = sampler.latest?.angle ?? 110
        super.init()
        let link = overlay.screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
        sampler.onSample = { [weak self] in self?.sample($0) }
        overlay.onCaptureError = { [weak self] in self?.fail("capture error") }
    }

    func invalidate() {
        onFailure = nil
        sampler.precise = false
        sampler.onSample = nil
        link?.invalidate()
        link = nil
        phase = .idle
        overlay.close()
    }

    private func fail(_ reason: String) {
        lifecycle("controller failed: \(reason)")
        finish()
        onFailure?()
    }

    private var presentationTime: Double {
        guard let link, !link.isPaused else { return CACurrentMediaTime() }
        return link.targetTimestamp + (link.targetTimestamp - link.timestamp)
    }

    private func sample(_ s: HingeSample) {
        history.append(s)
        if history.count > 4 { history.removeFirst() }
        if phase == .idle {
            guard enabled else { return }
            if abs(s.angle - restAngle) > wakeThreshold, s.angle > minimumLidAngle {
                arm(s)
            } else {
                restAngle += (s.angle - restAngle) * 0.2
            }
            return
        }
        predictor.add(s, target: presentationTime)
        if abs(s.angle - anchorAngle) > moveThreshold {
            anchorAngle = s.angle
            lastMove = s.time
            if phase == .settling {
                phase = .holding
            }
        }
    }

    private func arm(_ s: HingeSample) {
        phase = .arming
        armedAt = CACurrentMediaTime()
        sampler.precise = true
        predictor.reset(with: history)
        lidAngle = s.angle
        anchorAngle = s.angle
        lastMove = s.time
        link?.isPaused = false
        log(String(format: "arm at %.2f° (rest %.2f°)", s.angle, restAngle))
        overlay.startCapture { [weak self] in self?.firstFrame() }
        overlay.warmUp()
    }

    private func firstFrame() {
        guard phase == .arming else { return }
        lidAngle = predictor.angle(at: presentationTime, now: CACurrentMediaTime())
        virtualAngle = lidAngle
        phase = .holding
        draw()
        overlay.show()
        log(String(format: "first frame after %.0f ms, frozen at %.2f°", (CACurrentMediaTime() - armedAt) * 1000, lidAngle))
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        lidAngle = predictor.angle(at: presentationTime, now: now)
        if lidAngle < minimumLidAngle { finish(); return }

        switch phase {
        case .idle:
            return
        case .arming:
            if now - armedAt > 1.5 { fail("no capture frame within 1.5 s") }
            return
        case .holding:
            if now - lastMove >= stillDelay {
                phase = .settling
                settleFrom = virtualAngle
                settleStart = now
                settleDuration = Settle.duration(for: lidAngle - virtualAngle)
                log(String(format: "still at %.2f°; travelling from %.2f°", lidAngle, virtualAngle))
            }
        case .settling:
            let p = (presentationTime - settleStart) / settleDuration
            if p >= 1 {
                finish()
                return
            }
            virtualAngle = settleFrom + (lidAngle - settleFrom) * Settle.ease(p)
        }

        draw()
    }

    private func draw() {
        overlay.draw(Projection.homography(geometry, pointSize: overlay.pointSize,
                                           virtualAngle: virtualAngle, lidAngle: lidAngle),
                     depth: Projection.rayDepth(geometry, virtualAngle: virtualAngle, lidAngle: lidAngle),
                     geometry: geometry, look: look)
    }

    private func finish() {
        guard phase != .idle else { return }
        overlay.hide()
        overlay.endCapture()
        link?.isPaused = true
        sampler.precise = false
        restAngle = sampler.latest?.angle ?? lidAngle
        phase = .idle
        log(String(format: "idle at %.2f°", restAngle))
    }
}
