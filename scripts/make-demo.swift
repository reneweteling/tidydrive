#!/usr/bin/env swift
// make-demo.swift: composes the website demo video from the screens that
// `TidyDrive --render-assets DIR --demo` draws. Frames go straight into
// ffmpeg as raw RGBA, so nothing piles up on disk.
//
//   swift scripts/make-demo.swift build/assets docs/public/assets/demo.mp4

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-demo.swift ASSET_DIR OUTPUT.mp4"); exit(1)
}
let assets = URL(fileURLWithPath: args[1])
let output = args[2]
let W = 1600, H = 1000, FPS = 30
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ name: String) -> CGImage {
    let url = assets.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("missing \(url.path)")
    }
    return cg
}

let notification = load("notification.png")
let scans = (0..<4).map { load("states/scan-\($0).png") }
let results = load("states/results.png")
let cleans = (0..<6).map { load("states/clean-\($0).png") }
let done = load("states/done.png")
let reviews = ["review-projects", "review-docker", "review-toolchains"].map { load("states/\($0).png") }
let icon = NSImage(contentsOfFile: assets.deletingLastPathComponent().appendingPathComponent("icon-1024.png").path)?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let accent = rgb(0xFF5A36), ink = rgb(0x0D1517), paper = rgb(0xF3F5F2)

func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func progress(_ t: Double, _ start: Double, _ end: Double) -> Double { ease((t - start) / (end - start)) }

/// Draws text with AppKit into the current CGContext (flipped coordinates are not used: y is from the bottom).
func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .bold,
          color: CGColor = paper, alpha: CGFloat = 1, mono: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color)!.withAlphaComponent(alpha), .kern: -size * 0.02]
    NSAttributedString(string: string, attributes: attrs).draw(at: CGPoint(x: x, y: y))
    NSGraphicsContext.restoreGraphicsState()
}

func shadowed(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect, alpha: CGFloat, radius: CGFloat = 16) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: rgb(0x000000, 0.55))
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.setFillColor(rgb(0x1E1E1E)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setAlpha(alpha * 0.5)
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.25)); ctx.setLineWidth(1); ctx.strokePath()
    ctx.restoreGState()
}

/// Size of a 2x screenshot at its point size.
func pts(_ image: CGImage, scale: CGFloat = 1) -> CGSize { CGSize(width: CGFloat(image.width) / 2 * scale, height: CGFloat(image.height) / 2 * scale) }

// Timeline (seconds)
let total = 24.0
let menuBarH: CGFloat = 34
let statusX: CGFloat = CGFloat(W) - 250

func background(_ ctx: CGContext, t: Double, percent: Int) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0x18292C), rgb(0x070C0D)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: CGFloat(W) * 0.3, y: CGFloat(H) * 0.75), startRadius: 0,
                           endCenter: CGPoint(x: CGFloat(W) * 0.3, y: CGFloat(H) * 0.75), endRadius: CGFloat(W) * 0.9, options: [.drawsAfterEndLocation])
    // Faint dial lines in the background, slowly turning.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.035)); ctx.setLineWidth(2)
    let c = CGPoint(x: CGFloat(W) * 0.18, y: CGFloat(H) * 0.05)
    for i in 0..<9 {
        ctx.addArc(center: c, radius: CGFloat(260 + i * 90), startAngle: 0, endAngle: .pi, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Menu bar
    ctx.setFillColor(rgb(0x000000, 0.45))
    ctx.fill(CGRect(x: 0, y: CGFloat(H) - menuBarH, width: CGFloat(W), height: menuBarH))
    text(ctx, "", x: 22, y: CGFloat(H) - 26, size: 17, weight: .regular)
    text(ctx, "Finder   File   Edit   View   Go   Window   Help", x: 52, y: CGFloat(H) - 25, size: 14, weight: .medium, alpha: 0.85)
    text(ctx, "Tue 3 Nov  9:41", x: CGFloat(W) - 140, y: CGFloat(H) - 25, size: 14, weight: .medium, alpha: 0.85)
    // Status item: drive glyph and percentage
    let warn = percent >= 90
    ctx.saveGState()
    ctx.setStrokeColor(paper); ctx.setLineWidth(1.6)
    let glyph = CGRect(x: statusX, y: CGFloat(H) - 25, width: 18, height: 13)
    ctx.addPath(CGPath(roundedRect: glyph, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.strokePath()
    ctx.setFillColor(paper); ctx.fillEllipse(in: CGRect(x: glyph.maxX - 6, y: glyph.minY + 3.5, width: 3, height: 3))
    ctx.restoreGState()
    text(ctx, warn ? "\(percent)%" : "", x: statusX + 24, y: CGFloat(H) - 25, size: 14, weight: .semibold, color: warn ? accent : paper)
}

func caption(_ ctx: CGContext, _ title: String, _ sub: String, alpha: CGFloat) {
    guard alpha > 0.001 else { return }
    let y: CGFloat = 120
    ctx.saveGState()
    ctx.setFillColor(accent.copy(alpha: alpha)!)
    ctx.fill(CGRect(x: 80, y: y + 66, width: 56, height: 6))
    ctx.restoreGState()
    text(ctx, title, x: 76, y: y, size: 52, weight: .heavy, alpha: alpha)
    text(ctx, sub, x: 80, y: y - 42, size: 22, weight: .medium, color: rgb(0x93A3A8), alpha: alpha)
}

func frame(_ ctx: CGContext, t: Double) {
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
    let percent = t < 18.2 ? 93 : 84
    background(ctx, t: t, percent: percent)

    // Popover anchor under the status item.
    func popoverRect(_ image: CGImage, scale: CGFloat = 1) -> CGRect {
        let s = pts(image, scale: scale)
        return CGRect(x: statusX + 10 - s.width / 2 - 20, y: CGFloat(H) - menuBarH - 10 - s.height, width: s.width, height: s.height)
    }

    // 0-3.5 s: notification
    let nIn = progress(t, 0.4, 1.1), nOut = progress(t, 3.2, 3.8)
    if t < 3.9 {
        let s = pts(notification, scale: 1.25)
        let x = CGFloat(W) - s.width - 20 + CGFloat(1 - nIn) * (s.width + 40) + CGFloat(nOut) * (s.width + 40)
        shadowed(ctx, notification, CGRect(x: x, y: CGFloat(H) - menuBarH - 16 - s.height, width: s.width, height: s.height), alpha: 1, radius: 20)
    }
    caption(ctx, "Your disk hits 90%.", "TidyDrive tells you once, with what it found.", alpha: CGFloat(progress(t, 0.6, 1.2) * (1 - progress(t, 3.2, 3.6))))

    // 3.8-6.2 s: scanning
    if t >= 3.8 && t < 6.6 {
        let i = min(3, Int((t - 4.0) / 0.6))
        let img = scans[max(0, i)]
        let a = progress(t, 3.8, 4.2) * (1 - progress(t, 6.3, 6.6))
        shadowed(ctx, img, popoverRect(img, scale: 1.25), alpha: CGFloat(a))
    }
    caption(ctx, "It looks where developers pile up junk.", "Xcode, simulators, node_modules, Rust targets, caches, Docker.", alpha: CGFloat(progress(t, 4.0, 4.5) * (1 - progress(t, 6.2, 6.6))))

    // 6.4-9.4 s: results
    if t >= 6.3 && t < 9.8 {
        let a = progress(t, 6.3, 6.7) * (1 - progress(t, 9.4, 9.8))
        shadowed(ctx, results, popoverRect(results, scale: 1.25), alpha: CGFloat(a))
    }
    caption(ctx, "85 GB, sorted by risk.", "Safe caches and stale projects are preselected. Careful never is.", alpha: CGFloat(progress(t, 6.6, 7.1) * (1 - progress(t, 9.3, 9.7))))

    // 9.6-14.2 s: review windows
    if t >= 9.5 && t < 14.6 {
        let idx = min(2, Int((t - 9.6) / 1.6))
        for (i, img) in reviews.enumerated() {
            let start = 9.6 + Double(i) * 1.6
            let a: Double
            if i == 0 { a = progress(t, 9.5, 10.0) * (idx == 0 ? 1 : 1 - progress(t, start + 1.6, start + 1.9)) }
            else { a = progress(t, start, start + 0.3) * (i == 2 ? 1 - progress(t, 14.2, 14.6) : (idx > i ? 1 - progress(t, start + 1.6, start + 1.9) : 1)) }
            let s = pts(img, scale: 1.18)
            let lift = CGFloat(1 - progress(t, start, start + 0.4)) * 14
            shadowed(ctx, img, CGRect(x: CGFloat(W) - s.width - 70, y: (CGFloat(H) - s.height) / 2 - 10 - lift, width: s.width, height: s.height),
                     alpha: CGFloat(a), radius: 12)
        }
    }
    caption(ctx, "Every item, explained.", "Per project, per compose stack, per language version.", alpha: CGFloat(progress(t, 9.8, 10.3) * (1 - progress(t, 14.1, 14.5))))

    // 14.5-17.4 s: cleaning
    if t >= 14.4 && t < 18.4 {
        let i = min(5, max(0, Int((t - 14.6) / 0.45)))
        let img = cleans[i]
        let a = progress(t, 14.4, 14.8) * (1 - progress(t, 18.0, 18.4))
        shadowed(ctx, img, popoverRect(img, scale: 1.25), alpha: CGFloat(a))
    }
    caption(ctx, "One click.", "Tools clean themselves where they can: pnpm, brew, docker, simctl.", alpha: CGFloat(progress(t, 14.6, 15.1) * (1 - progress(t, 17.9, 18.3))))

    // 18.2-21.4 s: done
    if t >= 18.1 && t < 21.8 {
        let a = progress(t, 18.1, 18.5) * (1 - progress(t, 21.3, 21.8))
        shadowed(ctx, done, popoverRect(done, scale: 1.25), alpha: CGFloat(a))
        let counter = Int(85.4 * progress(t, 18.3, 19.6) * 10) / 1
        let gb = String(format: "%.1f GB", Double(counter) / 10)
        text(ctx, gb, x: 76, y: 300, size: 150, weight: .heavy, color: accent, alpha: CGFloat(a))
    }
    caption(ctx, "Back on your disk.", "Measured on the volume, not guessed.", alpha: CGFloat(progress(t, 18.4, 18.9) * (1 - progress(t, 21.2, 21.6))))

    // 21.6-24 s: end card
    let e = progress(t, 21.6, 22.2)
    if e > 0 {
        ctx.setFillColor(ink.copy(alpha: CGFloat(e) * 0.92)!)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let icon {
            let size: CGFloat = 220
            ctx.saveGState(); ctx.setAlpha(CGFloat(e))
            ctx.draw(icon, in: CGRect(x: (CGFloat(W) - size) / 2, y: 520, width: size, height: size))
            ctx.restoreGState()
        }
        let title = "TidyDrive"
        text(ctx, title, x: CGFloat(W) / 2 - 190, y: 400, size: 96, weight: .heavy, alpha: CGFloat(e))
        text(ctx, "Free for your Mac. Signed and notarized.", x: CGFloat(W) / 2 - 232, y: 340, size: 26, weight: .medium, color: rgb(0x93A3A8), alpha: CGFloat(e))
        text(ctx, "github.com/reneweteling/tidydrive", x: CGFloat(W) / 2 - 222, y: 280, size: 24, weight: .semibold, color: accent, alpha: CGFloat(e), mono: true)
    }
}

// Pipe raw frames into ffmpeg.
let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ffmpeg.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "\(FPS)", "-i", "-",
                    "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", output]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let frames = Int(total * Double(FPS))
var poster: CGImage?
for f in 0..<frames {
    let t = Double(f) / Double(FPS)
    frame(ctx, t: t)
    if f == Int(7.5 * Double(FPS)) { poster = ctx.makeImage() }
    // The bitmap's memory is already top row first, which is what ffmpeg wants.
    pipe.fileHandleForWriting.write(Data(bytes: ctx.data!, count: W * H * 4))
}
pipe.fileHandleForWriting.closeFile()
ffmpeg.waitUntilExit()

if let poster {
    let posterURL = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("demo-poster.png")
    try NSBitmapImageRep(cgImage: poster).representation(using: .png, properties: [:])!.write(to: posterURL)
}
print(ffmpeg.terminationStatus == 0 ? "✓ \(output)" : "✗ ffmpeg failed")
