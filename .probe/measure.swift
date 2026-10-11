import AppKit

// Measure the existing 1024 icon: colors, edges, bar extents, ECG trace.
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot load \(path)") }
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide
let h = rep.pixelsHigh
print("size \(w)x\(h)")

func rgba(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (
        Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5),
        Int(c.blueComponent * 255 + 0.5), Int(c.alphaComponent * 255 + 0.5)
    )
}
func hex(_ p: (Int, Int, Int, Int)) -> String {
    String(format: "#%02X%02X%02X a=%d", p.0, p.1, p.2, p.3)
}
func transitions(row y: Int) {
    var last = rgba(0, y)
    var out = "row \(y): 0:\(hex(last))"
    for x in 1..<w {
        let p = rgba(x, y)
        if abs(p.0 - last.0) + abs(p.1 - last.1) + abs(p.2 - last.2) + abs(p.3 - last.3) > 40 {
            out += " | \(x):\(hex(p))"
            last = p
        }
    }
    print(out)
}
func transitions(column x: Int) {
    var last = rgba(x, 0)
    var out = "col \(x): 0:\(hex(last))"
    for y in 1..<h {
        let p = rgba(x, y)
        if abs(p.0 - last.0) + abs(p.1 - last.1) + abs(p.2 - last.2) + abs(p.3 - last.3) > 40 {
            out += " | \(y):\(hex(p))"
            last = p
        }
    }
    print(out)
}
transitions(row: 512)
transitions(row: 250)
transitions(row: 600)
transitions(column: 250)
transitions(column: 512)
transitions(column: 775)
transitions(column: 30)
// Corner profile: first opaque x per row near the top (outer shape), and first
// panel-colored x (inner panel) per row.
for y in [0, 2, 5, 10, 20, 40, 60, 80, 100, 150, 200, 230, 260] {
    var outer = -1
    var inner = -1
    for x in 0..<w {
        let p = rgba(x, y)
        if outer < 0 && p.3 > 127 { outer = x }
        if inner < 0 && p.3 > 127 && p.0 > 80 {
            inner = x
            break
        }
    }
    print("y=\(y) outerStart=\(outer) panelStart=\(inner)")
}
// ECG trace: teal-ish pixels (green high, red low).
var trace: [String] = []
for x in stride(from: 80, to: 950, by: 10) {
    var ys: [Int] = []
    for y in 650..<900 {
        let p = rgba(x, y)
        if p.1 > 180 && p.0 < 100 && p.2 > 120 { ys.append(y) }
    }
    if let a = ys.min(), let b = ys.max() { trace.append("\(x):\(a)-\(b)") }
}
print("ecg " + trace.joined(separator: " "))
print("ecg color \(hex(rgba(300, 825)))")
