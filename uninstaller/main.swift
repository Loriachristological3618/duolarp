import AppKit

final class Uninstaller: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Uninstall duolarp?"
        confirm.informativeText = """
            This quits duolarp and removes it — the app (to the Bin), its login item, its \
            Screen Recording permission and its settings. Nothing else on your Mac is touched.
            """
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        let problems = removeDuolarp()
        let done = NSAlert()
        done.messageText = problems.isEmpty ? "duolarp has been removed" : "duolarp was almost fully removed"
        done.informativeText = problems.isEmpty ? "Everything it added to this Mac is gone." : problems.joined(separator: "\n")
        done.runModal()
        forgetSelf()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = Uninstaller()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
