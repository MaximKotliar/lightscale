// Draws the app icon (1024x1024 PNG): two offset frames with a sparkle between them,
// on a blue-violet rounded square. Usage: swift scripts/make-icon.swift OUT.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824pt body centered in 1024 with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.47, green: 0.22, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: -55)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Two frames, the second offset: "the frame in between".
    func frame(_ rect: NSRect, alpha: CGFloat) {
        let p = NSBezierPath(roundedRect: rect, xRadius: 52, yRadius: 52)
        NSColor.white.withAlphaComponent(alpha * 0.18).setFill()
        p.fill()
        NSColor.white.withAlphaComponent(alpha).setStroke()
        p.lineWidth = 22
        p.stroke()
    }
    frame(NSRect(x: 230, y: 330, width: 420, height: 300), alpha: 0.45)
    frame(NSRect(x: 374, y: 394, width: 420, height: 300), alpha: 0.95)

    // Sparkle.
    let config = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
    if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sparkle.size, flipped: false) { r in
            sparkle.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: 584 - tinted.size.width / 2, y: 544 - tinted.size.height / 2,
                               width: tinted.size.width, height: tinted.size.height))
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
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
