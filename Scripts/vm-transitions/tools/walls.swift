// Runs on the Mac: writes solid-color wallpapers that cover the cases the menu bar key
// has to handle: dark, mid and light gray, saturated colors, and white.
//   walls <directory>
import AppKit

let colors: [(String, NSColor)] = [
    ("black", .black), ("darkgreen", NSColor(srgbRed: 0.1, green: 0.3, blue: 0.25, alpha: 1)),
    ("midgray", NSColor(white: 0.5, alpha: 1)), ("lightgray", NSColor(white: 0.8, alpha: 1)),
    ("red", NSColor(srgbRed: 0.9, green: 0.15, blue: 0.1, alpha: 1)),
    ("yellow", NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)),
    ("cyan", NSColor(srgbRed: 0.3, green: 0.85, blue: 1, alpha: 1)), ("white", .white),
]
for (name, color) in colors {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1200, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 1200).fill()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[1])/\(name).png"))
}
