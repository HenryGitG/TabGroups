import AppKit

struct TabItem {
    let id: CGWindowID
    let title: String
    let icon: NSImage?
}

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripPanel, didSelect id: CGWindowID)
    func tabStrip(_ strip: TabStripPanel, didClose id: CGWindowID)
    func tabStrip(_ strip: TabStripPanel, didMove id: CGWindowID, to index: Int)
    /// `point` is where the tab was dropped; nil when it came from the context menu.
    func tabStrip(_ strip: TabStripPanel, didTearOff id: CGWindowID, at point: CGPoint?)
    func tabStripUngroupAll(_ strip: TabStripPanel)
}

/// The interactive top of the shell around a group. A click-through companion
/// panel draws the connected sides and bottom around the shown window.
@MainActor
final class TabStripPanel: NSPanel {
    weak var stripDelegate: TabStripDelegate?
    private let tabsView = TabStripView()
    private let shellPanel = GroupShellPanel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: Style.stripHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false      // NSPanel defaults to true; we're never active
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .transient]   // transient: hidden in Mission Control
        animationBehavior = .none

        // Adaptive glass: the tint and text in draw(_:) follow the system appearance.
        let fx = NSVisualEffectView()
        fx.material = .headerView
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = .topRoundedMask(radius: Style.cornerRadius)
        contentView = fx

        tabsView.frame = fx.bounds
        tabsView.autoresizingMask = [.width, .height]
        tabsView.owner = self
        fx.addSubview(tabsView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(items: [TabItem], active: CGWindowID, hints: Bool) {
        tabsView.items = items
        tabsView.active = active
        tabsView.hints = hints
        tabsView.needsDisplay = true
    }

    func show(at axFrame: CGRect, shell axShellFrame: CGRect, above windowID: CGWindowID) {
        setFrames(strip: axFrame, shell: axShellFrame)
        if !isVisible { orderFrontRegardless() }
        if shellPanel.parent == nil { addChildWindow(shellPanel, ordered: .below) }
        order(.above, relativeTo: Int(windowID))
    }

    func setFrames(strip axStripFrame: CGRect, shell axShellFrame: CGRect) {
        setFrame(Coords.toAppKit(axStripFrame), display: true)
        shellPanel.setFrame(Coords.toAppKit(axShellFrame), display: true)
    }

    override func orderOut(_ sender: Any?) {
        removeChildWindow(shellPanel)
        shellPanel.orderOut(nil)
        super.orderOut(sender)
    }
}

@MainActor
final class TabStripView: NSView {
    weak var owner: TabStripPanel?
    var items: [TabItem] = []
    var active: CGWindowID = 0
    var hints = true

    private var hovered: Int?
    private var pressedID: CGWindowID?
    private var pressPoint: NSPoint = .zero
    private var dragging = false
    private var torn = false
    private let chip = TabChip()
    private let tearDistance: CGFloat = 24

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Geometry

    private func tabRect(_ i: Int) -> NSRect {
        let inset: CGFloat = 5, gap: CGFloat = 4, height: CGFloat = 26
        let n = CGFloat(max(items.count, 1))
        let w = (bounds.width - inset * 2 - gap * (n - 1)) / n
        return NSRect(x: inset + CGFloat(i) * (w + gap), y: (bounds.height - height) / 2, width: w, height: height)
    }

    private func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i)
        return NSRect(x: r.minX + 6, y: r.midY - 7, width: 14, height: 14)
    }

    private func index(at p: NSPoint) -> Int? {
        items.indices.first { tabRect($0).contains(p) }
    }

    private func slot(forX x: CGFloat) -> Int {
        items.indices.min { abs(tabRect($0).midX - x) < abs(tabRect($1).midX - x) } ?? 0
    }

    // MARK: Drawing

    /// TrellisWM's translucent strip, adapted to the current system appearance.
    override func draw(_ dirtyRect: NSRect) {
        let ink = NSColor.labelColor
        let outline = NSBezierPath.topRoundedRect(bounds, radius: Style.cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.78).setFill()
        outline.fill()
        ink.withAlphaComponent(0.14).setStroke()
        let r = Style.cornerRadius - 0.5
        NSBezierPath.topRoundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: r).stroke()

        // Dividers between tabs, left out next to a filled (shown or hovered) tab.
        ink.withAlphaComponent(0.14).setFill()
        for i in items.indices.dropFirst() {
            let filled = { (j: Int) in self.items[j].id == self.active || (self.hovered == j && !self.dragging) }
            if filled(i - 1) || filled(i) { continue }
            let r = tabRect(i)
            NSRect(x: r.minX - 2.5, y: r.midY - 8, width: 1, height: 16).fill()
        }

        for (i, item) in items.enumerated() {
            let r = tabRect(i)
            let isActive = item.id == active
            let isPressed = dragging && item.id == pressedID
            let shape = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

            if isActive {
                ink.withAlphaComponent(0.09).setFill()
                shape.fill()
                let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 6.75, yRadius: 6.75)
                edge.lineWidth = 0.5
                ink.withAlphaComponent(0.13).setStroke()
                edge.stroke()
            } else if hovered == i && !dragging {
                ink.withAlphaComponent(0.06).setFill()
                shape.fill()
            }
            if isPressed && torn { continue }   // the chip under the pointer carries it
            if isPressed {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                shape.fill()
            }

            let showClose = hovered == i && !dragging
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(isActive ? 1 : 0.68),
                .paragraphStyle: para,
            ]
            // Ghostty's shortcut hint on the right; ✕ on the left on hover.
            var room = r.insetBy(dx: 8, dy: 0)
            if showClose { room.origin.x += 18; room.size.width -= 18 }
            if let hint = shortcut(i) {
                let hintAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: ink.withAlphaComponent(isActive ? 0.6 : 0.48),
                ]
                let w = (hint as NSString).size(withAttributes: hintAttrs).width
                if room.width > w + 60 {
                    (hint as NSString).draw(at: NSPoint(x: room.maxX - w, y: r.midY - 8), withAttributes: hintAttrs)
                    room.size.width -= w + 6
                }
            }
            // Centre icon + title; the title truncates once the tab is too narrow.
            let iconSize: CGFloat = 16, spacing: CGFloat = 7
            let titleW = min((item.title as NSString).size(withAttributes: attrs).width,
                             max(0, room.width - iconSize - spacing))
            let x = min(max(room.minX, r.midX - (iconSize + spacing + titleW) / 2),
                        room.maxX - iconSize - spacing - titleW)
            item.icon?.draw(in: NSRect(x: x, y: r.midY - iconSize / 2, width: iconSize, height: iconSize))
            (item.title as NSString).draw(with: NSRect(x: x + iconSize + spacing, y: r.midY - 8, width: titleW, height: 16),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: attrs)
            if showClose {
                let x: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: ink.withAlphaComponent(0.6),
                ]
                ("✕" as NSString).draw(in: closeRect(i).insetBy(dx: 2, dy: 0), withAttributes: x)
            }
        }
    }

    /// Switch key + 1…8, and + 9 for the last tab (see `DragController.switchTab`).
    private func shortcut(_ i: Int) -> String? {
        let key = SwitchKey.current.symbol
        return !hints ? nil : i < 8 ? "\(key)\(i + 1)" : i == items.count - 1 ? "\(key)9" : nil
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: convert(event.locationInWindow, from: nil))
        if h != hovered { hovered = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return }
        pressedID = items[i].id
        pressPoint = p
        dragging = false
        torn = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = pressedID, let from = items.firstIndex(where: { $0.id == id }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 4 else { return }
            dragging = true
        }
        // Far enough off the strip and it tears; bring it back and it re-docks.
        torn = !bounds.insetBy(dx: -tearDistance, dy: -tearDistance).contains(p)
        if torn {
            chip.show(items[from], at: NSEvent.mouseLocation)
        } else {
            chip.hide()
            let to = slot(forX: p.x)
            if to != from {
                let item = items.remove(at: from)
                items.insert(item, at: to)
            }
        }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            let item = menu.addItem(withTitle: L10n.text("tabs.remove_from_group", fallback: "Remove from Group"),
                                    action: #selector(removeFromGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = items[i].id
        }
        menu.addItem(withTitle: L10n.text("tabs.ungroup_all", fallback: "Ungroup All"),
                     action: #selector(ungroupAll), keyEquivalent: "").target = self
        return menu
    }

    @objc private func removeFromGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID, let owner else { return }
        owner.stripDelegate?.tabStrip(owner, didTearOff: id, at: nil)
    }

    @objc private func ungroupAll() {
        guard let owner else { return }
        owner.stripDelegate?.tabStripUngroupAll(owner)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging, wasTorn = torn
        defer {
            pressedID = nil
            dragging = false
            torn = false
            chip.hide()
            needsDisplay = true
        }
        guard let id = pressedID, let owner, let delegate = owner.stripDelegate else { return }
        let p = convert(event.locationInWindow, from: nil)

        if !wasDragging {
            if let i = items.firstIndex(where: { $0.id == id }), closeRect(i).contains(p) {
                delegate.tabStrip(owner, didClose: id)
            } else {
                delegate.tabStrip(owner, didSelect: id)
            }
        } else if wasTorn {
            delegate.tabStrip(owner, didTearOff: id, at: Coords.cursor())
        } else if let i = items.firstIndex(where: { $0.id == id }) {
            delegate.tabStrip(owner, didMove: id, to: i)
        }
    }
}

/// The non-interactive part of a group's shell. The transparent centre leaves
/// the wrapped app window fully visible and clickable.
@MainActor
private final class GroupShellPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .transient]
        animationBehavior = .none
        contentView = GroupShellView()
    }
}

private final class GroupShellView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Style.cornerRadius,
                                 yRadius: Style.cornerRadius)
        let innerRect = NSRect(x: Style.shellWidth,
                               y: Style.shellWidth,
                               width: max(0, bounds.width - Style.shellWidth * 2),
                               height: max(0, bounds.height - Style.stripHeight - Style.shellWidth))
        let inner = NSBezierPath(roundedRect: innerRect,
                                 xRadius: max(0, Style.cornerRadius - Style.shellWidth),
                                 yRadius: max(0, Style.cornerRadius - Style.shellWidth))
        outer.append(inner)
        outer.windingRule = .evenOdd

        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        outer.fill()
    }
}

/// "A dragged tab is always a chip": the tab follows the pointer once torn off.
@MainActor
final class TabChip {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        fx.material = .popover
        fx.state = .active
        fx.maskImage = .roundedMask(radius: 8)
        icon.frame = NSRect(x: 8, y: 7, width: 16, height: 16)
        label.frame = NSRect(x: 30, y: 7, width: 162, height: 16)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12, weight: .medium)
        fx.addSubview(icon)
        fx.addSubview(label)
        panel.contentView = fx
    }

    func show(_ item: TabItem, at screenPoint: NSPoint) {
        icon.image = item.icon
        label.stringValue = item.title
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - 100, y: screenPoint.y - 40))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }
}

extension NSImage {
    /// A stretchable mask that rounds an NSVisualEffectView's corners
    /// (layer.cornerRadius doesn't clip behind-window blur).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    static func topRoundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath.topRoundedRect(rect, radius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: 0, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private extension NSBezierPath {
    static func topRoundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let r = min(max(0, radius), min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                       radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                       radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }
}
