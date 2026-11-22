// Draws the CoreGlance app icon and writes Resources/AppIcon.icns.
// Run from the project root:  swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon shape: rounded square with a margin
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.addPath(shape); ctx.clip()
    let colors = [CGColor(red: 0.07, green: 0.10, blue: 0.16, alpha: 1),
                  CGColor(red: 0.11, green: 0.17, blue: 0.27, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])

    // Three bars (CPU / RAM / GPU) behind a pulse line
    let barColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    for (i, h) in [300.0, 430.0, 360.0].enumerated() {
        let bar = CGRect(x: (270 + Double(i) * 180) * s, y: 250 * s, width: 120 * s, height: h * s)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil))
        ctx.setFillColor(barColor); ctx.fillPath()
    }
    let pts: [(Double, Double)] = [(190, 500), (370, 500), (440, 660), (540, 330), (620, 560), (670, 500), (834, 500)]
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.90, blue: 0.62, alpha: 1))
    ctx.setLineWidth(46 * s); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0 * s, y: p.1 * s)) }
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("CoreGlance.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run(); task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
