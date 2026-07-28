import AppKit

if CommandLine.arguments.contains("--smoke") {
    exit(SmokeTest.run())
}

// NSApp.delegate 不持有 delegate,需要全局强引用
nonisolated(unsafe) var retainedDelegate: AnyObject?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
