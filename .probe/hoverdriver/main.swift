import ApplicationServices
import Cocoa

// Stubs for the two app types MenuBarHoverZone.swift depends on.
enum MenuBarOrder {
    static var isUsingLTRLanguage: Bool { true }
}

enum AccessibilityMenuBarInventory {
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
                == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}

// Sweep the primary menu bar through the real MenuBarHitTester and print runs.
let screen = NSScreen.screens[0]
let bandMidY = (screen.visibleFrame.maxY + screen.frame.maxY) / 2
let xs = Array(stride(from: CGFloat(4), through: screen.frame.maxX - 4, by: 8))
var results = [MenuBarHit?](repeating: nil, count: xs.count)
var pending = xs.count
let started = Date()
for (index, x) in xs.enumerated() {
    MenuBarHitTester.probe(at: CGPoint(x: x, y: bandMidY)) { hit in
        results[index] = hit
        pending -= 1
    }
}
while pending > 0 && Date().timeIntervalSince(started) < 60 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
var runStart = 0
for index in 1...xs.count {
    if index == xs.count || results[index] != results[runStart] {
        print(
            "x \(Int(xs[runStart]))-\(Int(xs[index - 1])): \(String(describing: results[runStart]))"
        )
        runStart = index
    }
}
print(String(format: "%d probes in %.2fs", xs.count, Date().timeIntervalSince(started)))
print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
print("notch=\(String(describing: MenuBarHoverZone.notchSpan(of: screen)))")
