import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tracker = WindowTracker()
    private lazy var groups = GroupManager(tracker: tracker)
    private lazy var drags = DragController(tracker: tracker, groups: groups)
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleSignals()

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            start()
        } else {
            // Wait for the user to tick us in System Settings ▸ Privacy ▸ Accessibility.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows parked in a corner.
        groups.ungroupAll()
    }

    private func start() {
        guard !started else { return }
        started = true
        tracker.delegate = groups
        tracker.start()
        drags.start()
    }

    /// Ctrl-C from `swift run` skips applicationWillTerminate; route it through terminate.
    private func handleSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }
}

@main
enum TabGroupsApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()   // run() never returns, so this stays alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }
}
