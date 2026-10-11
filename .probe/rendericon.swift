import Cocoa

// Render what IconServices shows for each bundle path given on the command line
// (512x512 PNGs next to this script), so the system's treatment of the icon
// (e.g. the macOS 26+ plate for non-conforming legacy icons) can be inspected.
let outDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
    let icon = NSWorkspace.shared.icon(forFile: path)
    let size = NSSize(width: 512, height: 512)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let out = outDir.appendingPathComponent("rendered-\(index).png")
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    print("\(path) -> \(out.path) reps=\(icon.representations.count)")
}
