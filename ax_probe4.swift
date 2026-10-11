//
//  ax_probe4.swift
//  Scratch: drives the overflow menu's ⌘-drag rearrangement. Opens the menu,
//  finds a row by title, posts a ⌘-press and a vertical drag, releases, then
//  dumps item positions and the app log. Delete after use.
//
//  Usage:
//    swift ax_probe4.swift --open-menu --list-rows
//    swift ax_probe4.swift --cmd-drag "Postgres" 2
//

import ApplicationServices
import Cocoa

let args = CommandLine.arguments

func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

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
    return (attr(e as! AXUIElement, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func post(_ type: CGEventType, at p: CGPoint, command: Bool) {
    guard
        let e = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
            mouseCursorPosition: p, mouseButton: .left)
    else { return }
    e.flags = command ? .maskCommand : []
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.post(tap: .cghidEventTap)
}

func pressNotchDropdown(open: Bool) {
    for it in ownItems()
    where (str(it, kAXHelpAttribute as CFString) ?? "").lowercased().contains("notch") {
        print("notch press: \(axOk(AXUIElementPerformAction(it, kAXPressAction as CFString)))")
    }
}
func axOk(_ e: AXError) -> String { e == .success ? "ok" : "err \(e.rawValue)" }

/// Collects the overflow menu's items: (title, frame) in menu order.
func overflowMenuRows() -> [(title: String, frame: CGRect)] {
    var rows: [(String, CGRect)] = []
    var nodes = 0
    func walk(_ e: AXUIElement, _ d: Int) {
        guard nodes < 20000, d < 30 else { return }
        nodes += 1
        if role(e) == "AXMenu" {
            let children = (attr(e, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            let titles = children.compactMap { str($0, kAXTitleAttribute as CFString) }
            if titles.contains(where: { $0.contains("Notch Overflow") }) {
                for child in children {
                    guard let p = point(child), let s = size(child) else { continue }
                    rows.append(
                        (
                            str(child, kAXTitleAttribute as CFString) ?? "",
                            CGRect(origin: p, size: s)
                        ))
                }
            }
        }
        if let ch = attr(e, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for c in ch { walk(c, d + 1) }
        }
    }
    walk(axApp, 0)
    return rows
}

func dumpExtras(tag: String) {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.processIdentifier != myPID && $0.bundleURL?.pathExtension == "app"
    }
    var rows: [(String, CGFloat, CGFloat)] = []
    for a in apps {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let e = attr(ax, "AXExtrasMenuBar" as CFString) else { continue }
        guard
            let children = attr(e as! AXUIElement, kAXChildrenAttribute as CFString)
                as? [AXUIElement]
        else { continue }
        for child in children {
            guard let p = point(child), let s = size(child), s.width > 0, s.height > 0 else {
                continue
            }
            rows.append((a.bundleIdentifier ?? "?", p.x, s.width))
        }
    }
    rows.sort { $0.1 < $1.1 }
    print("=== extras \(tag): \(rows.count) items ===")
    for (b, x, w) in rows { print(String(format: "x=%7.1f w=%4.1f  %@", x, w, b)) }
}

func logTail(_ n: Int) {
    let path = NSHomeDirectory() + "/Library/Logs/iMonitor/imonitor.log"
    guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    print("=== log tail ===")
    for line in data.split(separator: "\n").suffix(n) { print(line) }
}

// MARK: - Modes

if let needle = argValue("--cmd-drag") {
    let deltaRows = Double(argValue("--delta-rows") ?? "0") ?? 0
    dumpExtras(tag: "before")
    pressNotchDropdown(open: true)

    var rows: [(title: String, frame: CGRect)] = []
    for _ in 0..<16 {
        Thread.sleep(forTimeInterval: 0.5)
        rows = overflowMenuRows()
        if !rows.isEmpty { break }
        // AXPress can time out yet still land; a second nudge cannot double-open
        // (the menu is only opened once) and a real miss recovers quickly.
        if rows.isEmpty { pressNotchDropdown(open: true) }
    }
    guard !rows.isEmpty else {
        print("!! overflow menu not found")
        exit(1)
    }
    if args.contains("--list-rows") {
        print("=== menu rows (\(rows.count)) ===")
        for (title, frame) in rows {
            print(String(format: "  y=%7.1f h=%4.1f  [%@]", frame.minY, frame.height, title))
        }
    }
    guard let target = rows.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }),
        target.frame.height > 0
    else {
        print("!! no row matching '\(needle)'; available:")
        for (title, _) in rows where !title.isEmpty { print("  [\(title)]") }
        exit(1)
    }

    let start = CGPoint(x: target.frame.midX, y: target.frame.midY)
    let end = CGPoint(x: start.x, y: start.y + deltaRows * target.frame.height)
    print(
        String(
            format: "dragging [%@] from (%.1f, %.1f) to y=%.1f", target.title, start.x, start.y,
            end.y))

    post(.mouseMoved, at: start, command: false)
    Thread.sleep(forTimeInterval: 0.2)
    post(.leftMouseDown, at: start, command: true)
    Thread.sleep(forTimeInterval: 0.25)
    let steps = 10
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: start.x, y: start.y + (end.y - start.y) * t)
        post(.leftMouseDragged, at: p, command: true)
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.15)
    post(.leftMouseUp, at: end, command: true)
    // The app now expands the bar, runs its synthetic ⌘-drag and re-collapses.
    Thread.sleep(forTimeInterval: 5.0)

    dumpExtras(tag: "after")
    logTail(15)
    // Hygiene: whatever is left open, close it.
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
} else if args.contains("--open-menu") {
    pressNotchDropdown(open: true)
    Thread.sleep(forTimeInterval: 2.5)
    let rows = overflowMenuRows()
    print("=== overflow menu (\(rows.count) rows) ===")
    for (title, frame) in rows {
        print(String(format: "  y=%7.1f h=%4.1f  [%@]", frame.minY, frame.height, title))
    }
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
} else if args.contains("--dump-extras") {
    dumpExtras(tag: "")
} else if args.contains("--log") {
    logTail(20)
}
