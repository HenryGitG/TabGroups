import AppKit

/// Held down, it turns a press anywhere in a window into a window drag, and
/// only while it's held does a drag make a group.
enum DragKey: String, CaseIterable {
    case command, option, control, fn

    static var current: DragKey {
        get { UserDefaults.standard.string(forKey: "dragKey").flatMap(DragKey.init) ?? .command }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dragKey") }
    }

    static var isDown: Bool { CGEventSource.flagsState(.combinedSessionState).contains(current.flag) }

    var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        case .fn: .maskSecondaryFn
        }
    }

    var title: String {
        switch self {
        case .command: "⌘ Command"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .fn: "fn"
        }
    }
}

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

    private var tap: CFMachPort?
    /// Pointer offset into the window being moved with the drag key.
    private var grab: CGPoint?
    private var pressPoint: CGPoint = .zero
    /// The swallowed press, replayed if it turns out to be a plain click.
    private var pressed: CGEvent?
    fileprivate static let replayTag: Int64 = 0x7461_6267   // "tabg"

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

        // Presses with the drag key go through an active tap instead: the
        // app under the pointer must not see them. (Swallowed events never
        // reach the monitors above.)
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: tapCallback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { NSLog("TabGroups: couldn't create the event tap"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// Returns false to swallow the event.
    fileprivate func handleTap(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return true }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown:
            return !keyDown(event)
        case .leftMouseDragged:
            guard grab != nil else { return true }
            keyDragged(event.location)
            return false
        case .leftMouseUp:
            guard grab != nil else { return true }
            let window = source
            let doubleClick = pressed?.getIntegerValueField(.mouseEventClickState) == 2
            let click = pressed.flatMap { down in event.copy().map { [down, $0] } }
            mouseUp()
            if doubleClick, let window { titleBarDoubleClick(window); return false }
            for e in click ?? [] {
                e.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
                e.post(tap: .cgSessionEventTap)
            }
            return false
        default:
            return true
        }
    }

    /// A press with the drag key on a tracked window: we'll move it ourselves.
    private func keyDown(_ event: CGEvent) -> Bool {
        guard event.flags.contains(DragKey.current.flag) else { return false }
        let p = event.location
        // Our own strips and windows handle their own clicks.
        let n = NSWindow.windowNumber(at: NSPoint(x: p.x, y: Coords.primaryHeight - p.y),
                                      belowWindowWithWindowNumber: 0)
        guard NSApp.window(withWindowNumber: n) == nil,
              let w = tracker.topWindow(at: p), let f = w.frame else { return false }
        reset()
        source = w
        sourceStart = f
        grab = CGPoint(x: p.x - f.minX, y: p.y - f.minY)
        pressPoint = p
        pressed = event.copy()
        return true
    }

    private func keyDragged(_ p: CGPoint) {
        guard let w = source, let start = sourceStart, let grab else { return }
        if !moving {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 3 else { return }   // still a click
            pressed = nil
            w.raise()
            startMoving()
        }
        let origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
        AX.withoutEnhancedUI(w.appElement) { AX.setPosition(w.element, origin) }
        groups.dragMoved(w.id, frame: CGRect(origin: origin, size: start.size))
        evaluate()
    }

    /// Whatever double-clicking the title bar does
    /// (System Settings ▸ Desktop & Dock).
    private func titleBarDoubleClick(_ w: Win) {
        let d = UserDefaults.standard
        let action = d.string(forKey: "AppleActionOnDoubleClick")
            ?? (d.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": AX.set(w.element, kAXMinimizedAttribute, kCFBooleanTrue)
        case "None": break
        // ponytail: "Fill" zooms too (most apps zoom to the whole screen anyway);
        // set the frame to the visible frame if that falls short.
        default:
            // Option-click on the green button. Reports an error but zooms.
            if let b = AX.element(w.element, kAXZoomButtonAttribute) { AX.perform(b, "AXZoomWindow") }
        }
    }

    private func startMoving() {
        moving = true
        // Keep evaluating while the pointer rests: no drag events arrive then.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
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
            startMoving()
        }
        if let f = w.serverFrame { groups.dragMoved(w.id, frame: f) }
        evaluate()
    }

    private func mouseUp() {
        let go = moving && armed && DragKey.isDown
        let src: Win? = go ? source : nil
        let dst: Win? = go ? target : nil
        reset()
        guard let src, let dst else { return }
        // Let the WindowServer finish its own drag first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.groups.join(src, onto: dst) }
        }
    }

    private func evaluate() {
        guard moving, let src = source else { return }
        guard DragKey.isDown else { disarm(); return }
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
        grab = nil
        pressed = nil
        moving = false
        disarm()
    }
}

/// C trampoline for the event tap, which runs on the main run loop.
private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let drags = Unmanaged<DragController>.fromOpaque(refcon).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { drags.handleTap(type, event) }
    return pass ? Unmanaged.passUnretained(event) : nil
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
