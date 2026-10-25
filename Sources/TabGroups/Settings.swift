import AppKit
import ApplicationServices

/// The app's only window: shown when TabGroups is opened (not when it starts
/// at login), and again whenever it's reopened from Finder or the Dock.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    static func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private let loginBox = NSButton(checkboxWithTitle: L10n.text("settings.launch_at_login", fallback: "Launch at login"),
                                    target: nil, action: nil)
    private let dockBox = NSButton(checkboxWithTitle: L10n.text("settings.show_in_dock", fallback: "Show in Dock"),
                                   target: nil, action: nil)
    private let keyPopup = NSPopUpButton()
    private let switchPopup = NSPopUpButton()
    private let axStatus = NSTextField(labelWithString: "")
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
        keyPopup.selectItem(at: DragKey.allCases.firstIndex(of: DragKey.current) ?? 0)
        switchPopup.selectItem(at: SwitchKey.allCases.firstIndex(of: SwitchKey.current) ?? 0)
        let trusted = AXIsProcessTrusted()
        axStatus.stringValue = trusted
            ? L10n.text("settings.accessibility_allowed", fallback: "✓ Accessibility allowed")
            : L10n.text("settings.accessibility_not_allowed", fallback: "⚠︎ Accessibility not allowed")
        axStatus.textColor = trusted ? .secondaryLabelColor : .systemOrange
        // A rebuilt (re-signed) app stays ticked in the list but isn't trusted.
        axStatus.toolTip = trusted ? nil : L10n.text(
            "settings.accessibility_tooltip",
            fallback: "Already ticked? Remove TabGroups from the list and add it again."
        )
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

    /// Back from System Settings: the grant may have changed.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func checkForUpdates() { Updates.shared.check() }

    @objc private func pickKey() {
        DragKey.current = DragKey.allCases[keyPopup.indexOfSelectedItem]
    }

    @objc private func pickSwitchKey() {
        SwitchKey.current = SwitchKey.allCases[switchPopup.indexOfSelectedItem]
        // The strips' hints show the key.
        for case let strip as TabStripPanel in NSApp.windows {
            strip.contentView?.subviews.forEach { $0.needsDisplay = true }
        }
    }

    private func makeWindow() -> NSWindow {
        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        dockBox.target = self
        dockBox.action = #selector(toggleDock)

        keyPopup.addItems(withTitles: DragKey.allCases.map(\.title))
        keyPopup.target = self
        keyPopup.action = #selector(pickKey)
        let keyRow = NSStackView(views: [
            NSTextField(labelWithString: L10n.text("settings.drag_key", fallback: "Drag key:")), keyPopup,
        ])
        switchPopup.addItems(withTitles: SwitchKey.allCases.map(\.title))
        switchPopup.target = self
        switchPopup.action = #selector(pickSwitchKey)
        let switchRow = NSStackView(views: [NSTextField(labelWithString: L10n.text(
                                                "settings.switch_tabs", fallback: "Switch tabs:"
                                            )), switchPopup,
                                            NSTextField(labelWithString: "+ 1…9")])
        let axRow = NSStackView(views: [axStatus, NSButton(
            title: L10n.text("settings.open_system_settings", fallback: "Open Settings…"),
            target: self,
            action: #selector(openAccessibility)
        )])

        let hint = NSTextField(wrappingLabelWithString: L10n.text(
            "settings.hint",
            fallback: "Hold the drag key to move a window by any spot. Drag it onto the middle of another, "
                + "still holding the key, and pause a moment to stack them under one strip of tabs. "
                + "The switch key with 1…9 shows that tab (9: the last)."
        ))
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let quit = NSButton(title: L10n.text("settings.quit", fallback: "Quit TabGroups"),
                            target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let updates = NSButton(title: L10n.text("settings.check_for_updates", fallback: "Check for Updates…"),
                               target: self, action: #selector(checkForUpdates))
        let version = NSTextField(labelWithString: L10n.format(
            "settings.version", fallback: "Version %@", Updates.current
        ))
        version.textColor = .secondaryLabelColor
        let updateRow = NSStackView(views: [updates, version])
        let rows: [NSView] = [hint, axRow, keyRow, switchRow, loginBox, dockBox, updateRow, quit]

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: hint)
        stack.setCustomSpacing(16, after: axRow)
        stack.setCustomSpacing(16, after: switchRow)
        stack.setCustomSpacing(20, after: dockBox)
        // The content runs under the transparent title bar: leave room for it.
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.title = "TabGroups"
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
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
