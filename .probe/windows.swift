import Cocoa
import CoreGraphics

// Probe: what does the window server expose for menu-bar windows on this macOS?
let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list")
    exit(1)
}
var layers: [Int: Int] = [:]
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    layers[layer, default: 0] += 1
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let rect = CGRect(
        x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    // Anything touching the top 40pt of the global CG space (menu-bar band).
    if rect.minY < 40 && rect.height < 60 {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
        print("layer=\(layer) owner=\(owner) pid=\(pid) rect=\(rect)")
    }
}
print("layer histogram:", layers.sorted { $0.key < $1.key })
for s in NSScreen.screens {
    print("screen frame=\(s.frame) visible=\(s.visibleFrame)")
    if #available(macOS 12.0, *) {
        print(
            "  auxL=\(String(describing: s.auxiliaryTopLeftArea)) auxR=\(String(describing: s.auxiliaryTopRightArea))"
        )
    }
}
print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
print(
    "kCGStatusWindowLevel=\(CGWindowLevelForKey(.statusWindow)) mainMenu=\(CGWindowLevelForKey(.mainMenuWindow))"
)
