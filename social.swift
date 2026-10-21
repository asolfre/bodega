// One-off: composes docs/social-preview.png (1280x640), then upload it under the repo's Settings → Social preview.
// Regenerate:
//   swift icon.swift /tmp/src.png && swift social.swift /tmp/src.png docs/screenshot.png docs/social-preview.png
import AppKit

let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!
let shot = NSImage(contentsOfFile: args[2])!
let size = NSSize(width: 1280, height: 640)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
NSGradient(starting: color(246, 232, 210), ending: color(226, 204, 172))!
    .draw(in: NSRect(origin: .zero, size: size), angle: 90)

// Left column: icon, name, tagline.
icon.draw(in: NSRect(x: 40, y: 300, width: 260, height: 260))
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 76, weight: .bold),
                                            .foregroundColor: color(80, 48, 24)]
NSAttributedString(string: "Bodega", attributes: title).draw(at: NSPoint(x: 64, y: 196))
let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 25, weight: .medium),
                                          .foregroundColor: color(110, 66, 34)]
for (i, line) in ["Native macOS Homebrew GUI", "SwiftUI · formulae & casks", "No Electron"].enumerated() {
    NSAttributedString(string: line, attributes: tag).draw(at: NSPoint(x: 66, y: 150 - Double(i) * 36))
}

// Right column: the app window, scaled to fit, with a soft shadow.
let maxW = 780.0, maxH = 560.0
let scale = min(maxW / shot.size.width, maxH / shot.size.height)
let w = shot.size.width * scale, h = shot.size.height * scale
let frame = NSRect(x: 1280 - 40 - w, y: (640 - h) / 2, width: w, height: h)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
NSGraphicsContext.restoreGraphicsState()
NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
shot.draw(in: frame)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
