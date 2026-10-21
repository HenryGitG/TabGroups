import AppKit

/// Watches the user dragging other apps' windows by their title bars.
/// Drop one on the *middle* of another and hold still for a moment → they
/// become tabs of one group. (TrellisWM: "Drag a window onto the middle of
/// another and pause a moment.")
@MainActor
final class DragController {
    var holdDuration: TimeInterval = 0.35
    var holdSlop: CGFloat = 12
    var middleInset: CGFloat = 0.25         // outer 25% of each side is "edge", not "middle"

    private let tracker: WindowTracker
    private let groups: GroupManager
    private let highlight = DropHighlight()

    private var monitors: [Any] = []
    private var source: Win?
    private var sourceStart: CGRect?
    private var moving = false
    private var ticker: Timer?

    private var target: Win?
    private var targetZone: CGRect = .zero
    private var anchor: CGPoint = .zero
    private var since = Date.distantFuture
    private var armed = false

    init(tracker: WindowTracker, groups: GroupManager) {
        self.tracker = tracker
        self.groups = groups
    }

    func start() {
        // Global monitors see events going to other apps (not our own panels).
        // Rectangle uses the same approach for its snap areas; a CGEventTap
        // would also work.
        let watch: [(NSEvent.EventTypeMask, @MainActor (DragController) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown() }),
            (.leftMouseDragged, { $0.mouseDragged() }),
            (.leftMouseUp, { $0.mouseUp() }),
        ]
        for (mask, action) in watch {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }) {
                monitors.append(m)
            }
        }
    }

    private func mouseDown() {
        reset()
        guard let w = tracker.topWindow(at: Coords.cursor()) else { return }
        source = w
        sourceStart = w.serverFrame
    }

    private func mouseDragged() {
        guard let w = source, let start = sourceStart else { return }
        if !moving {
            // Is the window itself moving (a title-bar drag), not a text selection?
            guard let f = w.serverFrame, f.size == start.size, f.origin != start.origin else { return }
            moving = true
            // Keep evaluating while the pointer rests: no drag events arrive then.
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        if let f = w.serverFrame { groups.dragMoved(w.id, frame: f) }
        evaluate()
    }

    private func mouseUp() {
        let src: Win? = (moving && armed) ? source : nil
        let dst: Win? = (moving && armed) ? target : nil
        reset()
        guard let src, let dst else { return }
        // Let the WindowServer finish its own drag first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.groups.join(src, onto: dst) }
        }
    }

    private func evaluate() {
        guard moving, let src = source else { return }
        let p = Coords.cursor()
        let sourceTabs = Set(groups.group(of: src.id)?.tabs ?? [src.id])

        var candidate: Win?
        var zone: CGRect?
        if let g = groups.group(atStrip: p), !g.tabs.contains(src.id) {
            candidate = tracker.windows[g.active]
            zone = g.frame
        } else if let w = tracker.topWindow(at: p, excluding: sourceTabs) {
            candidate = w
            if let g = groups.group(of: w.id) {
                zone = g.frame
            } else {
                zone = (w.id == target?.id) ? targetZone : w.frame
            }
        }

        guard let c = candidate, let z = zone, !sourceTabs.contains(c.id),
              z.insetBy(dx: z.width * middleInset, dy: z.height * middleInset).contains(p)
        else { disarm(); return }

        if c.id != target?.id {
            target = c
            targetZone = z
            anchor = p
            since = Date()
            armed = false
            highlight.hide()
        }
        guard !armed else { return }
        if hypot(p.x - anchor.x, p.y - anchor.y) > holdSlop {
            anchor = p          // still travelling: restart the hold
            since = Date()
        } else if Date().timeIntervalSince(since) >= holdDuration {
            armed = true
            highlight.show(over: z)
        }
    }

    private func disarm() {
        target = nil
        armed = false
        highlight.hide()
    }

    private func reset() {
        groups.dragEnded()
        ticker?.invalidate()
        ticker = nil
        source = nil
        sourceStart = nil
        moving = false
        disarm()
    }
}

/// The "let go now and they'll be tabs" hint over the target.
@MainActor
final class DropHighlight {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating

        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 12

        let strip = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: Style.stripHeight))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        strip.layer?.cornerRadius = 9
        strip.autoresizingMask = [.width, .minYMargin]
        v.addSubview(strip)
        panel.contentView = v
    }

    func show(over axRect: CGRect) {
        let r = Coords.toAppKit(axRect.insetBy(dx: 6, dy: 6))
        panel.setFrame(r, display: false)
        if let strip = panel.contentView?.subviews.first {
            strip.frame = NSRect(x: 6, y: r.height - Style.stripHeight - 6,
                                 width: r.width - 12, height: Style.stripHeight)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
