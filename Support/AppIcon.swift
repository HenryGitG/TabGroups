// Draws the app icon. Regenerate Support/AppIcon.icns after changing it:
//   swift Support/AppIcon.swift /tmp/icon.png && ./Support/make-icns.sh /tmp/icon.png

import AppKit

// Renders the TabGroups app icon at 1024×1024: a stack of windows under one strip of tabs.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    // Body on Apple's macOS grid: 824 pt square, 100 pt margin, continuous corners.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowOffset = NSSize(width: 0, height: -12)
    drop.shadowBlurRadius = 28
    drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
    drop.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.40, green: 0.58, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.25, blue: 0.86, alpha: 1)])!
        .draw(in: squircle, angle: 90)   // flipped: 90° runs top → bottom

    // The group: a dark strip of tabs over a white window, centred; a second
    // window of the stack peeks out behind, up and to the right.
    let group = NSRect(x: 190, y: 304, width: 600, height: 460)
    let stripH: CGFloat = 96, gap: CGFloat = 14
    let strip = NSRect(x: group.minX, y: group.minY, width: group.width, height: stripH)
    let front = NSRect(x: group.minX, y: strip.maxY + gap, width: group.width, height: group.height - stripH - gap)

    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: group.offsetBy(dx: 44, dy: -44), xRadius: 46, yRadius: 46).fill()

    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowOffset = NSSize(width: 0, height: -10)
    lift.shadowBlurRadius = 30
    lift.shadowColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.3, alpha: 0.4)
    lift.set()
    NSColor(srgbRed: 0.14, green: 0.15, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: strip, xRadius: 30, yRadius: 30).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: front, xRadius: 46, yRadius: 46).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Three equal tabs, the first one shown.
    let inset: CGFloat = 14, tabGap: CGFloat = 12
    let tabW = (strip.width - inset * 2 - tabGap * 2) / 3
    for i in 0..<3 {
        let r = NSRect(x: strip.minX + inset + CGFloat(i) * (tabW + tabGap), y: strip.minY + inset,
                       width: tabW, height: stripH - inset * 2)
        NSColor.white.withAlphaComponent(i == 0 ? 0.95 : 0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
    }

    // Content lines in the shown window.
    NSColor(srgbRed: 0.33, green: 0.38, blue: 0.95, alpha: 0.16).setFill()
    for (i, w) in [400.0, 320, 360].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: front.minX + 48, y: front.minY + 52 + CGFloat(i) * 70, width: w, height: 34),
                     xRadius: 17, yRadius: 17).fill()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
