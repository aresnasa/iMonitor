import AppKit

// Corner profiles of the existing icon's panel and of the green bar track.
let path = CommandLine.arguments[1]
let image = NSImage(contentsOfFile: path)!
let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
func alpha(_ x: Int, _ y: Int) -> Int {
    Int(rep.colorAt(x: x, y: y)!.alphaComponent * 255 + 0.5)
}
func color(_ x: Int, _ y: Int) -> NSColor { rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
// Panel: first non-opaque (alpha < 250) pixel per row, scanning from the left.
var panel: [String] = []
for y in [61, 62, 64, 66, 70, 75, 80, 90, 100, 120, 140, 160, 180, 200, 220, 240] {
    var x = 0
    while x < 512 && alpha(x, y) >= 250 { x += 1 }
    panel.append("\(y):\(x)")
}
print("panel left edge per row: " + panel.joined(separator: " "))
// Green track: first pixel per row whose green dominates (track or fill).
var bar: [String] = []
for y in [205, 206, 208, 210, 213, 216, 220, 225, 230, 236, 245, 260] {
    var x = 150
    while x < 316 {
        let c = color(x, y)
        if c.greenComponent > c.blueComponent + 0.15 { break }
        x += 1
    }
    bar.append("\(y):\(x)")
}
print("green bar left edge per row: " + bar.joined(separator: " "))
var fill: [String] = []
for y in [343, 344, 346, 348, 351, 355, 360, 366, 372, 380, 390] {
    var x = 150
    while x < 316 {
        let c = color(x, y)
        if alpha(x, y) > 200 && c.greenComponent > 0.6 { break }
        x += 1
    }
    fill.append("\(y):\(x)")
}
print("green fill left edge per row: " + fill.joined(separator: " "))
