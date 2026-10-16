// Runs on the Mac: reads a recording (one PNG of the menu bar per frame, named by its
// epoch time, plus a `marks` file of "<epoch> <label>" lines) and prints when the top
// rows go from black to not black and back, interleaved with the marks. "not black" in
// a full-screen Space is the app's own content; elsewhere it's the background showing.
//   timeline <recording directory>
import AppKit

let dir = CommandLine.arguments[1]
let marks = try String(contentsOfFile: "\(dir)/marks", encoding: .utf8).split(separator: "\n").map { line in
    let parts = line.split(separator: " ", maxSplits: 1)
    return (Double(parts[0])!, "MARK \(parts[1])")
}
var events = marks
var last = ""
for file in try FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".png") }).sorted() {
    guard let time = Double(file.dropLast(4)),
          let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(file)"))) else { continue }
    var lit = 0, total = 0
    for y in 2..<6 {
        for x in stride(from: 0, to: image.pixelsWide, by: 3) {
            let c = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            total += 1
            if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.05 { lit += 1 }
        }
    }
    let share = 100 * Double(lit) / Double(total)
    let state = share < 1 ? "black" : share > 90 ? "NOT BLACK" : String(format: "partly %.0f%%", share)
    if state != last { events.append((time, "\(state)  \(file)")); last = state }
}
let start = marks.first?.0 ?? 0
for (time, text) in events.sorted(by: { $0.0 < $1.0 }) where time >= start {
    print(String(format: "%7.2f  ", time - start), text)
}
