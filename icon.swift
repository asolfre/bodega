// One-off: draws the Bodega cask icon (Core Graphics only; Apple's terms forbid SF Symbols in app icons).
// Regenerate Resources/AppIcon.icns:
//   swift icon.swift /tmp/src.png && mkdir /tmp/AppIcon.iconset
//   for s in 16 32 128 256 512; do sips -z $s $s /tmp/src.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) /tmp/src.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png; done
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
//   sips -z 256 256 /tmp/src.png --out docs/icon.png  # README header
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

let frame = color(110, 66, 34), plank = color(176, 112, 60), seam = color(130, 80, 42)

// One cask seen end-on, centred at the origin with radius 150.
func drawCask() {
    let cask = NSRect(x: -150, y: -150, width: 300, height: 300)
    frame.setFill()  // chime: the ring of stave ends around the head
    NSBezierPath(ovalIn: cask).fill()

    // Head: three boards clipped to a circle, gaps showing the darker chime.
    let head = cask.insetBy(dx: 30, dy: 30), hr = head.width / 2
    let gap = 12.0, boardH = (head.height - 2 * gap) / 3
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: head).addClip()
    for i in 0..<3 {
        let b = NSRect(x: head.minX, y: head.minY + Double(i) * (boardH + gap), width: head.width, height: boardH)
        plank.setFill()
        NSBezierPath(rect: b).fill()
        let half = (hr * hr - b.midY * b.midY).squareRoot() - 34  // grain stays inside the circle
        seam.setStroke()
        let grain = NSBezierPath()
        grain.lineWidth = 5
        grain.move(to: NSPoint(x: -half, y: b.midY + 6))
        grain.curve(to: NSPoint(x: half, y: b.midY - 4),
                    controlPoint1: NSPoint(x: -half / 3, y: b.midY + 22),
                    controlPoint2: NSPoint(x: half / 3, y: b.midY - 22))
        grain.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    color(70, 42, 22).setFill()  // nails on the chime
    for a in stride(from: 45.0, to: 360, by: 90) {
        let p = NSPoint(x: 135 * cos(a * .pi / 180), y: 135 * sin(a * .pi / 180))
        NSBezierPath(ovalIn: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)).fill()
    }
}

// Five casks stacked like a bodega rack: three on the floor, two resting in the grooves above.
let r = 110.0, rise = r * 3.squareRoot()
let floorY = 512 - rise / 2
let spots = [-2.0, 0, 2].map { NSPoint(x: 512 + $0 * r, y: floorY) }
          + [-1.0, 1].map { NSPoint(x: 512 + $0 * r, y: floorY + rise) }
for c in spots {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: c.x, yBy: c.y)
    t.scale(by: r / 150)
    t.concat()
    drawCask()
    NSGraphicsContext.restoreGraphicsState()
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
