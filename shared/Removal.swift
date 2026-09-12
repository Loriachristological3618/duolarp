import AppKit

let duolarpID = "com.nipuntalag.duolarp"
let home = FileManager.default.homeDirectoryForCurrentUser

func installedCopies() -> [URL] {
    [URL(fileURLWithPath: "/Applications/duolarp.app"), home.appendingPathComponent("Applications/duolarp.app")]
        .filter { Bundle(url: $0)?.bundleIdentifier == duolarpID }
}

@discardableResult
func run(_ tool: String, _ args: [String], timeout: TimeInterval = 5) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate() }
    return p.isRunning ? -1 : p.terminationStatus
}

func quitDuolarp() {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: duolarpID)
    running.forEach { $0.terminate() }
    let deadline = Date(timeIntervalSinceNow: 3)
    while running.contains(where: { !$0.isTerminated }), Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
}

func userCacheDirectory() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer))
}

func removeDuolarp() -> [String] {
    var problems: [String] = []
    quitDuolarp()
    for app in installedCopies() {
        let exe = app.appendingPathComponent("Contents/MacOS/duolarp")
        if FileManager.default.isExecutableFile(atPath: exe.path) { run(exe.path, ["--unregister"]) }
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
        } catch {
            problems.append("Couldn't move \(app.path) to the Bin — drag it there yourself.")
        }
    }
    run("/usr/bin/tccutil", ["reset", "ScreenCapture", duolarpID])
    run("/usr/bin/defaults", ["delete", duolarpID])
    if let caches = userCacheDirectory() {
        try? FileManager.default.removeItem(at: caches.appendingPathComponent(duolarpID))
    }
    return problems
}

func forgetSelf() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    run("/usr/bin/defaults", ["delete", id])
    if let caches = userCacheDirectory() { try? FileManager.default.removeItem(at: caches.appendingPathComponent(id)) }
}
