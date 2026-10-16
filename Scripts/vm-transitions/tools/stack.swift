// Runs on the Mac: stacks images vertically, with a magenta rule between them, into one
// PNG for looking through a transition frame by frame.
//   stack <output.png> <image>...
import AppKit

let images = CommandLine.arguments.dropFirst(2).compactMap { path in
    (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(NSBitmapImageRep.init(data:))
}
guard !images.isEmpty else { exit(0) }
let width = images.map(\.pixelsWide).max()!, height = images.map(\.pixelsHigh).reduce(0, +) + 6 * images.count
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.magenta.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
var y = height
for image in images {
    y -= image.pixelsHigh
    image.draw(in: NSRect(x: 0, y: y, width: image.pixelsWide, height: image.pixelsHigh))
    y -= 6
}
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
