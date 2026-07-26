// Generates AppIcon.icns — a navy "LC" monogram — with zero external tools.
// Usage:  swift scripts/make-icon.swift   (writes scripts/AppIcon.icns)
import AppKit

let navy = NSColor(srgbRed: 0x1F / 255.0, green: 0x3A / 255.0, blue: 0x5F / 255.0, alpha: 1)
let gold = NSColor(srgbRed: 0xC9 / 255.0, green: 0xB5 / 255.0, blue: 0x8C / 255.0, alpha: 1)

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // macOS-style rounded square with a small inset margin
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    navy.setFill()
    path.fill()
    // faint light keyline so the tile keeps its edge on dark backgrounds
    NSColor(white: 1.0, alpha: 0.18).setStroke()
    path.lineWidth = max(s * 0.01, 0.5)
    path.stroke()

    // gold baseline accent
    let barH = max(s * 0.025, 1)
    let bar = NSRect(x: s * 0.30, y: s * 0.235, width: s * 0.40, height: barH)
    gold.setFill()
    NSBezierPath(rect: bar).fill()

    // "LC" monogram
    let font = NSFont.systemFont(ofSize: s * 0.42, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: s * 0.01,
    ]
    let text = NSAttributedString(string: "LC", attributes: attrs)
    let tSize = text.size()
    text.draw(at: NSPoint(x: (s - tSize.width) / 2, y: (s - tSize.height) / 2 + s * 0.02))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = scriptDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    let rep = drawIcon(size: size)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", scriptDir.appendingPathComponent("AppIcon.icns").path]
task.launch()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote scripts/AppIcon.icns" : "iconutil failed")
exit(task.terminationStatus)
