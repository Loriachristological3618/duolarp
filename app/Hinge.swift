import Foundation
import QuartzCore

struct HingeSample {
    var time: Double
    var angle: Double
}

final class HingeSampler {
    let source: AngleSource
    private let lock = NSLock()
    private var _latest: HingeSample?
    private var _precise = false
    private var running = false

    var onSample: ((HingeSample) -> Void)?

    var latest: HingeSample? { lock.lock(); defer { lock.unlock() }; return _latest }

    var precise: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _precise }
        set { lock.lock(); _precise = newValue; lock.unlock() }
    }

    init(source: AngleSource) { self.source = source }

    func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.name = "duolarp.hinge"
        t.start()
    }

    func stop() { running = false }

    private static func sleep(until t: Double) {
        let now = CACurrentMediaTime()
        if t > now { Thread.sleep(forTimeInterval: t - now) }
    }

    private func loop() {
        var period = 0.1009
        var lastValue: Double?
        var lastRead = 0.0
        var lastLocked: Double?
        var expected: Double?
        var probing = false
        var probeDue = 0.0
        var probeGiveUp = 0.0
        var probeEvery = 2.0

        func locked(_ t: Double) {
            if let prev = lastLocked {
                let dt = t - prev
                let n = (dt / period).rounded()
                if dt > 0.005, dt < 0.75 * period {
                    period = dt
                } else if n >= 1, n <= 20, abs(dt - n * period) < 0.01 {
                    period += (dt / n - period) * 0.1
                }
            }
            lastLocked = t
            expected = t + period
        }

        while running {
            if let next = expected, CACurrentMediaTime() - next > 0.5 { expected = nil }
            let precise = self.precise
            let now0 = CACurrentMediaTime()
            if !precise, !probing, now0 >= probeDue {
                probing = true
                probeDue = now0 + probeEvery
                probeGiveUp = now0 + 1.3 * period
            }

            if !precise, !probing {
                if let next = expected {
                    Self.sleep(until: next + 0.002)
                } else {
                    Thread.sleep(forTimeInterval: period)
                }
                guard let v = source.read() else { expected = nil; Thread.sleep(forTimeInterval: 0.1); continue }
                let t = CACurrentMediaTime()
                if v != lastValue {
                    lastValue = v
                    publish(HingeSample(time: expected.map { $0 + 0.001 } ?? t, angle: v))
                }
                if let next = expected { expected = next + period }
                lastRead = t
                continue
            }

            if probing, CACurrentMediaTime() > probeGiveUp, expected == nil {
                probing = false
                probeEvery = min(probeEvery * 2, 60)
                probeDue = CACurrentMediaTime() + probeEvery
                continue
            }
            if let next = expected { Self.sleep(until: next - 0.0015) }
            let afterSleep = CACurrentMediaTime() - lastRead > 0.003
            guard let value = source.read() else {
                expected = nil
                probing = false
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            let now = CACurrentMediaTime()
            defer { lastRead = now }

            guard let previous = lastValue else {
                lastValue = value
                publish(HingeSample(time: now, angle: value))
                continue
            }

            if value != previous {
                lastValue = value
                if afterSleep {
                    expected = now + period - 0.004
                    lastLocked = nil
                    if probing { probeDue = 0 }
                    publish(HingeSample(time: now - 0.001, angle: value))
                } else {
                    let t = (lastRead + now) / 2
                    locked(t)
                    probeEvery = 2
                    publish(HingeSample(time: t, angle: value))
                }
                probing = false
            } else if let next = expected, now > next + (precise ? 0.015 : 0.006) {
                expected = next + period
                probing = false
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    private func publish(_ sample: HingeSample) {
        lock.lock(); _latest = sample; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }
}

struct HingePredictor {
    var horizonCap = 0.08
    var brakeRatio = 0.8
    var stillStep = 0.5
    var blendTime = 0.04

    private var samples: [HingeSample] = []
    private var offset = 0.0
    private var lastEvaluation: Double?

    mutating func reset(_ s: HingeSample) {
        reset(with: [s])
    }

    mutating func reset(with history: [HingeSample]) {
        samples = Array(history.suffix(4))
        offset = 0
        lastEvaluation = nil
    }

    mutating func add(_ s: HingeSample, target: Double) {
        let before = samples.isEmpty ? nil : curve(at: target)
        samples.append(s)
        if samples.count > 4 { samples.removeFirst() }
        if let before { offset += before - curve(at: target) }
    }

    mutating func angle(at target: Double, now: Double) -> Double {
        if let last = lastEvaluation { offset *= exp(-(now - last) / blendTime) }
        lastEvaluation = now
        return curve(at: target) + offset
    }

    private func curve(at t: Double) -> Double {
        guard let newest = samples.last else { return 0 }
        guard samples.count >= 3 else { return newest.angle }
        let a = samples[samples.count - 3], b = samples[samples.count - 2], c = newest
        if abs(c.angle - b.angle) < stillStep, abs(b.angle - a.angle) < stillStep {
            return samples.reduce(0) { $0 + $1.angle } / Double(samples.count)
        }
        var v = (c.angle - b.angle) / (c.time - b.time)
        let vPrev = (b.angle - a.angle) / (b.time - a.time)
        if v * vPrev < 0 { return c.angle }
        if abs(v) < brakeRatio * abs(vPrev) { v *= abs(v) / abs(vPrev) }
        let acc = (v - vPrev) / ((c.time - a.time) / 2)
        var h = max(0, min(t - c.time, horizonCap))
        if acc * v < 0 { h = min(h, -v / acc) }
        return c.angle + v * h + 0.5 * acc * h * h
    }
}
