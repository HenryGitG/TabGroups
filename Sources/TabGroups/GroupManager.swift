import AppKit

enum Style {
    static let stripHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 10
}

/// Several windows (from any apps) sharing one frame under one strip.
/// Only `active` is on screen; the rest are parked out of view.
@MainActor
final class TabGroup {
    var tabs: [CGWindowID]
    var active: CGWindowID
    /// The whole group, strip included, in AX coordinates.
    var frame: CGRect
    let strip: TabStripPanel

    init(tabs: [CGWindowID], active: CGWindowID, frame: CGRect, strip: TabStripPanel) {
        self.tabs = tabs
        self.active = active
        self.frame = frame
        self.strip = strip
    }

    var stripFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Style.stripHeight)
    }

    var windowFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY + Style.stripHeight,
               width: frame.width, height: max(0, frame.height - Style.stripHeight))
    }
}

@MainActor
final class GroupManager {
    private let tracker: WindowTracker
    private(set) var groups: [TabGroup] = []

    /// Our own AX writes come back as Moved/Resized notifications; ignore those.
    private var ignoreUntil: [CGWindowID: Date] = [:]
    /// Each window's size before it joined, so a torn-off tab gets it back.
    private var sizeBeforeGrouping: [CGWindowID: CGSize] = [:]
    private var settle: DispatchWorkItem?
    private var tileDone: DispatchWorkItem?
    private var refitUntil: Date?
    /// The shown tab being dragged by its title bar; its strip follows the pointer.
    private var liveDrag: CGWindowID?
    /// Since the last settle, the shown tab's size changed while a mouse
    /// button was held: the user is resizing it, not the system.
    private var userResized = false

    init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    func group(of id: CGWindowID) -> TabGroup? {
        groups.first { $0.tabs.contains(id) }
    }

    func group(atStrip p: CGPoint) -> TabGroup? {
        groups.first { $0.strip.isVisible && $0.stripFrame.contains(p) }
    }

    // MARK: Making and changing groups

    /// Drop `source` (or its whole group) onto `target` (or its group).
    func join(_ source: Win, onto target: Win) {
        guard source.id != target.id else { return }

        var incoming = [source.id]
        if let old = group(of: source.id) {
            if old === group(of: target.id) { return }
            incoming = old.tabs
            discard(old)
        } else if let f = source.frame {
            sizeBeforeGrouping[source.id] = f.size
        }

        let g: TabGroup
        if let existing = group(of: target.id) {
            g = existing
        } else {
            guard let f = target.frame else { return }
            sizeBeforeGrouping[target.id] = f.size
            let strip = TabStripPanel()
            strip.stripDelegate = self
            g = TabGroup(tabs: [target.id], active: target.id, frame: f, strip: strip)
            groups.append(g)
        }

        let insertAt = (g.tabs.firstIndex(of: g.active) ?? g.tabs.count - 1) + 1
        g.tabs.insert(contentsOf: incoming.filter { !g.tabs.contains($0) }, at: insertAt)
        select(source.id, in: g)
    }

    func select(_ id: CGWindowID, in g: TabGroup) {
        guard let w = tracker.windows[id] else { return }
        g.active = id
        // Resize while still parked, out of sight.
        if let f = w.frame, f.size != g.windowFrame.size {
            place(w, CGRect(origin: f.origin, size: g.windowFrame.size))
        }
        // While two windows share the spot their shadows stack and the edges
        // visibly darken: swap them with nothing else in between.
        let spot = parkSpot(in: g)
        let others = g.tabs.filter { $0 != id }.compactMap { tracker.windows[$0] }
        moveTogether([(w, g.windowFrame.origin)] + others.map { ($0, spot) })
        // A window that wasn't parked (just dropped on the group) had its size
        // clamped to the screen where it was: size it again now it's in place.
        if let f = w.frame, f.size != g.windowFrame.size { place(w, g.windowFrame) }
        w.raise()
        layout(g)
        reorderStrip(g)
    }

    /// The raise lands asynchronously in the other app: re-assert the
    /// strip's z-order once it has.
    private func reorderStrip(_ g: TabGroup) {
        g.strip.order(.above, relativeTo: Int(g.active))
        for delay in [0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak g] in
                MainActor.assumeIsolated {
                    guard let self, let g, self.groups.contains(where: { $0 === g }) else { return }
                    g.strip.order(.above, relativeTo: Int(g.active))
                }
            }
        }
    }

    /// Take a tab out of its group at its old size: under the pointer when
    /// dropped at `p`, otherwise cascaded off the group's corner.
    func tearOff(_ id: CGWindowID, at p: CGPoint?) {
        guard let g = group(of: id), let w = tracker.windows[id] else { return }
        let size = sizeBeforeGrouping.removeValue(forKey: id) ?? g.windowFrame.size
        let origin = p.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - 12) }
            ?? CGPoint(x: g.frame.minX + 28, y: g.frame.minY + 28)
        remove(id, from: g)
        place(w, CGRect(origin: origin, size: size))
        w.raise()
    }

    /// Put every window back on screen. Must run before we quit, or parked
    /// windows stay stranded in the screen corner.
    func ungroupAll() {
        for g in groups { dissolve(g) }
    }

    private func remove(_ id: CGWindowID, from g: TabGroup) {
        guard let i = g.tabs.firstIndex(of: id) else { return }
        g.tabs.remove(at: i)
        if g.tabs.count < 2 { dissolve(g); return }
        if g.active == id {
            select(g.tabs[min(i, g.tabs.count - 1)], in: g)
        } else {
            refreshTabs(g)
        }
    }

    /// End a group: the last window takes the whole space, strip included;
    /// if several are left (ungroup all / quit) they cascade.
    private func dissolve(_ g: TabGroup) {
        discard(g)
        let order = g.tabs.filter { $0 == g.active } + g.tabs.filter { $0 != g.active }
        for (n, id) in order.enumerated() {
            guard let w = tracker.windows[id] else { continue }
            let step = CGFloat(n) * 28
            place(w, g.frame.offsetBy(dx: step, dy: step))
        }
    }

    private func discard(_ g: TabGroup) {
        groups.removeAll { $0 === g }
        g.strip.orderOut(nil)
    }

    // MARK: Placement

    private func place(_ w: Win, _ r: CGRect) {
        ignore(w.id)
        w.setFrame(r)
    }

    /// "Park" = move a window so only one pixel is left on screen, in a
    /// corner with no neighbouring display. Same trick as AeroSpace, and what
    /// TrellisWM's "Park windows out of view" setting refers to. Unlike
    /// minimising or hiding the app it has no animation, keeps the app's
    /// other windows alone, and the window stays live.
    private func parkSpot(in g: TabGroup) -> CGPoint {
        let size = g.windowFrame.size
        let screen = Coords.screenFrame(containing: g.frame)
        let others = Coords.screenFrames().filter { $0 != screen }
        let corners = [
            CGPoint(x: screen.maxX - 1, y: screen.maxY - 1),                // bottom-right
            CGPoint(x: screen.minX - size.width + 1, y: screen.maxY - 1),   // bottom-left
        ]
        return corners.first { c in
            !others.contains { $0.intersects(CGRect(origin: c, size: size)) }
        } ?? corners[0]
    }

    /// Back-to-back position writes; AXEnhancedUserInterface (see
    /// `AX.withoutEnhancedUI`) is switched off around all of them, not each.
    private func moveTogether(_ moves: [(Win, CGPoint)]) {
        var enhanced: [AXUIElement] = []
        for (w, _) in moves where !enhanced.contains(where: { CFEqual($0, w.appElement) })
            && AX.bool(w.appElement, "AXEnhancedUserInterface") == true {
            AX.set(w.appElement, "AXEnhancedUserInterface", kCFBooleanFalse)
            enhanced.append(w.appElement)
        }
        for (w, p) in moves {
            ignore(w.id)
            AX.setPosition(w.element, p)
        }
        for app in enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    private func ignore(_ id: CGWindowID) {
        ignoreUntil[id] = Date().addingTimeInterval(0.5)
    }

    /// Keep the strip on top of the window, below the menu bar, and in front.
    private func layout(_ g: TabGroup) {
        let visible = Coords.visibleFrame(containing: g.frame)
        if g.frame.minY < visible.minY {
            g.frame.origin.y = visible.minY
            if let w = tracker.windows[g.active] { place(w, g.windowFrame) }
        }
        refreshTabs(g)
        g.strip.show(at: g.stripFrame, above: g.active)
    }

    private func refreshTabs(_ g: TabGroup) {
        let items = g.tabs.compactMap { id in
            tracker.windows[id].map { TabItem(id: id, title: $0.title, icon: $0.icon) }
        }
        g.strip.update(items: items, active: g.active)
    }

    /// The user moved or resized the shown tab: the group follows it.
    /// The strip tracks the window live; the full layout (screen clamp,
    /// z-order) waits until the mouse is released.
    private func follow(_ w: Win) {
        // Right after a tile is fitted, the system puts the window back over
        // the strip once (to exactly the tile); only a second write sticks.
        if let until = refitUntil, until > Date(), let g = group(of: w.id), g.active == w.id,
           w.frame == g.frame {
            place(w, g.windowFrame)
            return
        }
        if let until = ignoreUntil[w.id], until > Date() { return }
        guard w.id != liveDrag, let g = group(of: w.id), g.active == w.id, let f = w.frame else { return }
        if f.size != g.windowFrame.size {
            if NSEvent.pressedMouseButtons & 1 != 0 { userResized = true }
            else if !userResized { followTile(g, w, f); return }
        }
        fit(g, to: f)
        g.strip.setFrame(Coords.toAppKit(g.stripFrame), display: true)
        scheduleSettle(g)
    }

    private func fit(_ g: TabGroup, to f: CGRect) {
        g.frame = CGRect(x: f.minX, y: f.minY - Style.stripHeight,
                         width: f.width, height: f.height + Style.stripHeight)
    }

    /// Title-bar drag of a shown tab, with the WindowServer's frame: the
    /// app's kAXMoved notifications are coalesced during a drag. (Dragging a
    /// tile out also restores its old size here.)
    func dragMoved(_ id: CGWindowID, frame f: CGRect) {
        guard let g = group(of: id), g.active == id else { return }
        liveDrag = id
        fit(g, to: f)
        g.strip.setFrame(Coords.toAppKit(g.stripFrame), display: true)
        scheduleSettle(g)
    }

    func dragEnded() { liveDrag = nil }

    /// The system is sizing the shown tab: edge tiling (it animates, a dozen
    /// notifications over ~0.3 s), Fill, a shortcut. Its frame is the space
    /// for the whole group: the strip rides the top edge, and once the frame
    /// holds still the window makes room for it. (Writing mid-animation would
    /// be undone by the animation's later frames.)
    private func followTile(_ g: TabGroup, _ w: Win, _ f: CGRect) {
        settle?.cancel()
        g.frame = f
        g.strip.setFrame(Coords.toAppKit(g.stripFrame), display: true)
        tileDone?.cancel()
        let work = DispatchWorkItem { [weak self, weak g] in
            MainActor.assumeIsolated {
                guard let self, let g, g.active == w.id, self.groups.contains(where: { $0 === g }) else { return }
                self.userResized = false
                self.place(w, g.windowFrame)
                self.refitUntil = Date().addingTimeInterval(1)
                self.layout(g)
            }
        }
        tileDone = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func scheduleSettle(_ g: TabGroup) {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self, weak g] in
            MainActor.assumeIsolated {
                guard let self, let g, self.groups.contains(where: { $0 === g }) else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleSettle(g); return } // still dragging
                if let w = self.tracker.windows[g.active], let f = w.frame {
                    // A tile on releasing a title-bar drag: follow skipped it.
                    if !self.userResized && f.size != g.windowFrame.size { self.followTile(g, w, f); return }
                    self.fit(g, to: f)   // the pointer only approximated it (menu-bar clamp)
                }
                self.userResized = false
                self.layout(g)
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: - Window events

extension GroupManager: WindowTrackerDelegate {
    func windowMoved(_ w: Win) { follow(w) }
    func windowResized(_ w: Win) { follow(w) }

    func windowDestroyed(_ id: CGWindowID) {
        sizeBeforeGrouping[id] = nil
        if let g = group(of: id) { remove(id, from: g) }
    }

    func windowTitleChanged(_ w: Win) {
        if let g = group(of: w.id) { refreshTabs(g) }
    }

    func windowFocused(_ w: Win) {
        guard let g = group(of: w.id) else { return }
        if g.active == w.id {
            reorderStrip(g)
        } else {
            // ⌘` or the app itself brought a parked tab forward: switch to it.
            select(w.id, in: g)
        }
    }

    func windowMinimized(_ w: Win) {
        // Prototype choice: a minimised tab leaves its group.
        // (TrellisWM minimises the whole group from the strip instead.)
        if let g = group(of: w.id) { remove(w.id, from: g) }
    }
}

// MARK: - Strip events

extension GroupManager: TabStripDelegate {
    private func group(for strip: TabStripPanel) -> TabGroup? {
        groups.first { $0.strip === strip }
    }

    func tabStrip(_ strip: TabStripPanel, didSelect id: CGWindowID) {
        if let g = group(for: strip) { select(id, in: g) }
    }

    func tabStrip(_ strip: TabStripPanel, didClose id: CGWindowID) {
        guard let g = group(for: strip), let w = tracker.windows[id] else { return }
        // Show it first: a "Save changes?" sheet on a parked window would be invisible.
        if g.active != id { select(id, in: g) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { w.close() }
        }
    }

    func tabStrip(_ strip: TabStripPanel, didMove id: CGWindowID, to index: Int) {
        guard let g = group(for: strip), let from = g.tabs.firstIndex(of: id) else { return }
        g.tabs.remove(at: from)
        g.tabs.insert(id, at: min(index, g.tabs.count))
        refreshTabs(g)
    }

    func tabStrip(_ strip: TabStripPanel, didTearOff id: CGWindowID, at point: CGPoint?) {
        tearOff(id, at: point)
    }

    func tabStripUngroupAll(_ strip: TabStripPanel) { ungroupAll() }
}
