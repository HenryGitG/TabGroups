# TabGroups — handoff notes

Goal: re-implement TrellisWM's "Tab groups" feature (https://trelliswm.app) as a native
macOS background app (no Dock icon, no menu-bar item) in Swift: drop a window on the middle of another (from any app) and
pause → they stack under one strip of tabs; click a tab to switch; drag a tab out to tear
it off. Code comments in English; the user prefers to talk in Chinese.

## Status

- Builds cleanly (Swift 6.4 toolchain, no warnings). Basic loop verified with synthetic
  mouse events: group (incl. cross-app, 3 tabs) → switch → tear off → quit restores.
- Known: Finder clamps parked windows (~20 px stay visible instead of 1).
- Known: switching tabs sometimes darkens the shadow for 1–2 frames. The two AX position
  writes return in <2 ms but the app applies them in different frames (measured with
  `screencapture -v`); old-out-first shows the background instead, which is worse. The only
  fix found is stacking hidden tabs behind the shown one; the user chose to keep parking.
- Known: parked windows show in Mission Control and fly back to the corner on exit.
  TrellisWM's answer is "Park windows out of view small" (shrink when parked; blurry for a
  moment when shown again). Tried it; the user prefers parked windows to keep their size.
- Swift tools 5.9 (Swift 5 language mode), macOS 14+, no sandbox (Accessibility API
  doesn't work sandboxed). All app classes are `@MainActor`; C callbacks / timers / event
  monitors hop in with `MainActor.assumeIsolated`.
- Run: `swift run` (the Accessibility grant goes to Terminal) or `./make-app.sh &&
  open build/TabGroups.app` (ad-hoc signed; the grant may reset after each rebuild).

## Architecture

| File | Role |
|---|---|
| `AX.swift` | AX helpers, private `_AXUIElementGetWindow` (via `@_silgen_name`), `Coords` (AX top-left ↔ AppKit bottom-left) |
| `WindowTracker.swift` | One `AXObserver` per regular app; `[CGWindowID: Win]`; `topWindow(at:excluding:)` via `CGWindowListCopyWindowInfo` z-order |
| `DragController.swift` | `NSEvent` global monitors; detects a title-bar drag via WindowServer bounds (`Win.serverFrame`; AX position lags mid-drag) and moves the strip with that frame (`GroupManager.dragMoved`); middle zone = target inset 25%; dwell 0.35 s / slop 12 px → `DropHighlight`; mouse-up → `GroupManager.join` |
| `GroupManager.swift` | `TabGroup` model (frame includes the 34 px strip). select = set the frame + raise the shown tab, **park** the others (move to the bottom-right corner, 1 px visible, same size). Follows the shown tab when the user moves/resizes it (strip follows live). Ignores our own AX writes for 0.5 s. Ungroups everything on quit. |
| `TabStrip.swift` | `TabStripPanel`: borderless non-activating `NSPanel`, `.normal` level, `order(.above, relativeTo: activeWindowID)`. `TabStripView`: draw, hover ✕, drag to reorder, drag beyond 24 px → torn (`TabChip` follows the pointer) |
| `App.swift` | `@main`, `LoginItem` (launch at login via `SMAppService.mainApp`, app bundle only; toggled from the strip's context menu), AX permission prompt + polling, SIGINT/SIGTERM → terminate (so windows get restored) |

## Next steps (suggested order)

1. ~~Compile, run, check the basic loop~~: done.
2. ~~Strip z-order~~: done — re-ordered (with delays) on focus change and on app activation.
3. Group-level controls on the strip (close / minimise the whole group), as TrellisWM has.
4. Skip or handle windows with native tabs (`AXTabGroup` child), full-screen windows, sheets.
5. Persist groups (bundle ID + title matching) and restore them on launch.
6. Optional: ScreenCaptureKit thumbnail of the tab under the pointer while it's being dragged.

Never leave windows parked: every exit path must call `GroupManager.ungroupAll()`.
