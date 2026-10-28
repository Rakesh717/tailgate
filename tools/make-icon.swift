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
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // Near-black base with a violet bloom behind the mark.
    let base = CGGradient(colorsSpace: cs, colors: [rgb(0.05, 0.05, 0.10), rgb(0.02, 0.02, 0.05)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let bloom = CGGradient(colorsSpace: cs, colors: [rgb(0.40, 0.25, 1.0, 0.45), rgb(0.40, 0.25, 1.0, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 460, options: [])

    // Nested arches: a gate, and a signal spreading out of it.
    let cx: CGFloat = 512, y0: CGFloat = 345, leg: CGFloat = 90, width: CGFloat = 58
    let mark = CGGradient(colorsSpace: cs, colors: [
        rgb(0.15, 0.95, 1.0), rgb(0.42, 0.52, 1.0), rgb(0.85, 0.35, 1.0)] as CFArray, locations: [0, 0.55, 1])!
    let arches: [(r: CGFloat, alpha: CGFloat)] = [(95, 1.0), (190, 0.86), (285, 0.68)]
    for (r, alpha) in arches {
        let arch = CGMutablePath()
        arch.move(to: CGPoint(x: cx - r, y: y0))
        arch.addLine(to: CGPoint(x: cx - r, y: y0 + leg))
        arch.addArc(center: CGPoint(x: cx, y: y0 + leg), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        arch.addLine(to: CGPoint(x: cx + r, y: y0))

        // glow
        ctx.saveGState()
        ctx.setAlpha(alpha * 0.55)
        ctx.setShadow(offset: .zero, blur: 40, color: rgb(0.45, 0.45, 1.0, 1))
        ctx.setStrokeColor(rgb(0.45, 0.5, 1.0))
        ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.addPath(arch); ctx.strokePath()
        ctx.restoreGState()

        // gradient-filled stroke
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.addPath(arch); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(mark, start: CGPoint(x: cx - 300, y: y0 + leg + 300),
                               end: CGPoint(x: cx + 300, y: y0 - 40), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        ctx.restoreGState()
    }

    // Core: the lid-awake light.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: rgb(0.3, 0.95, 1.0, 1))
    ctx.setFillColor(rgb(0.85, 1.0, 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - 40, y: y0 - 18, width: 80, height: 80))
    ctx.restoreGState()

    // Hairline inner border for depth.
    ctx.addPath(path); ctx.setLineWidth(3); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10)); ctx.strokePath()
    ctx.restoreGState()

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
