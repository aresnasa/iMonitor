import Cocoa

// Probe: which distributed notifications fire while an NSMenu tracks, and how
// does an open menu look in the CG window list on this macOS?
final class Probe: NSObject, NSApplicationDelegate {
    let candidates = [
        "com.apple.HIToolbox.beginMenuTrackingNotification",
        "com.apple.HIToolbox.endMenuTrackingNotification",
        "NSMenuDidBeginTrackingNotification",
        "NSMenuDidEndTrackingNotification",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dnc = DistributedNotificationCenter.default()
        for name in candidates {
            dnc.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { note in
                print(
                    "distributed: \(note.name.rawValue) object=\(String(describing: note.object))")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openMenu() }
    }

    func openMenu() {
        let menu = NSMenu(title: "probe")
        menu.addItem(withTitle: "iMonitor probe - closes by itself", action: nil, keyEquivalent: "")
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            self.dumpWindows(label: "while open")
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        let frame = NSScreen.main!.frame
        menu.popUp(positioning: nil, at: NSPoint(x: frame.midX, y: frame.maxY - 40), in: nil)
        print("menu closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.dumpWindows(label: "after close")
            NSApp.terminate(nil)
        }
    }

    func dumpWindows(label: String) {
        let list =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
            ?? []
        var found = false
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 24 else { continue }
            found = true
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            print(
                "\(label): layer=\(layer) owner=\(owner) bounds=\(w[kCGWindowBounds as String] ?? "-")"
            )
        }
        if !found { print("\(label): no windows above layer 24") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
app.delegate = probe
app.run()
