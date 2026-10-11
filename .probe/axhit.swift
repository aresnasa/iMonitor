import ApplicationServices
import Cocoa

// Probe: what does Accessibility hit-testing report across the menu bar?
let systemWide = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(systemWide, 0.2)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func describe(_ el: AXUIElement) -> String {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid\(pid)"
    let role = attr(el, kAXRoleAttribute) as? String ?? "-"
    let subrole = attr(el, kAXSubroleAttribute) as? String ?? "-"
    let title = (attr(el, kAXTitleAttribute) as? String ?? "").prefix(14)
    var parentRole = "-"
    if let p = attr(el, kAXParentAttribute) {
        parentRole = attr(p as! AXUIElement, kAXRoleAttribute) as? String ?? "-"
    }
    return "\(role)/\(subrole) parent=\(parentRole) app=\(app) title=\(title)"
}

let width = Int(NSScreen.screens.map { $0.frame.maxX }.max() ?? 1920)
var lastDesc = ""
var runStart = 0
let start = Date()
var calls = 0
for x in stride(from: 0, through: width, by: 8) {
    var el: AXUIElement?
    calls += 1
    let err = AXUIElementCopyElementAtPosition(systemWide, Float(x), 15, &el)
    let desc = (err == .success && el != nil) ? describe(el!) : "error \(err.rawValue)"
    if desc != lastDesc {
        if !lastDesc.isEmpty { print("x \(runStart)-\(x - 8): \(lastDesc)") }
        lastDesc = desc
        runStart = x
    }
}
print("x \(runStart)-\(width): \(lastDesc)")
let elapsed = Date().timeIntervalSince(start)
print(
    String(
        format: "%d hit-tests in %.3fs (%.2f ms each)", calls, elapsed,
        elapsed * 1000 / Double(calls)))
print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
