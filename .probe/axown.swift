import ApplicationServices
import Cocoa

// Why do hit-tests over iMonitor's own items come back unknown? Time each step.
let screen = NSScreen.screens[0]
let y = Float(screen.frame.maxY - (screen.visibleFrame.maxY + screen.frame.maxY) / 2)
for x in CommandLine.arguments.dropFirst().compactMap(Float.init) {
    var element: AXUIElement?
    var t = Date()
    let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &element)
    let hitMs = Date().timeIntervalSince(t) * 1000
    guard err == .success, let el = element else {
        print(String(format: "x=%.0f hit error %d after %.0f ms", x, err.rawValue, hitMs))
        continue
    }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    var role: CFTypeRef?
    t = Date()
    let roleErr = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let roleMs = Date().timeIntervalSince(t) * 1000
    let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
    print(
        String(
            format: "x=%.0f hit ok %.0f ms app=%@ role=%@ (err %d, %.0f ms)", x, hitMs, app,
            (role as? String) ?? "-", roleErr.rawValue, roleMs))
}
