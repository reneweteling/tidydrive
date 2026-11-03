#!/usr/bin/env swift
// make-icon.swift: draws the TidyDrive icon (a disk gauge arc in vermilion
// on a deep ink squircle) at every size an .iconset needs, plus a 1024px PNG
// for the website. Run: swift scripts/make-icon.swift

import AppKit
import CoreGraphics

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
let root = repoRoot.hasPrefix("/") ? repoRoot : FileManager.default.currentDirectoryPath
let iconset = "\(root)/build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icon grid: the shape sits inside ~80% of the canvas.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(13, 21, 23))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient, ink to a deeper teal
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(28, 46, 50), color(8, 14, 16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // Faint tick marks along the dial
    let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.36)
    let r = rect.width * 0.33
    ctx.setLineCap(.round)
    for i in 0...10 {
        let a = CGFloat.pi - CGFloat(i) / 10 * CGFloat.pi
        let inner = r + rect.width * 0.085
        let outer = r + rect.width * (i % 5 == 0 ? 0.125 : 0.105)
        ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
    }
    ctx.setStrokeColor(color(243, 245, 242, 0.28))
    ctx.setLineWidth(max(1, s * 0.008))
    ctx.strokePath()

    // Track
    let line = rect.width * 0.11
    ctx.setLineWidth(line)
    ctx.setStrokeColor(color(58, 74, 77))
    ctx.addArc(center: center, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    ctx.strokePath()

    // Value arc, vermilion, about 62% of the dial
    let end = CGFloat.pi - 0.62 * CGFloat.pi
    let arcGradient = CGGradient(colorsSpace: space, colors: [color(255, 122, 82), color(232, 67, 31)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addArc(center: center, radius: r, startAngle: .pi, endAngle: end, clockwise: true)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(arcGradient, start: CGPoint(x: center.x - r - line, y: center.y), end: CGPoint(x: center.x + r, y: center.y + r), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Needle and hub
    let needle = CGPoint(x: center.x + cos(end) * r * 0.72, y: center.y + sin(end) * r * 0.72)
    ctx.setStrokeColor(color(243, 245, 242))
    ctx.setLineWidth(rect.width * 0.035)
    ctx.move(to: center)
    ctx.addLine(to: needle)
    ctx.strokePath()
    let hub = rect.width * 0.075
    ctx.setFillColor(color(243, 245, 242))
    ctx.fillEllipse(in: CGRect(x: center.x - hub / 2, y: center.y - hub / 2, width: hub, height: hub))

    // Free-space bar below the dial
    let barW = rect.width * 0.5, barH = rect.width * 0.055
    let bar = CGRect(x: rect.midX - barW / 2, y: rect.minY + rect.height * 0.15, width: barW, height: barH)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    ctx.setFillColor(color(58, 74, 77))
    ctx.fillPath()
    let filled = CGRect(x: bar.minX, y: bar.minY, width: barW * 0.38, height: barH)
    ctx.addPath(CGPath(roundedRect: filled, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    ctx.setFillColor(color(95, 211, 154))
    ctx.fillPath()

    // Subtle top highlight
    let highlight = CGGradient(colorsSpace: space, colors: [color(255, 255, 255, 0.10), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in sizes {
    try! render(size).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "\(root)/build/icon-1024.png"))
print("✓ Wrote \(iconset)")
