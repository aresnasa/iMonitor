import AppKit
import ApplicationServices
import Foundation

// Throwaway probe: exercise the same AX calls the app makes, from this process.
// Prints the actual AX error codes, which tell permission problems apart from
// "the API works but is not authorized for that app".

print("AXIsProcessTrusted:", AXIsProcessTrusted())

// 1. Find another app that owns a status item and try to read its extras bar.
guard
    let target = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.dwarvesv.minimalbar"
            || $0.bundleIdentifier == "com.knollsoft.Rectangle"
    })
else {
    print("no probe target running (looked for minimalbar / Rectangle)")
    exit(0)
}

let app = AXUIElementCreateApplication(target.processIdentifier)
var value: CFTypeRef?
let err = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value)
print("target:", target.bundleIdentifier ?? "?")
print(
    "AXExtrasMenuBar error code:", err.rawValue, "(", err == .success ? "success" : "failure", ")")

if err == .success, let bar = value {
    var children: CFTypeRef?
    let childErr = AXUIElementCopyAttributeValue(
        bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
    let count = (children as? [AXUIElement])?.count ?? 0
    print("AXChildren error code:", childErr.rawValue, "child count:", count)
}
