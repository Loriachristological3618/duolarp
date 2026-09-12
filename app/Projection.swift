import Foundation
import QuartzCore
import simd

struct Vec3 {
    var x, y, z: Double
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (s: Double, a: Vec3) -> Vec3 { Vec3(x: s * a.x, y: s * a.y, z: s * a.z) }
    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
}

struct LaptopGeometry {
    var screenWidth: Double
    var screenHeight: Double
    var hingeToScreen = 1.3
    var eyeDistance = 50.0
    var viewingLidAngle = 110.0

    static func up(_ deg: Double) -> Vec3 {
        let r = deg * .pi / 180
        return Vec3(x: 0, y: sin(r), z: cos(r))
    }

    static func normal(_ deg: Double) -> Vec3 {
        let r = deg * .pi / 180
        return Vec3(x: 0, y: -cos(r), z: sin(r))
    }

    func point(lid deg: Double, _ sx: Double, _ sy: Double) -> Vec3 {
        Vec3(x: sx - screenWidth / 2, y: 0, z: 0) + (hingeToScreen + sy) * Self.up(deg)
    }

    var eye: Vec3 {
        point(lid: viewingLidAngle, screenWidth / 2, screenHeight / 2)
            + eyeDistance * Self.normal(viewingLidAngle)
    }
}

struct Homography {
    var m: [Double]

    func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = m[6] * x + m[7] * y + m[8]
        return ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Homography? {
        let a = m
        let c: [Double] = [
            a[4] * a[8] - a[5] * a[7], a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            a[5] * a[6] - a[3] * a[8], a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            a[3] * a[7] - a[4] * a[6], a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ]
        let det = a[0] * c[0] + a[1] * c[3] + a[2] * c[6]
        guard abs(det) > 1e-12 else { return nil }
        var inv = c.map { $0 / det }
        let q = Homography(m: a).apply(1, 1)
        if inv[6] * q.x + inv[7] * q.y + inv[8] < 0 { inv = inv.map { -$0 } }
        return Homography(m: inv)
    }

    var simd: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(Float(m[0]), Float(m[3]), Float(m[6])),
            SIMD3(Float(m[1]), Float(m[4]), Float(m[7])),
            SIMD3(Float(m[2]), Float(m[5]), Float(m[8]))))
    }
}

enum Projection {
    static func homography(_ g: LaptopGeometry, pointSize: CGSize,
                           virtualAngle phi: Double, lidAngle theta: Double) -> Homography? {
        let E = g.eye
        let uPhi = LaptopGeometry.up(phi)
        let uTheta = LaptopGeometry.up(theta), nTheta = LaptopGeometry.normal(theta)
        let a = Vec3(x: -g.screenWidth / 2, y: 0, z: 0) + g.hingeToScreen * uPhi - E

        let k = -E.dot(nTheta)
        let dConst = a.dot(nTheta)
        let dSlope = uPhi.dot(nTheta)
        let cx = E.x + g.screenWidth / 2
        let cy = E.dot(uTheta) - g.hingeToScreen

        guard k < -1e-6 else { return nil }
        let dBottom = dConst, dTop = dConst + g.screenHeight * dSlope
        guard dBottom < -1e-6, dTop < -1e-6 else { return nil }

        var cm: [Double] = [
            k,        cx * dSlope,                          cx * dConst + k * a.x,
            0,        cy * dSlope + k * uPhi.dot(uTheta),   cy * dConst + k * a.dot(uTheta),
            0,        dSlope,                               dConst,
        ]
        let wCentre = dConst + dSlope * g.screenHeight / 2
        cm = cm.map { $0 / wCentre }

        let s = [g.screenWidth / Double(pointSize.width), g.screenHeight / Double(pointSize.height), 1]
        var pt = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { pt[r * 3 + c] = cm[r * 3 + c] * s[c] / s[r] } }
        return Homography(m: pt)
    }
}

struct RayDepth {
    var tCentre: Double
    var z0: Double
    var zx: Double
    var zy: Double
}

extension Projection {
    static func rayDepth(_ g: LaptopGeometry, virtualAngle phi: Double, lidAngle theta: Double) -> RayDepth {
        let E = g.eye
        let uPhi = LaptopGeometry.up(phi), nTheta = LaptopGeometry.normal(theta)
        let a = Vec3(x: -g.screenWidth / 2, y: 0, z: 0) + g.hingeToScreen * uPhi - E
        let k = -E.dot(nTheta)
        let dCentre = a.dot(nTheta) + uPhi.dot(nTheta) * g.screenHeight / 2
        return RayDepth(tCentre: k / dCentre, z0: a.dot(a), zx: a.x, zy: a.dot(uPhi))
    }
}

struct Look {
    var blurPerDepth = 0.18
    var blurMax = 150.0
    var chromaticDefocus = 0.2
    var absorption = 0.065
    var shadowContrast = 0.6
    var shadowGlow = 0.8
    var darkFloor = 0.3
    var glowFalloff = 100.0
    var glowBlur = 0.9
    var feather = 30.0
    var featherGap = 0.03
    var aberration = 0.32
    var aberrationMax = 9.0
}

enum Settle {
    static func duration(for degrees: Double) -> Double {
        min(0.55, 0.28 + 0.08 * sqrt(abs(degrees)))
    }

    static func ease(_ p: Double) -> Double {
        let t = min(max(p, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
