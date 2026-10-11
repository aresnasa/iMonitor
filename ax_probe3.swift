//
//  ax_probe3.swift
//  Scratch: bar-state probe. --press-arrow expands/collapses iMonitor's hidden
//  bar; --dump-extras prints other apps' item positions; --open-menu dumps the
//  overflow menu sections. Delete after use.
//

import ApplicationServices
import Cocoa

let args = CommandLine.arguments

guard
    let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.aresnasa.iMonitor"
    })
else {
    print("iMonitor not running")
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(axApp, 2.0)

func attr(_ el: AXUIElement, _ name: CFString) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name, &v) == .success ? v : nil
}
func role(_ el: AXUIElement) -> String {
    (attr(el, kAXRoleAttribute as CFString) as? String) ?? "?"
}
func str(_ el: AXUIElement, _ key: CFString) -> String? { attr(el, key) as? String }
func point(_ el: AXUIElement) -> CGPoint? {
    guard let pv = attr(el, kAXPositionAttribute as CFString) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue((pv as! AXValue), .cgPoint, &p) ? p : nil
}
func size(_ el: AXUIElement) -> CGSize? {
    guard let sv = attr(el, kAXSizeAttribute as CFString) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue((sv as! AXValue), .cgSize, &s) ? s : nil
}

func ownItems() -> [AXUIElement] {
    guard let e = attr(axApp, "AXExtrasMenuBar" as CFString) else { return [] }
    let extras = e as! AXUIElement
    return (attr(extras, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

if args.contains("--press-arrow") {
    var pressed = false
    for it in ownItems()
    where (str(it, kAXHelpAttribute as CFString) ?? "").contains("Hide or show") {
        print(
            "arrow press result: \(AXUIElementPerformAction(it, kAXPressAction as CFString).rawValue)"
        )
        pressed = true
    }
    if !pressed { print("arrow item not found") }
}

if args.contains("--wait") { Thread.sleep(forTimeInterval: 2.0) }

if args.contains("--dump-extras") {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.processIdentifier != myPID && $0.bundleURL?.pathExtension == "app"
    }
    var rows: [(String, CGFloat, CGFloat)] = []
    for a in apps {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let e = attr(ax, "AXExtrasMenuBar" as CFString) else { continue }
        let extras = e as! AXUIElement
        guard let children = attr(extras, kAXChildrenAttribute as CFString) as? [AXUIElement]
        else { continue }
        for child in children {
            guard let p = point(child), let s = size(child), s.width > 0, s.height > 0 else {
                continue
            }
            rows.append((a.bundleIdentifier ?? "?", p.x, s.width))
        }
    }
    rows.sort { $0.1 < $1.1 }
    print("items: \(rows.count)")
    for (b, x, w) in rows { print(String(format: "x=%7.1f w=%4.1f  %@", x, w, b)) }
}

if args.contains("--open-menu") {
    for it in ownItems()
    where (str(it, kAXHelpAttribute as CFString) ?? "").lowercased().contains("notch") {
        print(
            "notch press result: \(AXUIElementPerformAction(it, kAXPressAction as CFString).rawValue)"
        )
    }
    Thread.sleep(forTimeInterval: 2.5)
    var found = false
    var nodes = 0
    func walk(_ e: AXUIElement, _ d: Int) {
        guard nodes < 20000, d < 30 else { return }
        nodes += 1
        if role(e) == "AXMenu" {
            let mi = (attr(e, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            let titles = mi.map { str($0, kAXTitleAttribute as CFString) ?? "" }
            if titles.contains(where: {
                $0.contains("Notch Overflow") || $0.contains("Behind Notch")
            }) {
                found = true
                print("=== overflow menu (\(titles.count) rows) ===")
                for t in titles where !t.isEmpty { print("  [\(t)]") }
            }
        }
        if let ch = attr(e, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for c in ch { walk(c, d + 1) }
        }
    }
    walk(axApp, 0)
    if !found { print("!! overflow menu not found") }
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
}
