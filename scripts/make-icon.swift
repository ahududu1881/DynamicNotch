#!/usr/bin/env swift
// Draws the Dynamic Notch app icon and writes Resources/AppIcon.icns (+ docs/icon.png).
// Usage: swift scripts/make-icon.swift      (run from the repository root)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// macOS-style squircle (superellipse) inscribed in `rect`.
func squircle(_ rect: CGRect, n: CGFloat = 4.5) -> CGPath {
    let path = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// The notch silhouette used in the app: concave flares at the top, big rounded bottom corners. y grows upwards.
func notchPath(_ rect: CGRect, top t: CGFloat, bottom b: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.maxY - t), control: CGPoint(x: rect.minX + t, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY + b))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.minY), control: CGPoint(x: rect.minX + t, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.minY + b), control: CGPoint(x: rect.maxX - t, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY - t))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
    p.closeSubpath()
    return p
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(tile)

    // Soft drop shadow of the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.38))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Background: indigo at the top melting through violet into pink, like a macOS wallpaper.
    ctx.drawLinearGradient(gradient([(0, rgb(0xFF5E9C)), (0.42, rgb(0x8A3FE6)), (1, rgb(0x2B2FC0))]),
                           start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
    // A warm light in the lower right and a cool one at the upper left give the colour some depth.
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFB066, 0.75)), (1, rgb(0xFFB066, 0))]),
                           startCenter: CGPoint(x: 800, y: 210), startRadius: 0, endCenter: CGPoint(x: 800, y: 210), endRadius: 470, options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0x3CC8FF, 0.55)), (1, rgb(0x3CC8FF, 0))]),
                           startCenter: CGPoint(x: 190, y: 640), startRadius: 0, endCenter: CGPoint(x: 190, y: 640), endRadius: 430, options: [])

    // A soft sheen on the upper half.
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0.10))]),
                           start: CGPoint(x: 0, y: tile.midY - 40), end: CGPoint(x: 0, y: tile.maxY), options: [])

    // The notch grows out of the top edge into an island.
    let island = CGRect(x: tile.midX - 270, y: tile.maxY - 330, width: 540, height: 330)
    let islandShape = notchPath(island, top: 52, bottom: 130)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: rgb(0x14052E, 0.55))
    ctx.addPath(islandShape); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    // Faint rim light along the lower edge.
    ctx.saveGState()
    ctx.addPath(islandShape); ctx.clip()
    ctx.setLineWidth(5); ctx.setStrokeColor(rgb(0xFFFFFF, 0.09))
    ctx.addPath(islandShape); ctx.strokePath()
    ctx.restoreGState()

    // Waveform: five rounded bars, the app's now-playing signature.
    let heights: [CGFloat] = [78, 138, 182, 118, 66]
    let barW: CGFloat = 30, gap: CGFloat = 26
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let centerY = island.minY + 150
    var x = island.midX - total / 2
    for h in heights {
        let bar = CGRect(x: x, y: centerY - h / 2, width: barW, height: h)
        let p = CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26, color: rgb(0xFF8AC0, 0.55))
        ctx.addPath(p); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFB6D9)), (1, rgb(0xFFFFFF))]),
                               start: CGPoint(x: 0, y: bar.minY), end: CGPoint(x: 0, y: bar.maxY), options: [])
        ctx.restoreGState()
        x += barW + gap
    }

    // Hairline highlight around the tile.
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.setLineWidth(4); ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.addPath(shape); ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DynamicNotch.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    write(master, size: size, to: iconset.appendingPathComponent("\(name).png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)
write(master, size: 512, to: URL(fileURLWithPath: "docs/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
