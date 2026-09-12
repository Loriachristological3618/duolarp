import AppKit
import ScreenCaptureKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller?
    private var sampler: HingeSampler?
    private var distanceMenu = NSMenu()
    private static let distances: [(String, Double)] = [("Close — 40 cm", 40), ("Normal — 50 cm", 50), ("Relaxed — 60 cm", 60), ("Far — 70 cm", 70)]
    private var eyeDistance: Double {
        get { UserDefaults.standard.object(forKey: "eyeDistance") as? Double ?? 50 }
        set { UserDefaults.standard.set(newValue, forKey: "eyeDistance") }
    }
    private var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var problem: String?

    private var generation = 0
    private var rebuildWork: DispatchWorkItem?
    private var retryDelay = 0.5
    private var systemAsleep = false
    private var displaysAsleep = false
    private var sessionInactive = false
    private var permissionWatch: Timer?
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard onlyInstance(), installedProperly() else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.portrait.on.rectangle.portrait.angled",
                                           accessibilityDescription: "duolarp")
            ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "duolarp")

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        enabledItem = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.state = UserDefaults.standard.object(forKey: "enabled") as? Bool == false ? .off : .on
        let distanceItem = menu.addItem(withTitle: "Viewing Distance", action: nil, keyEquivalent: "")
        for (i, (title, _)) in Self.distances.enumerated() {
            distanceMenu.addItem(withTitle: title, action: #selector(pickDistance(_:)), keyEquivalent: "").tag = i
        }
        distanceItem.submenu = distanceMenu
        loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        permissionItem = menu.addItem(withTitle: "Allow Screen Recording…", action: #selector(openPrivacy), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall duolarp…", action: #selector(uninstall), keyEquivalent: "")
        menu.addItem(withTitle: "Quit duolarp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        let source: AngleSource? = LidSensor()
        guard let source else {
            unsupportedMac()
            return
        }
        sampler = HingeSampler(source: source)
        sampler?.start()

        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                      reason: "Following the lid angle")

        if !CGPreflightScreenCaptureAccess() { welcome() }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = true
            self?.tearDown("system will sleep")
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = false
            self?.setNeedsRebuild("system woke", after: 0.5)
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = true
            self?.tearDown("displays slept")
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = false
            self?.setNeedsRebuild("displays woke", after: 0.5)
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = true
            self?.tearDown("user session switched out")
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = false
            self?.setNeedsRebuild("user session active")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setNeedsRebuild("display configuration changed")
        }
        setNeedsRebuild("launch", after: 0)
    }

    private func setNeedsRebuild(_ reason: String, after delay: Double = 0.3) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason) }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func retryLater(_ reason: String) {
        if retryDelay < 10 { lifecycle("\(reason); retrying in \(retryDelay) s") }
        setNeedsRebuild("retry", after: retryDelay)
        retryDelay = min(retryDelay * 2, 10)
    }

    private func tearDown(_ reason: String) {
        generation += 1
        rebuildWork?.cancel()
        if controller != nil { lifecycle("session ended: \(reason)") }
        controller?.invalidate()
        controller = nil
    }

    private func rebuild(_ reason: String) {
        tearDown(reason)
        guard let sampler else { return }
        guard !systemAsleep, !displaysAsleep, !sessionInactive else { return }
        let built = generation

        guard let screen = NSScreen.screens.first(where: {
            let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        }) else {
            problem = "Built-in display is off"
            retryLater("built-in display not available")
            return
        }
        guard let overlay = Overlay(screen: screen) else {
            problem = "Metal unavailable"
            return
        }
        let mm = CGDisplayScreenSize(overlay.displayID)
        var geometry = LaptopGeometry(screenWidth: mm.width > 0 ? mm.width / 10 : 30.4,
                                      screenHeight: mm.height > 0 ? mm.height / 10 : 19.7)
        geometry.eyeDistance = eyeDistance

        Task { @MainActor in
            do {
                try await overlay.prepare()
                guard built == generation else { overlay.close(); return }
                let c = Controller(sampler: sampler, overlay: overlay, geometry: geometry)
                c.enabled = enabledItem.state == .on
                c.onFailure = { [weak self] in self?.setNeedsRebuild("capture failed", after: 0.5) }
                controller = c
                problem = nil
                retryDelay = 0.5
                lifecycle(String(format: "session started (%@): %.1f × %.1f cm, %.0f × %.0f pt",
                                 reason, geometry.screenWidth, geometry.screenHeight,
                                 screen.frame.width, screen.frame.height))
            } catch {
                overlay.close()
                guard built == generation else { return }
                if CGPreflightScreenCaptureAccess() {
                    problem = "Waiting for the display…"
                    retryLater("capture setup failed: \(error.localizedDescription)")
                } else {
                    problem = "Screen Recording not allowed"
                    lifecycle("screen recording not allowed")
                    watchForPermission()
                }
            }
        }
    }

    private func onlyInstance() -> Bool {
        let me = NSRunningApplication.current
        let deadline = Date(timeIntervalSinceNow: 3)
        while true {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0 != me && !$0.isTerminated }
            if others.isEmpty { return true }
            if Date() > deadline {
                lifecycle("another copy is already running; quitting")
                NSApp.terminate(nil)
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func installedProperly() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return true }
        let alert = NSAlert()
        alert.messageText = "Move duolarp to Applications?"
        alert.informativeText = "It needs to live in your Applications folder to open at login and keep its permission."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }
        let fm = FileManager.default
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let dest = URL(fileURLWithPath: dir).appendingPathComponent("duolarp.app")
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
                NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                return false
            } catch {
                continue
            }
        }
        let failed = NSAlert()
        failed.messageText = "Couldn't move duolarp"
        failed.informativeText = "Drag it from the disk image into your Applications folder, then open it from there."
        failed.runModal()
        NSApp.terminate(nil)
        return false
    }

    private func welcome() {
        guard !UserDefaults.standard.bool(forKey: "welcomed") else {
            CGRequestScreenCaptureAccess()
            return
        }
        UserDefaults.standard.set(true, forKey: "welcomed")
        let alert = NSAlert()
        alert.messageText = "duolarp lives in your menu bar"
        alert.informativeText = """
            Move your MacBook's lid and the picture stays still in space, then settles back \
            when you stop.

            To draw that, duolarp needs to see your screen, so macOS will ask for Screen \
            Recording next. Nothing is ever saved or sent anywhere.
            """
        alert.addButton(withTitle: "Continue")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Open duolarp at login"
        alert.suppressionButton?.state = .on
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if alert.suppressionButton?.state == .on { try? SMAppService.mainApp.register() }
        CGRequestScreenCaptureAccess()
    }

    private func watchForPermission() {
        guard permissionWatch == nil else { return }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            self?.permissionWatch = nil
            self?.setNeedsRebuild("screen recording allowed", after: 0)
        }
    }

    private func unsupportedMac() {
        let alert = NSAlert()
        alert.messageText = "This Mac has no lid angle sensor"
        alert.informativeText = """
            duolarp follows the hinge of MacBooks that have one: MacBook Air (M2 and later), \
            14- and 16-inch MacBook Pro (2021 and later), and the 16-inch MacBook Pro (2019).
            """
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if controller == nil, problem == "Screen Recording not allowed", CGPreflightScreenCaptureAccess() {
            setNeedsRebuild("screen recording allowed", after: 0)
        }
        if let problem {
            statusLine.title = problem
        } else if let angle = sampler?.latest?.angle {
            statusLine.title = String(format: "Lid at %.1f°", angle)
        }
        permissionItem.isHidden = CGPreflightScreenCaptureAccess()
        for item in distanceMenu.items { item.state = Self.distances[item.tag].1 == eyeDistance ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        enabledItem.state = enabledItem.state == .on ? .off : .on
        UserDefaults.standard.set(enabledItem.state == .on, forKey: "enabled")
        controller?.enabled = enabledItem.state == .on
    }

    @objc private func pickDistance(_ item: NSMenuItem) {
        eyeDistance = Self.distances[item.tag].1
        controller?.geometry.eyeDistance = eyeDistance
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item: \(error)")
        }
    }

    @objc private func uninstall() {
        let uninstaller = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Uninstall duolarp.app")
        NSWorkspace.shared.openApplication(at: uninstaller, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't open the uninstaller"
                alert.informativeText = "Quit duolarp, then move it from Applications to the Bin."
                alert.runModal()
            }
        }
    }

    @objc private func openPrivacy() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

if CommandLine.arguments.contains("--unregister") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
