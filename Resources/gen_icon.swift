// Generates Resources/AppIcon.icns — run via: swift Resources/gen_icon.swift
import AppKit

let canvas: CGFloat = 1024
let margin: CGFloat = 100
let rect = NSRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.16, alpha: 1),
    ending: NSColor(calibratedRed: 0.55, green: 0.16, blue: 0.35, alpha: 1)
)!
gradient.draw(in: path, angle: -60)

// terminal prompt glyph: ❯_
let text = "❯_"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 330, weight: .bold),
    .foregroundColor: NSColor.white,
]
let size = text.size(withAttributes: attrs)
text.draw(
    at: NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2 + 20),
    withAttributes: attrs
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("render failed")
}

let iconsetURL = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        resized.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        let png = resized.representation(using: .png, properties: [:])!
        try! png.write(to: iconsetURL.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)
print("Wrote Resources/AppIcon.icns")
