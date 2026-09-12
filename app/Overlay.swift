import AppKit
import ScreenCaptureKit
import os

final class Overlay: NSObject, SCStreamOutput, SCStreamDelegate {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    private let window: NSWindow
    private var mirror: CAMetalLayer?
    private let renderer: MirrorRenderer
    private var pendingShow = false
    private var coolDown: DispatchWorkItem?
    private let captureQueue = DispatchQueue(label: "duolarp.capture", qos: .userInteractive)
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var waitingForFirstFrame = false
    private var onFirstFrame: (() -> Void)?
    var onCaptureError: (() -> Void)?
    private var delivering = false
    private var lastSurface: IOSurfaceRef?
    private var captureLinger: DispatchWorkItem?
    private let lingerTime = 5.0

    var pointSize: CGSize { screen.frame.size }

    init?(screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        guard let renderer = MirrorRenderer(device: CGDirectDisplayCopyCurrentMetalDevice(displayID)) else { return nil }
        self.renderer = renderer
        self.screen = screen
        self.displayID = displayID

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.layer!.backgroundColor = .black
        window.contentView = root
        super.init()
    }

    func prepare() async throws {
        await MainActor.run {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.orderOut(nil)
            window.alphaValue = 1
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "duolarp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in display not shareable"])
        }
        let windowNumber = await MainActor.run { CGWindowID(window.windowNumber) }
        if let own = content.windows.first(where: { $0.windowID == windowNumber }) {
            filter = SCContentFilter(display: display, excludingWindows: [own])
        } else {
            let me = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        }
        lifecycle("capture ready (overlay excluded by \(content.windows.contains { $0.windowID == windowNumber } ? "window" : "app"))")
    }

    func startCapture(firstFrame: @escaping () -> Void) {
        captureLinger?.cancel()
        delivering = true
        if stream != nil {
            if let surface = lastSurface {
                renderer.setSource(surface)
                DispatchQueue.main.async { firstFrame() }
            } else {
                waitingForFirstFrame = true
                onFirstFrame = firstFrame
            }
            return
        }
        guard let filter else { return }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(screen.maximumFramesPerSecond, 60)))
        config.colorSpaceName = CGColorSpace.displayP3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            log("addStreamOutput failed: \(error)")
            return
        }
        self.stream = stream
        waitingForFirstFrame = true
        onFirstFrame = firstFrame
        stream.startCapture { [weak self] error in
            guard let error else { return }
            lifecycle("capture failed to start: \(error.localizedDescription)")
            DispatchQueue.main.async { self?.captureFailed(stream) }
        }
    }

    func endCapture() {
        delivering = false
        waitingForFirstFrame = false
        onFirstFrame = nil
        captureLinger?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopCapture() }
        captureLinger = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lingerTime, execute: work)
    }

    func stopCapture() {
        captureLinger?.cancel()
        delivering = false
        waitingForFirstFrame = false
        onFirstFrame = nil
        lastSurface = nil
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
        DispatchQueue.main.async { [self] in
            guard self.stream === stream else { return }
            lastSurface = surface
            guard delivering else { return }
            renderer.setSource(surface)
            if waitingForFirstFrame {
                waitingForFirstFrame = false
                onFirstFrame?()
                onFirstFrame = nil
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lifecycle("capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [self] in captureFailed(stream) }
    }

    private func captureFailed(_ failed: SCStream) {
        guard stream === failed else { return }
        stream = nil
        lastSurface = nil
        onCaptureError?()
    }

    func show() { pendingShow = true }

    func hide() {
        pendingShow = false
        window.orderOut(nil)
        renderer.clearSource()
        coolDown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.releaseMemory() }
        coolDown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func warmUp() {
        coolDown?.cancel()
        let scale = screen.backingScaleFactor
        renderer.warmUp(width: Int(pointSize.width * scale), height: Int(pointSize.height * scale))
        let layer = mirror ?? makeMirror()
        guard let commands = renderer.queue.makeCommandBuffer() else { return }
        var drawables: [CAMetalDrawable] = []
        for _ in 0..<layer.maximumDrawableCount {
            guard let d = layer.nextDrawable() else { break }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = d.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            drawables.append(d)
        }
        commands.commit()
        commands.waitUntilScheduled()
        drawables.removeAll()
    }

    private func releaseMemory() {
        mirror?.removeFromSuperlayer()
        mirror = nil
        renderer.releaseMemory()
    }

    private func makeMirror() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = true
        layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        layer.contentsScale = screen.backingScaleFactor
        layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                    height: screen.frame.height * screen.backingScaleFactor)
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        window.contentView!.layer!.addSublayer(layer)
        mirror = layer
        return layer
    }

    func close() {
        coolDown?.cancel()
        onCaptureError = nil
        stopCapture()
        hide()
        window.close()
    }

    func draw(_ homography: Homography?, depth: RayDepth, geometry: LaptopGeometry, look: Look) {
        let layer = mirror ?? makeMirror()
        guard let drawable = layer.nextDrawable(), let commands = renderer.queue.makeCommandBuffer() else { return }
        let scale = Float(screen.backingScaleFactor)
        var u = MirrorUniforms()
        if let homography, let inverse = homography.inverse {
            u.inverseH = inverse.simd
            u.wRow = SIMD3(Float(homography.m[6]), Float(homography.m[7]), Float(homography.m[8]))
        } else {
            u.visible = 0
        }
        u.outputPixels = SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
        u.sourcePoints = SIMD2(Float(pointSize.width), Float(pointSize.height))
        u.scale = scale
        u.sourceScale = scale
        u.setDepth(depth, geometry: geometry, pointSize: pointSize)
        u.apply(look)
        renderer.encode(commands, into: drawable.texture, uniforms: u)
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        if pendingShow {
            pendingShow = false
            window.orderFrontRegardless()
        }
    }
}

private let lifecycleLog = Logger(subsystem: "com.nipuntalag.duolarp", category: "lifecycle")
func lifecycle(_ message: String) {
    lifecycleLog.notice("\(message, privacy: .public)")
    log(message)
}

let loggingEnabled = ProcessInfo.processInfo.environment["DUOLARP_LOG"] != nil
func log(_ s: @autoclosure () -> String) {
    guard loggingEnabled else { return }
    FileHandle.standardError.write(String(format: "[%.3f] ", CACurrentMediaTime()).data(using: .utf8)! + (s() + "\n").data(using: .utf8)!)
}
