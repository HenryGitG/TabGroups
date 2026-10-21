import AppKit

/// The app's only window: shown when TabGroups is opened (not when it starts
/// at login), and again whenever it's reopened from Finder or the Dock.
@MainActor
final class SettingsWindow: NSObject {
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    static func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let dockBox = NSButton(checkboxWithTitle: "Show in Dock", target: nil, action: nil)
    private lazy var window = makeWindow()

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        loginBox.state = LoginItem.isEnabled ? .on : .off
        loginBox.isEnabled = LoginItem.isAvailable
        dockBox.state = Self.showInDock ? .on : .off
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
        refresh()
    }

    @objc private func toggleDock() {
        Self.showInDock = dockBox.state == .on
        Self.applyDockPolicy()
        // Leaving the Dock deactivates the app; keep this window in front.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.show() } }
    }

    private func makeWindow() -> NSWindow {
        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        dockBox.target = self
        dockBox.action = #selector(toggleDock)

        let hint = NSTextField(wrappingLabelWithString:
            "Drag a window onto the middle of another and pause a moment to stack them under one strip of tabs.")
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let quit = NSButton(title: "Quit TabGroups", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let rows: [NSView] = [hint, loginBox, dockBox, quit]

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: hint)
        stack.setCustomSpacing(20, after: dockBox)
        // The content runs under the transparent title bar: leave room for it.
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.title = "TabGroups"
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        let size = NSSize(width: 340, height: stack.fittingSize.height)
        if #available(macOS 26, *) {
            // Liquid Glass: the whole window is one pane of glass.
            w.isOpaque = false
            w.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            glass.contentView = stack
            w.contentView = glass
        } else {
            w.contentView = stack
        }
        w.setContentSize(size)
        w.center()
        return w
    }
}
