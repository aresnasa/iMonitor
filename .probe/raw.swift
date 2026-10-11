import AppKit

// Raw sample values (no color management) at key points, plus the PNG's profile.
let path = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let rep = NSBitmapImageRep(data: data)!
print(
    "colorSpace=\(rep.colorSpace.localizedName ?? "?") alphaFirst=\(rep.bitmapFormat.contains(.alphaFirst)) premultiplied=\(!rep.bitmapFormat.contains(.alphaNonpremultiplied)) bps=\(rep.bitsPerSample) spp=\(rep.samplesPerPixel)"
)
let points: [(String, Int, Int)] = [
    ("frame", 30, 512), ("panel", 100, 512), ("greenTrack", 250, 250), ("greenFill", 250, 600),
    ("blueTrack", 512, 300), ("blueFill", 512, 600), ("orangeTrack", 775, 230),
    ("orangeFill", 775, 600),
    ("ecg", 300, 817),
]
for (name, x, y) in points {
    var p = [Int](repeating: 0, count: 4)
    rep.getPixel(&p, atX: x, y: y)
    print(name, p)
}
