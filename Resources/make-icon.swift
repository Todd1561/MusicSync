// Draws the app icon (a music note inside sync arrows) as a 1024x1024 PNG.
// Usage: swift Resources/make-icon.swift <output.png>   (build.sh turns it into AppIcon.icns)
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Standard macOS icon shape: rounded square inset from the canvas, with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.36, blue: 0.45, alpha: 1),
           ending: NSColor(srgbRed: 0.55, green: 0.20, blue: 0.85, alpha: 1))!
    .draw(in: shape, angle: -90)

func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat, dy: CGFloat = 0) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let s = image.size
    image.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2 + dy,
                          width: s.width, height: s.height))
}

drawSymbol("arrow.triangle.2.circlepath", pointSize: 560, weight: .medium, alpha: 0.9)
drawSymbol("music.note", pointSize: 250, weight: .bold, alpha: 1)

NSGraphicsContext.current = nil
try rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
