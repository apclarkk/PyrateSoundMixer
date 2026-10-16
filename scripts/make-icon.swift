// Draws the placeholder app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: 824 pt body centered in 1024 with a continuous-corner squircle.
    let body = rect.insetBy(dx: 100, dy: 100)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.05, green: 0.42, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.02, green: 0.20, blue: 0.26, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // Speaker.
    NSColor.white.setFill()
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: 300, y: 440))
    speaker.line(to: NSPoint(x: 390, y: 440))
    speaker.line(to: NSPoint(x: 520, y: 330))
    speaker.line(to: NSPoint(x: 520, y: 694))
    speaker.line(to: NSPoint(x: 390, y: 584))
    speaker.line(to: NSPoint(x: 300, y: 584))
    speaker.close()
    speaker.fill()

    // Three sound waves, the last one in the accent color.
    let center = NSPoint(x: 520, y: 512)
    for (i, radius) in [90.0, 170.0, 250.0].enumerated() {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: center, radius: radius, startAngle: -38, endAngle: 38)
        wave.lineWidth = 44
        wave.lineCapStyle = .round
        (i == 2 ? NSColor(srgbRed: 0.36, green: 0.86, blue: 0.80, alpha: 1) : NSColor.white).setStroke()
        wave.stroke()
    }
    return true
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
