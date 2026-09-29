#!/usr/bin/env swift
// Renders the app icon into App/Assets.xcassets/AppIcon.appiconset.
//   swift Scripts/make-icon.swift
import AppKit

let outDir = "App/Assets.xcassets/AppIcon.appiconset"

/// Draws the icon on a 1024-point canvas: a wallpaper-like square with a black
/// menu bar across the top and the desktop's corners rounded beneath it.
func draw(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [NSColor(red: 0.10, green: 0.36, blue: 0.75, alpha: 1).cgColor,
                  NSColor(red: 0.13, green: 0.62, blue: 0.82, alpha: 1).cgColor,
                  NSColor(red: 0.30, green: 0.85, blue: 0.72, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Soft hill in the lower corner, for depth.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.fillEllipse(in: CGRect(x: 380, y: -160, width: 900, height: 620))

    // Menu bar.
    let barHeight: CGFloat = 150
    let barTop = body.maxY
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: body.minX, y: barTop - barHeight, width: body.width, height: barHeight))

    // Inverted corners under the bar.
    let r: CGFloat = 64
    let y = barTop - barHeight
    let left = CGMutablePath()
    left.move(to: CGPoint(x: body.minX, y: y))
    left.addLine(to: CGPoint(x: body.minX + r, y: y))
    left.addArc(center: CGPoint(x: body.minX + r, y: y - r), radius: r,
                startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    left.closeSubpath()
    let right = CGMutablePath()
    right.move(to: CGPoint(x: body.maxX, y: y))
    right.addLine(to: CGPoint(x: body.maxX - r, y: y))
    right.addArc(center: CGPoint(x: body.maxX - r, y: y - r), radius: r,
                 startAngle: .pi / 2, endAngle: 0, clockwise: true)
    right.closeSubpath()
    ctx.addPath(left); ctx.addPath(right)
    ctx.fillPath()

    // Menu bar items: a few pills on the left, dots on the right.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    let midY = barTop - barHeight / 2
    var x = body.minX + 90
    for width: CGFloat in [70, 110, 90] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: midY - 14, width: width, height: 28),
                           cornerWidth: 14, cornerHeight: 14, transform: nil))
        x += width + 26
    }
    ctx.fillPath()
    x = body.maxX - 90
    for _ in 0..<3 {
        x -= 28
        ctx.fillEllipse(in: CGRect(x: x, y: midY - 14, width: 28, height: 28))
        x -= 26
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = "icon_\(px).png"
    try render(pixels: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
