import Metal
import MetalPerformanceShaders
import simd
import CoreGraphics

struct MirrorUniforms {
    var inverseH = matrix_identity_float3x3
    var outputPixels = SIMD2<Float>(1, 1)
    var sourcePoints = SIMD2<Float>(1, 1)
    var scale: Float = 2
    var sourceScale: Float = 2
    var wRow = SIMD3<Float>(0, 0, 1)
    var tCentre: Float = 1
    var z0: Float = 0, zx: Float = 0, zy: Float = 0
    var cmPerPointX: Float = 0, cmPerPointY: Float = 0
    var blurPerDepth: Float = 0
    var panelCm: Float = 1
    var blurMax: Float = 0
    var chromaticDefocus: Float = 0
    var absorption: Float = 0
    var shadowContrast: Float = 0
    var shadowGlow: Float = 0
    var darkFloor: Float = 0
    var glowFalloff: Float = 1
    var glowBlur: Float = 0
    var feather: Float = 0
    var featherGap: Float = 1
    var aberration: Float = 0
    var aberrationMax: Float = 0
    var visible: Float = 1
    var levels: Float = 1
}

extension MirrorUniforms {
    mutating func setDepth(_ d: RayDepth, geometry g: LaptopGeometry, pointSize: CGSize) {
        tCentre = Float(d.tCentre)
        z0 = Float(d.z0); zx = Float(d.zx); zy = Float(d.zy)
        cmPerPointX = Float(g.screenWidth / Double(pointSize.width))
        cmPerPointY = Float(g.screenHeight / Double(pointSize.height))
        panelCm = Float(g.hingeToScreen + g.screenHeight)
    }

    mutating func apply(_ look: Look) {
        blurPerDepth = Float(look.blurPerDepth)
        blurMax = Float(look.blurMax)
        chromaticDefocus = Float(look.chromaticDefocus)
        absorption = Float(look.absorption)
        shadowContrast = Float(look.shadowContrast)
        shadowGlow = Float(look.shadowGlow)
        darkFloor = Float(look.darkFloor)
        glowFalloff = Float(look.glowFalloff)
        glowBlur = Float(look.glowBlur)
        feather = Float(look.feather)
        featherGap = Float(look.featherGap)
        aberration = Float(look.aberration)
        aberrationMax = Float(look.aberrationMax)
    }
}

final class MirrorRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let pyramid: MPSImageGaussianPyramid
    private(set) var pyramidTexture: MTLTexture?
    private var hasFrame = false
    private var pendingSource: MTLTexture?
    private var pendingSurface: IOSurfaceRef?

    init?(device preferred: MTLDevice? = nil, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device = preferred ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fullscreen")
            desc.fragmentFunction = library.makeFunction(name: "mirror")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            log("shader: \(error)")
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .nearest
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
        pyramid = MPSImageGaussianPyramid(device: device)
    }

    func setSource(_ surface: IOSurfaceRef) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
        desc.usage = .shaderRead
        pendingSource = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
        pendingSurface = surface
    }

    func setSource(_ texture: MTLTexture) {
        pendingSource = texture
        pendingSurface = nil
    }

    func clearSource() {
        pendingSource = nil
        pendingSurface = nil
        hasFrame = false
    }

    func warmUp(width: Int, height: Int) {
        guard pyramidTexture?.width != width || pyramidTexture?.height != height else { return }
        pyramidTexture = makePyramid(width: width, height: height)
    }

    func releaseMemory() {
        clearSource()
        pyramidTexture = nil
    }

    private func makePyramid(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    func encode(_ commandBuffer: MTLCommandBuffer, into target: MTLTexture, uniforms: MirrorUniforms) {
        if let source = pendingSource {
            buildPyramid(commandBuffer, from: source)
            hasFrame = true
            let surface = pendingSurface
            commandBuffer.addCompletedHandler { _ in _ = surface }
            pendingSource = nil
            pendingSurface = nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let tex = pyramidTexture, hasFrame {
            var u = uniforms
            u.levels = Float(tex.mipmapLevelCount)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<MirrorUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func buildPyramid(_ commandBuffer: MTLCommandBuffer, from source: MTLTexture) {
        if pyramidTexture?.width != source.width || pyramidTexture?.height != source.height {
            pyramidTexture = makePyramid(width: source.width, height: source.height)
        }
        guard let tex = pyramidTexture, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: tex, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.endEncoding()
        var inPlace: MTLTexture = tex
        pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &inPlace, fallbackCopyAllocator: nil)
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float3x3 inverseH;
        float2 outputPixels;
        float2 sourcePoints;
        float scale, sourceScale;
        float3 wRow;
        float tCentre, z0, zx, zy;
        float cmPerPointX, cmPerPointY;
        float blurPerDepth, panelCm, blurMax, chromaticDefocus;
        float absorption, shadowContrast, shadowGlow, darkFloor;
        float glowFalloff, glowBlur, feather, featherGap;
        float aberration, aberrationMax;
        float visible, levels;
    };

    vertex float4 fullscreen(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2 - 1, 0, 1);
    }

    static float4 bspline(texture2d<float> t, sampler s, float2 px, uint k) {
        float2 size = float2(t.get_width(k), t.get_height(k));
        float2 st = (px - 1) / float(1 << k);
        float2 i = floor(st), f = st - i;
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (1 - 3 * f + 3 * f2 - f3) / 6;
        float2 w1 = (4 - 6 * f2 + 3 * f3) / 6;
        float2 w2 = (1 + 3 * f + 3 * f2 - 3 * f3) / 6;
        float2 w3 = f3 / 6;
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 h0 = (i - 0.5 + w1 / g0) / size;
        float2 h1 = (i + 1.5 + w3 / g1) / size;
        return g0.y * (g0.x * t.sample(s, float2(h0.x, h0.y), level(k)) + g1.x * t.sample(s, float2(h1.x, h0.y), level(k)))
             + g1.y * (g0.x * t.sample(s, float2(h0.x, h1.y), level(k)) + g1.x * t.sample(s, float2(h1.x, h1.y), level(k)));
    }

    static float levelVariance(float k) { return k < 0.5 ? 0.0 : (2 * exp2(2 * k) - 1) / 3; }

    static float3 levelSample(texture2d<float> t, sampler s, float2 uv, float2 px, float k) {
        return k < 0.5 ? t.sample(s, uv, level(0)).rgb : bspline(t, s, px, uint(k)).rgb;
    }

    static float3 blurred(texture2d<float> t, sampler s, float2 uv, float3 variance, float levels) {
        float vmin = min(variance.r, min(variance.g, variance.b));
        float vmax = max(variance.r, max(variance.g, variance.b));
        if (vmax < 1e-3) return t.sample(s, uv, level(0)).rgb;
        float2 px = uv * float2(t.get_width(0), t.get_height(0));
        float k = clamp(floor(0.5 * log2((3 * vmin + 1) / 2)), 0.0, levels - 3);
        float v0 = levelVariance(k), v1 = levelVariance(k + 1);
        float3 a = levelSample(t, s, uv, px, k), b = levelSample(t, s, uv, px, k + 1);
        float3 low = a + saturate((variance - v0) / (v1 - v0)) * (b - a);
        if (vmax <= v1) return low;
        float v2 = levelVariance(k + 2);
        float3 c = levelSample(t, s, uv, px, k + 2);
        float3 high = b + saturate((variance - v1) / (v2 - v1)) * (c - b);
        return select(low, high, variance > v1);
    }

    fragment float4 mirror(float4 pos [[position]],
                           constant Uniforms& u [[buffer(0)]],
                           texture2d<float> src [[texture(0)]],
                           sampler smp [[sampler(0)]]) {
        if (u.visible < 0.5) return float4(0, 0, 0, 1);
        float2 W = u.sourcePoints;

        float2 q = float2(pos.x, u.outputPixels.y - pos.y) / u.scale;

        float3 h = u.inverseH * float3(q, 1);
        bool ahead = h.z > 0;
        float2 p = h.xy / max(h.z, 1e-6);
        float2 pc = clamp(p, 0.0, W);

        float2 srcPx = float2(p.x / W.x, 1 - p.y / W.y) * float2(src.get_width(), src.get_height());
        float2 jx = dfdx(srcPx), jy = dfdy(srcPx);
        float m = clamp(max(length(jx), length(jy)), 1e-3, 64.0);
        float areaRatio = abs(jx.x * jy.y - jx.y * jy.x);

        float t = u.tCentre / max(dot(u.wRow, float3(p, 1)), 1e-4);
        float gap = abs(t - 1);
        float2 cm = p * float2(u.cmPerPointX, u.cmPerPointY);
        float zFocus = sqrt(max(u.z0 + dot(cm, cm) + 2 * (cm.x * u.zx + cm.y * u.zy), 1.0));

        float sigmaPt = min(u.blurPerDepth * W.y * gap * zFocus / u.panelCm, u.blurMax);
        float side = t > 1 ? 1.0 : -1.0;
        float3 channelSigma = sigmaPt * float3(1 - u.chromaticDefocus * side, 1, 1 + u.chromaticDefocus * side);

        float toGlass = u.sourceScale / m / u.scale;
        float outside = length(p - pc) * toGlass;
        float edge = outside > 0 ? -outside : min(min(p.x, W.x - p.x), min(p.y, W.y - p.y)) * toGlass;
        float glowPt = u.glowBlur * outside;

        float3 sigmaPx = sqrt(channelSigma * channelSigma + glowPt * glowPt) * u.scale;
        float3 variance = sigmaPx * sigmaPx * m * m + 0.25 * max(m * m - 1, 0.0);
        float3 c = blurred(src, smp, float2(pc.x / W.x, 1 - pc.y / W.y), variance, u.levels);

        float2 radial = q - 0.5 * u.outputPixels / u.scale;
        float2 dir = radial / max(length(radial), 1.0);
        float shiftPx = min(u.aberration * sigmaPx.g / u.scale, u.aberrationMax) * u.scale;
        float2 delta = float2(dir.x, -dir.y) * shiftPx;
        c.r += dfdx(c.r) * delta.x + dfdy(c.r) * delta.y;
        c.b -= dfdx(c.b) * delta.x + dfdy(c.b) * delta.y;

        float absorbed = exp(-u.absorption * gap * zFocus);
        float spread = min(areaRatio, 1.0);
        float shadow = 1 - max(absorbed * spread, u.darkFloor);
        c = saturate(c);

        if (shadow > 1e-5) {
            c = pow(c, 1 + u.shadowContrast * shadow) * (1 - shadow);
            float3 around = src.sample(smp, float2(pc.x / W.x, 1 - pc.y / W.y), level(min(7.0, u.levels - 1))).rgb;
            c += max(around * (1 - shadow) - c, 0.0) * shadow * u.shadowGlow;
        }

        float start = u.feather * saturate(gap / u.featherGap);
        float into = max(start - edge, 0.0) / u.glowFalloff;
        float fade = exp(-into * into);
        return float4(ahead ? saturate(c) * fade : 0, 1);
    }
    """
}
