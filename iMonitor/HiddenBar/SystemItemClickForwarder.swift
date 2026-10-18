//
//  SystemItemClickForwarder.swift
//  iMonitor
//

import ApplicationServices
import Cocoa

// macOS 27's native hiding keeps macOS's own menu-bar items - the clock /
// calendar, Wi-Fi, Control Center... - on the bar, but inert: a click on one
// does nothing while the other icons are hidden. This passes such a click
// through. On the click's mouse-up the hiding is lifted for a moment (the
// hidden icons pop out to the left), the clicked item is pressed through
// Accessibility, and the hiding goes straight back on (see
// MenuBarEngine.liftHidingBriefly). The calendar/widgets panel or the menu the
// press opened stays up: Notification Center and Control Center are in the
// native engine's allow-list.
//
// The item is pressed with AXPress rather than by replaying the click: a
// replayed click is a real click and lands on whatever sits under the pointer
// once it is posted, while AXPress reaches exactly the item clicked.
//
// Measured on macOS 27.0.1:
// - A global monitor sees the mouse-down/up on these items while they are
//   inert, and Accessibility still lists them under MenuBarAgent, with their
//   frames. They are trailing-anchored: the hiding does not move them.
// - A click on an item whose panel or menu is open closes it by itself
//   (click-outside); pressing the item as well would open it again. Whether it
//   is open is therefore read on mouse-down, before that closing starts (its
//   content is gone about 0.36 s later).
// - Notification Center shows banners in the very window its calendar panel
//   uses, so the panel is told apart by its content, not by its window.
final class SystemItemClickForwarder {
    private struct Item {
        let identifier: String
        let element: AXUIElement
        // The item's slot, as tall as the bar: a click flung against the top
        // edge of the screen still counts.
        let frame: CGRect
    }

    private struct PendingClick {
        let item: Item
        // Every item's module on the bar, to tell whose Control Center UI is up.
        let modules: Set<String>
        // Whether the item's panel or menu was open at the mouse-down; nil when
        // that could not be told.
        let openState: Bool?
    }

    private static let menuBarAgent = "com.apple.MenuBarAgent"
    private static let notificationCenter = "com.apple.notificationcenterui"
    private static let controlCenter = "com.apple.controlcenter"
    private static let itemPrefix = "com.apple.menuextra."
    private static let clock = "com.apple.menuextra.clock"

    // What only Notification Center's calendar/widgets panel holds - widgets,
    // the widget editor button, the notification list - and a banner does not.
    private static let panelMarkerIdentifiers: Set<String> = [
        "widget-editor-button", "AXNotificationListItems",
    ]
    private static let panelMarkerRole = "AXOpaqueProviderGroup"

    // Accessibility runs on the main thread here, inside a click: bounded so a
    // busy system process cannot stall the app. A full query takes 20-60 ms.
    private static let messagingTimeout: Float = 0.1
    private static let pressTimeout: Float = 0.25
    private static let queryBudget: TimeInterval = 0.15
    // When the log checks what the press opened.
    private static let verifyDelay: TimeInterval = 0.5

    private let isActive: () -> Bool
    private let liftHiding: (@escaping () -> Void) -> Bool
    private var pending: PendingClick?

    /// - Parameters:
    ///   - isActive: whether macOS's items are inert right now, i.e. the
    ///     user wants the bar collapsed and the engine's hiding blocks them.
    ///   - liftHiding: lifts the hiding briefly around the given press
    ///     (MenuBarEngine.liftHidingBriefly); false when it cannot.
    init(
        isActive: @escaping () -> Bool,
        liftHiding: @escaping (@escaping () -> Void) -> Bool
    ) {
        self.isActive = isActive
        self.liftHiding = liftHiding
    }

    /// A left mouse-down in the menu bar, from a global monitor.
    func mouseDown(_ event: NSEvent) {
        pending = nil
        // ⌘-drag rearranges and ⌃-click asks for a context menu: neither is
        // the item's plain press.
        guard event.modifierFlags.intersection([.command, .control]).isEmpty, isActive()
        else { return }
        let point = Self.accessibilityPoint(of: event)
        let items = Self.menuBarItems()
        guard let item = items.first(where: { $0.frame.contains(point) }) else { return }
        let modules = Set(items.map { Self.module(of: $0.identifier) })
        pending = PendingClick(
            item: item, modules: modules,
            openState: Self.isUIOpen(of: item.identifier, modules: modules))
    }

    /// A left mouse-up anywhere, from a global monitor.
    func mouseUp(_ event: NSEvent) {
        guard let click = pending else { return }
        pending = nil
        let item = click.item
        // Released off the item: a drag, not a click.
        guard item.frame.contains(Self.accessibilityPoint(of: event)), isActive() else { return }
        switch click.openState {
        case false?:
            break
        case true?:
            AppLogger.info(
                "HiddenBar: \(item.identifier) clicked with its panel/menu open; the click closes it"
            )
            return
        case nil:
            // A click left alone costs a second click; pressing an item whose
            // panel is open closes the panel and opens it again.
            AppLogger.info(
                "HiddenBar: \(item.identifier) clicked, but whether its panel/menu is open "
                    + "cannot be told; not pressing it")
            return
        }
        // Up already: the bar was briefly unrestricted (another item's press)
        // and the click itself went through.
        if Self.isUIOpen(of: item.identifier, modules: click.modules) == true {
            AppLogger.info(
                "HiddenBar: \(item.identifier) opened by the click itself; not pressing it")
            return
        }
        let modules = click.modules
        let started = liftHiding {
            Self.press(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay) {
                let state = Self.isUIOpen(of: item.identifier, modules: modules)
                AppLogger.info(
                    "HiddenBar: \(item.identifier) panel/menu \(Self.describe(state)) "
                        + "\(Self.verifyDelay) s after the press")
            }
        }
        AppLogger.info(
            started
                ? "HiddenBar: \(item.identifier) clicked while hidden; lifting the hiding to press it"
                : "HiddenBar: \(item.identifier) clicked while hidden; the hiding cannot be lifted now"
        )
    }

    /// Drops a click in progress (the bar is being expanded, or the feature
    /// torn down).
    func cancel() {
        pending = nil
    }

    // MARK: - Pressing

    // AXPress on the clicked item, looked up again if its element went stale
    // since the mouse-down. Not retried otherwise: the press toggles, and a
    // second one would close what a slow first one opens.
    private static func press(_ item: Item) {
        AXUIElementSetMessagingTimeout(item.element, pressTimeout)
        var result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        if result == .invalidUIElement,
            let fresh = menuBarItems().first(where: { $0.identifier == item.identifier })
        {
            AXUIElementSetMessagingTimeout(fresh.element, pressTimeout)
            result = AXUIElementPerformAction(fresh.element, kAXPressAction as CFString)
        }
        if result != .success {
            AppLogger.warn(
                "HiddenBar: pressing \(item.identifier) failed (AXError \(result.rawValue))")
        }
    }

    // MARK: - Items

    // macOS's own items, as MenuBarAgent hosts them: each in a slot (an AXGroup
    // as tall as the bar) under its AXExtrasMenuBar.
    private static func menuBarItems() -> [Item] {
        guard let agent = application(menuBarAgent),
            let bar = elementAttribute(agent, "AXExtrasMenuBar")
        else { return [] }
        var items: [Item] = []
        for slot in children(of: bar) {
            for element in [slot] + children(of: slot) {
                guard let identifier = string(element, kAXIdentifierAttribute),
                    identifier.hasPrefix(itemPrefix)
                else { continue }
                let slotFrame = AccessibilityMenuBarInventory.frame(of: slot) ?? .null
                let frame = slotFrame.union(
                    AccessibilityMenuBarInventory.frame(of: element) ?? .null)
                guard !frame.isNull else { continue }
                items.append(Item(identifier: identifier, element: element, frame: frame))
            }
        }
        return items
    }

    // "com.apple.menuextra.wifi" -> "wifi", the prefix of the AX identifiers in
    // the Wi-Fi menu ("wifi-header", "wifi-network-...").
    private static func module(of identifier: String) -> String {
        return identifier.hasPrefix(itemPrefix)
            ? String(identifier.dropFirst(itemPrefix.count)) : identifier
    }

    // Accessibility frames use a top-left origin on the primary screen; event
    // locations a bottom-left one.
    private static func accessibilityPoint(of event: NSEvent) -> CGPoint {
        let location = event.screenLocation
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: primaryTop - location.y)
    }

    // MARK: - Whether an item's UI is open

    // Whether the panel or menu `identifier` opens is on screen; nil when it
    // cannot be told. The clock's panel belongs to Notification Center, every
    // other item's UI to Control Center.
    private static func isUIOpen(of identifier: String, modules: Set<String>) -> Bool? {
        let owner = identifier == clock ? notificationCenter : controlCenter
        guard let pid = processIdentifier(of: owner), hasRaisedWindow(pid: pid) else {
            return false
        }
        if identifier == clock {
            return notificationCenterShowsPanel(pid: pid)
        }
        return controlCenterShows(module(of: identifier), among: modules, pid: pid)
    }

    // The cheap first check: with no window of its own above the desktop
    // (the bar's levels aside), the process shows no panel or menu.
    private static func hasRaisedWindow(pid: pid_t) -> Bool {
        let barLevels: Set<Int> = [
            Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)),
        ]
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return true }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            else { return false }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return layer > 0 && !barLevels.contains(layer) && alpha > 0
        }
    }

    // Notification Center's window shows the calendar/widgets panel, not just
    // banners.
    private static func notificationCenterShowsPanel(pid: pid_t) -> Bool? {
        let deadline = Date().addingTimeInterval(queryBudget)
        guard let dialogs = systemDialogs(of: pid) else { return nil }
        for dialog in dialogs {
            let found = search(dialog, depth: 5, deadline: deadline) { element in
                if let identifier = string(element, kAXIdentifierAttribute),
                    panelMarkerIdentifiers.contains(identifier)
                {
                    return true
                }
                return string(element, kAXRoleAttribute) == panelMarkerRole
            }
            guard let isPanel = found else { return nil }
            if isPanel { return true }
        }
        return false
    }

    // Control Center shows `module`'s menu or panel. Its UIs are told apart by
    // their AX identifiers: the Wi-Fi menu's start with "wifi-", the Control
    // Center panel's with "controlcenter-". A UI matching no module on the bar
    // (Now Playing's, for one) leaves the answer open.
    private static func controlCenterShows(
        _ module: String, among modules: Set<String>, pid: pid_t
    ) -> Bool? {
        let deadline = Date().addingTimeInterval(queryBudget)
        guard let dialogs = systemDialogs(of: pid) else { return nil }
        var hasUnattributedUI = false
        for dialog in dialogs {
            var owners: Set<String> = []
            let found = search(dialog, depth: 3, deadline: deadline) { element in
                if let identifier = string(element, kAXIdentifierAttribute),
                    let owner = modules.first(where: { identifier.hasPrefix($0 + "-") })
                {
                    owners.insert(owner)
                }
                return owners.contains(module)
            }
            guard let isModule = found else { return nil }
            if isModule { return true }
            if owners.isEmpty {
                hasUnattributedUI = true
            }
        }
        return hasUnattributedUI ? nil : false
    }

    private static func describe(_ state: Bool?) -> String {
        switch state {
        case true?: return "open"
        case false?: return "not open"
        case nil: return "unknown"
        }
    }

    // MARK: - Accessibility helpers

    private static func processIdentifier(of bundleIdentifier: String) -> pid_t? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.processIdentifier
    }

    private static func application(_ bundleIdentifier: String) -> AXUIElement? {
        guard let pid = processIdentifier(of: bundleIdentifier) else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    // The process's panel-like windows (Notification Center's panel and
    // banners, Control Center's menus and panel); nil when Accessibility does
    // not answer.
    private static func systemDialogs(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
        }
        return windows.filter { string($0, kAXSubroleAttribute) == "AXSystemDialog" }
    }

    // Depth-first over `element` and up to `depth` levels below it until
    // `visit` returns true; nil once the deadline has passed.
    private static func search(
        _ element: AXUIElement, depth: Int, deadline: Date, visit: (AXUIElement) -> Bool
    ) -> Bool? {
        guard Date() < deadline else { return nil }
        if visit(element) { return true }
        guard depth > 0 else { return false }
        for child in children(of: element) {
            guard let found = search(child, depth: depth - 1, deadline: deadline, visit: visit)
            else { return nil }
            if found { return true }
        }
        return false
    }

    // A timeout set on an element does not carry over to its children, so
    // each child gets its own.
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        for child in children {
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
        }
        return children
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String)
        -> AXUIElement?
    {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value = value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

extension NSEvent {
    /// Where the event happened, in screen coordinates (bottom-left origin).
    /// A global monitor's events have no window: theirs is that already.
    var screenLocation: NSPoint {
        guard let window = window else { return locationInWindow }
        return window.convertPoint(toScreen: locationInWindow)
    }
}
