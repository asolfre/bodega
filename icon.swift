// One-off: draws the Bodega crate icon (Core Graphics only; Apple's terms forbid SF Symbols in app icons).
// Regenerate Resources/AppIcon.icns:
//   swift icon.swift /tmp/src.png && mkdir /tmp/AppIcon.iconset
//   for s in 16 32 128 256 512; do sips -z $s $s /tmp/src.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) /tmp/src.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png; done
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

func color(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// macOS icon grid: ~824 pt rounded square centred in 1024, corner radius ~185.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: color(246, 232, 210), ending: color(226, 204, 172))!.draw(in: tilePath, angle: 90)

// Crate body.
let crate = NSRect(x: 232, y: 262, width: 560, height: 500)
let frame = color(110, 66, 34), plank = color(176, 112, 60), seam = color(130, 80, 42)
frame.setFill()
NSBezierPath(roundedRect: crate, xRadius: 28, yRadius: 28).fill()

// Three horizontal planks inside the frame, with gaps showing the darker frame.
let inset = 46.0, gap = 18.0
let inner = crate.insetBy(dx: inset, dy: inset)
let plankH = (inner.height - 2 * gap) / 3
for i in 0..<3 {
    let r = NSRect(x: inner.minX, y: inner.minY + Double(i) * (plankH + gap), width: inner.width, height: plankH)
    plank.setFill()
    NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    seam.setStroke()  // wood grain
    let grain = NSBezierPath()
    grain.lineWidth = 5
    grain.move(to: NSPoint(x: r.minX + 40, y: r.midY + 8))
    grain.curve(to: NSPoint(x: r.maxX - 40, y: r.midY - 6),
                controlPoint1: NSPoint(x: r.midX - 60, y: r.midY + 30),
                controlPoint2: NSPoint(x: r.midX + 60, y: r.midY - 30))
    grain.stroke()
}

// Diagonal brace across the planks.
frame.setFill()
let brace = NSBezierPath()
brace.move(to: NSPoint(x: inner.minX, y: inner.minY + 20))
brace.line(to: NSPoint(x: inner.minX + 44, y: inner.minY))
brace.line(to: NSPoint(x: inner.maxX, y: inner.maxY - 20))
brace.line(to: NSPoint(x: inner.maxX - 44, y: inner.maxY))
brace.close()
brace.fill()

// Nails in the corners.
color(70, 42, 22).setFill()
for x in [crate.minX + 23, crate.maxX - 23] {
    for y in [crate.minY + 23, crate.maxY - 23] {
        NSBezierPath(ovalIn: NSRect(x: x - 9, y: y - 9, width: 18, height: 18)).fill()
    }
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
