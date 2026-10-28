// Draws the Tailgate app icon and writes Resources/AppIcon.icns.
// Run: swift tools/make-icon.swift   (needs iconutil, ships with macOS)
import AppKit
import CoreGraphics

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle tile (macOS template: 824pt body in a 1024 canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.07, green: 0.10, blue: 0.30, alpha: 1),
        CGColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // soft top sheen
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Laptop: screen (lid) + base, white.
    let white = CGColor(gray: 1, alpha: 1)
    ctx.setFillColor(white)
    let screen = CGPath(roundedRect: CGRect(x: 292, y: 318, width: 440, height: 290),
                        cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.addPath(screen); ctx.fillPath()
    let base = CGPath(roundedRect: CGRect(x: 232, y: 262, width: 560, height: 46),
                      cornerWidth: 23, cornerHeight: 23, transform: nil)
    ctx.addPath(base); ctx.fillPath()

    // Screen glow: a moon/“awake” dot, cut into the lid.
    ctx.setFillColor(CGColor(red: 0.12, green: 0.34, blue: 0.85, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 512 - 34, y: 463 - 34, width: 68, height: 68))
    ctx.setFillColor(CGColor(red: 0.12, green: 0.34, blue: 0.85, alpha: 0.35))
    ctx.fillEllipse(in: CGRect(x: 512 - 70, y: 463 - 70, width: 140, height: 140))
    ctx.setFillColor(CGColor(red: 0.12, green: 0.34, blue: 0.85, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 512 - 34, y: 463 - 34, width: 68, height: 68))

    // Signal arcs rising from the lid.
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    let center = CGPoint(x: 512, y: 640)
    for (i, r) in [CGFloat(80), 140, 200].enumerated() {
        ctx.setLineWidth(34)
        ctx.setAlpha(1.0 - CGFloat(i) * 0.18)
        ctx.addArc(center: center, radius: r + 20, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
        ctx.strokePath()
    }
    ctx.setAlpha(1)
    ctx.fillEllipse(in: CGRect(x: 512 - 22, y: 640 + 20 - 22 + 0, width: 0, height: 0))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? fm.removeItem(at: set)
print("wrote \(out.path)")
