//
//  icon_probe.swift
//  Scratch: checks NSRunningApplication.icon availability (main vs background
//  thread, mirroring the app's fetch path) and renders sample PNGs to compare
//  the two NSImage resize techniques. Delete after use.
//

import Cocoa

let repoRoot = "/Users/aresnasa/MyProjects/go/src/github.com/aresnasa/iMonitor"

let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.pathExtension == "app" }

var mainIcons = 0
for app in apps where app.icon != nil { mainIcons += 1 }
print("main thread: \(mainIcons)/\(apps.count) apps expose an icon")

var bgNil: [String] = []
let sem = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .userInitiated).async {
    for app in apps where app.icon == nil {
        bgNil.append(app.bundleIdentifier ?? app.localizedName ?? "?")
    }
    sem.signal()
}
sem.wait()
print("background thread nil-icon apps (\(bgNil.count)): \(bgNil.sorted().joined(separator: ", "))")

if let docker = apps.first(where: { $0.bundleIdentifier == "com.electron.dockerdesktop" }),
    let icon = docker.icon
{
    let target = NSSize(width: 18, height: 18)

    // Variant 1: drawing-handler (the code path currently in NotchOverflow.swift)
    let viaHandler = NSImage(size: target, flipped: false) { rect in
        icon.draw(
            in: rect, from: NSRect(origin: .zero, size: icon.size),
            operation: .sourceOver, fraction: 1.0)
        return true
    }
    if let tiff = viaHandler.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    {
        try? png.write(to: URL(fileURLWithPath: repoRoot + "/icon-handler-test.png"))
        print("handler render: \(png.count) bytes, size=\(viaHandler.size)")
    } else {
        print("handler render: FAILED (tiff=\(viaHandler.tiffRepresentation != nil))")
    }

    // Variant 2: lockFocus
    let viaFocus = NSImage(size: target)
    viaFocus.lockFocus()
    icon.draw(
        in: NSRect(origin: .zero, size: target),
        from: NSRect(origin: .zero, size: icon.size), operation: .sourceOver, fraction: 1.0)
    viaFocus.unlockFocus()
    if let tiff = viaFocus.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    {
        try? png.write(to: URL(fileURLWithPath: repoRoot + "/icon-focus-test.png"))
        print("lockFocus render: \(png.count) bytes")
    } else {
        print("lockFocus render: FAILED")
    }

    print("docker icon original size: \(icon.size)")
} else {
    print("Docker Desktop icon not available")
}
