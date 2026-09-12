import AppKit

final class Installer: NSObject, NSApplicationDelegate {
    private let payload = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/duolarp.app")
    private var window: NSWindow!
    private var status: NSTextField!
    private var buttons: [NSButton] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        window = makeWindow(installed: !installedCopies().isEmpty)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func makeWindow(installed: Bool) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = installed ? "duolarp" : "Install duolarp"
        w.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.image = NSImage(contentsOf: payload.appendingPathComponent("Contents/Resources/AppIcon.icns")) ?? icon.image
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let title = NSTextField(labelWithString: "duolarp")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let tagline = NSTextField(wrappingLabelWithString: "Move your MacBook's lid and the picture stays still in space, then settles back when you stop.")
        tagline.textColor = .secondaryLabelColor
        tagline.preferredMaxLayoutWidth = 320
        tagline.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let heading = NSStackView(views: [title, tagline])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        let top = NSStackView(views: [icon, heading])
        top.alignment = .centerY
        top.spacing = 16

        let points = installed ? [
            ("arrow.clockwise", "Reinstall puts a fresh copy in Applications and restarts it."),
            ("trash", "Uninstall removes duolarp and everything it added — its login item, its screen permission and its settings. Nothing else is touched."),
        ] : [
            ("folder", "duolarp is copied into your Applications folder and starts in the menu bar — there's no window or Dock icon."),
            ("rectangle.dashed.badge.record", "macOS will ask once to let it see your screen. It only looks while your lid is moving, and never saves or sends anything."),
            ("wifi.slash", "It never uses the internet."),
            ("xmark.circle", "Remove it any time from its menu bar icon → Uninstall duolarp…"),
        ]
        let list = NSStackView(views: points.map { symbol, text in
            let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            glyph.contentTintColor = .controlAccentColor
            glyph.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            glyph.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.preferredMaxLayoutWidth = 400
            label.widthAnchor.constraint(equalToConstant: 400).isActive = true
            let row = NSStackView(views: [glyph, label])
            row.alignment = .firstBaseline
            row.spacing = 10
            return row
        })
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12

        status = NSTextField(wrappingLabelWithString: "")
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 230
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        if installed {
            let uninstall = NSButton(title: "Uninstall", target: self, action: #selector(uninstall))
            let reinstall = NSButton(title: "Reinstall", target: self, action: #selector(install))
            reinstall.keyEquivalent = "\r"
            buttons = [uninstall, cancel, reinstall]
        } else {
            let install = NSButton(title: "Install", target: self, action: #selector(install))
            install.keyEquivalent = "\r"
            buttons = [cancel, install]
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [status, spacer] + buttons)
        bar.spacing = 10

        let content = NSStackView(views: [top, list, bar])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 24
        content.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 22, right: 28)
        bar.widthAnchor.constraint(equalToConstant: 444).isActive = true
        w.contentView = content
        content.layoutSubtreeIfNeeded()
        w.setContentSize(content.fittingSize)
        return w
    }

    @objc private func cancel() { quit() }

    @objc private func install() {
        busy("Installing…")
        quitDuolarp()
        let fm = FileManager.default
        for dir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            let dest = dir.appendingPathComponent("duolarp.app")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    guard Bundle(url: dest)?.bundleIdentifier == duolarpID else { continue }
                    try fm.trashItem(at: dest, resultingItemURL: nil)
                }
                try fm.copyItem(at: payload, to: dest)
                run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
                NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    DispatchQueue.main.async {
                        if let error {
                            self.fail("duolarp was installed but didn't start: \(error.localizedDescription)")
                        } else {
                            self.finish("Installed — duolarp is starting in your menu bar.")
                        }
                    }
                }
                return
            } catch {
                continue
            }
        }
        fail("Couldn't copy duolarp into Applications.")
    }

    @objc private func uninstall() {
        busy("Removing…")
        let problems = removeDuolarp()
        if problems.isEmpty { finish("duolarp has been removed. Everything it added is gone.") }
        else { fail(problems.joined(separator: "\n")) }
    }

    private func busy(_ text: String) {
        status.stringValue = text
        buttons.forEach { $0.isEnabled = false }
        status.displayIfNeeded()
    }

    private func finish(_ text: String) {
        status.stringValue = text
        status.textColor = .labelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.quit() }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Something went wrong"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in self.quit() }
    }

    private func quit() {
        forgetSelf()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = Installer()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
