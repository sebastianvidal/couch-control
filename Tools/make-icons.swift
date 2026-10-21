// Renders the app icon: a cursor over a trackpad on a blue-violet gradient.
// Usage: swift Tools/make-icons.swift <output-dir>
// Writes icon-1024.png (iOS, square) and AppIcon.iconset/ (macOS, rounded) into output-dir.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default

func render(size: CGFloat, rounded: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS icons carry their own rounded mask and a little transparent margin.
    let inset = rounded ? size * 0.06 : 0
    let bg = rect.insetBy(dx: inset, dy: inset)
    let path = rounded
        ? NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.225, yRadius: bg.width * 0.225)
        : NSBezierPath(rect: bg)
    path.addClip()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.25, green: 0.30, blue: 0.95, alpha: 1),
        NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -60)

    // Trackpad slab.
    let padW = bg.width * 0.62, padH = bg.height * 0.46
    let pad = NSRect(x: bg.midX - padW / 2, y: bg.midY - padH / 2 - bg.height * 0.04, width: padW, height: padH)
    NSColor(white: 1, alpha: 0.18).setFill()
    NSBezierPath(roundedRect: pad, xRadius: padW * 0.08, yRadius: padW * 0.08).fill()
    NSColor(white: 1, alpha: 0.35).setStroke()
    let outline = NSBezierPath(roundedRect: pad, xRadius: padW * 0.08, yRadius: padW * 0.08)
    outline.lineWidth = size * 0.012
    outline.stroke()

    // Cursor arrow.
    let s = bg.width * 0.30
    let ox = bg.midX - s * 0.25, oy = bg.midY + s * 0.55
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: ox, y: oy))
    cursor.line(to: NSPoint(x: ox, y: oy - s))
    cursor.line(to: NSPoint(x: ox + s * 0.27, y: oy - s * 0.74))
    cursor.line(to: NSPoint(x: ox + s * 0.45, y: oy - s * 1.1))
    cursor.line(to: NSPoint(x: ox + s * 0.62, y: oy - s * 1.02))
    cursor.line(to: NSPoint(x: ox + s * 0.45, y: oy - s * 0.66))
    cursor.line(to: NSPoint(x: ox + s * 0.78, y: oy - s * 0.66))
    cursor.close()
    NSColor.black.withAlphaComponent(0.25).setFill()
    cursor.transform(using: AffineTransform(translationByX: size * 0.012, byY: -size * 0.012))
    cursor.fill()
    cursor.transform(using: AffineTransform(translationByX: -size * 0.012, byY: size * 0.012))
    NSColor.white.setFill()
    cursor.fill()
    NSColor(white: 0.1, alpha: 0.6).setStroke()
    cursor.lineWidth = size * 0.012
    cursor.lineJoinStyle = .round
    cursor.stroke()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try png(render(size: 1024, rounded: false), pixels: 1024).write(to: URL(fileURLWithPath: "\(outDir)/icon-1024.png"))

let iconset = "\(outDir)/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(render(size: CGFloat(pixels), rounded: true), pixels: pixels).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
print("Wrote \(outDir)/icon-1024.png and \(iconset)")
