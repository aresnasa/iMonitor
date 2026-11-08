//
//  SystemItemClickForwarder.swift
//  iMonitor
//

import ApplicationServices
import Cocoa

// macOS 27's native hiding (the menu bar's assessment mode) keeps the clock on
// the bar but makes it inert: a click on it does not open the calendar/widgets
// panel while the other icons are hidden, whatever the allow-list holds. (Wi-Fi,
// Control Center and the rest of Control Center's items keep working: its
// bundle is allowed.) This passes a click on the clock through. On the click's
// mouse-up the hiding is lifted for a moment - the hidden icons pop out to the
// left - a click is replayed on the clock, and the hiding goes back on once the
// panel it opened is gone (see MenuBarEngine.liftHidingBriefly). The panel
// stays up while it is used: Notification Center, which owns it, is in the
// native engine's allow-list, but a restriction re-applied under the panel
// would dismiss it.
//
// The replay targets the clock's own frame rather than the pointer: the clock
// is trailing-anchored, so its slot stays put while the hidden icons pop out.
// The synthetic events are flagged, so the global monitor does not take them
// for a second user click.
//
// Measured on macOS 27.0.1:
// - A global monitor sees the mouse-down/up on the inert clock, and
//   Accessibility still lists it under MenuBarAgent with its frame. It is
//   trailing-anchored: lifting the hiding does not move it.
// - A click on the clock while its panel is open closes the panel by itself
//   (click-outside); pressing the clock as well would open it again. Whether
//   the panel is open is therefore read on mouse-down, before that closing
//   starts (the panel's content is gone about 0.36 s later).
// - Notification Center shows banners in the very window the panel uses, so
//   the panel is told apart by its content, not by its window.
//
// Measured on macOS 27.2:
// - AXPress on the clock still reports success but opens nothing, even with the
//   bar unrestricted; a replayed click does open the panel. The press is
//   therefore a click now.
// - Re-applying the hiding under the open panel dismisses it (27.0.1 kept it),
//   so the engine holds the hiding lifted until the panel is gone (see
//   MenuBarEngine.liftHidingBriefly's keepLifted).
// - Notification Center's panel no longer appears in CGWindowList - the old
//   cheap check reported "no window" with the panel plainly open - so the panel
//   is looked for in Accessibility directly.
final class SystemItemClickForwarder {
    private struct Item {
        // The item's slot, as tall as the bar: a click flung against the top
        // edge of the screen still counts.
        let frame: CGRect
    }

    private struct PendingClick {
        let item: Item
        // Whether the panel was open at the mouse-down; nil when that could not
        // be told.
        let wasOpen: Bool?
    }

    private static let menuBarAgent = "com.apple.MenuBarAgent"
    private static let notificationCenter = "com.apple.notificationcenterui"
    // The one item the restriction leaves inert, as MenuBarAgent identifies it.
    private static let clock = "com.apple.menuextra.clock"

    // What only the calendar/widgets panel holds - widgets, the widget editor
    // button, the notification list - and a banner does not.
    private static let panelMarkerIdentifiers: Set<String> = [
        "widget-editor-button", "AXNotificationListItems",
    ]
    private static let panelMarkerRole = "AXOpaqueProviderGroup"

    // Accessibility runs on the main thread here, inside a click: bounded so a
    // busy system process cannot stall the app. A full panel query takes 20-60 ms.
    private static let messagingTimeout: Float = 0.1
    private static let queryBudget: TimeInterval = 0.15
    // When the log checks what the press opened.
    private static let verifyDelay: TimeInterval = 0.5
    // A replayed click is a press/release pair; the flag that keeps iMonitor
    // from handling its own events has to outlive both.
    private static let replayClickDownTime: TimeInterval = 0.06
    private static let replayClickLinger: TimeInterval = 0.3

    private let isActive: () -> Bool
    private let liftHiding: (@escaping () -> Void) -> Bool
    private var pending: PendingClick?
    // Set while the press below posts its own click, so the global monitor does
    // not take it for another user click on the clock.
    private var isReplayingClick = false

    /// - Parameters:
    ///   - isActive: whether the clock is inert right now, i.e. the user wants
    ///     the bar collapsed and the engine's hiding blocks it.
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
        guard !isReplayingClick else { return }
        pending = nil
        // ⌘-drag rearranges and ⌃-click asks for a context menu: neither is
        // the clock's plain press.
        guard event.modifierFlags.intersection([.command, .control]).isEmpty, isActive(),
            let clock = Self.clockItem(),
            clock.frame.contains(Self.accessibilityPoint(of: event))
        else { return }
        pending = PendingClick(item: clock, wasOpen: Self.isPanelOpen())
    }

    /// A left mouse-up anywhere, from a global monitor.
    func mouseUp(_ event: NSEvent) {
        guard !isReplayingClick, let click = pending else { return }
        pending = nil
        let item = click.item
        // Released off the clock: a drag, not a click.
        guard item.frame.contains(Self.accessibilityPoint(of: event)), isActive() else { return }
        switch click.wasOpen {
        case false?:
            break
        case true?:
            AppLogger.info("HiddenBar: clock clicked with its panel open; the click closes it")
            return
        case nil:
            // A click left alone costs a second click; pressing the clock with
            // the panel open closes the panel and opens it again.
            AppLogger.info(
                "HiddenBar: clock clicked, but whether its panel is open cannot be told; "
                    + "not pressing it")
            return
        }
        // Up already: the hiding was lifted for a moment (for the click before)
        // and this click went through by itself.
        if Self.isPanelOpen() == true {
            AppLogger.info("HiddenBar: clock panel opened by the click itself; not pressing it")
            return
        }
        let started = liftHiding { [weak self] in
            self?.press(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay) {
                AppLogger.info(
                    "HiddenBar: clock panel \(Self.describe(Self.isPanelOpen())) "
                        + "\(Self.verifyDelay) s after the press")
            }
        }
        AppLogger.info(
            started
                ? "HiddenBar: clock clicked while hidden; lifting the hiding to press it"
                : "HiddenBar: clock clicked while hidden; the hiding cannot be lifted now")
    }

    /// Drops a click in progress (the bar is being expanded, or the feature
    /// torn down).
    func cancel() {
        pending = nil
    }

    /// Whether the calendar/widgets panel is on screen; nil when Accessibility
    /// cannot tell. The hiding engine holds a click-through lift while this is
    /// true (and while a menu is tracking), because macOS 27.2 dismisses the
    /// panel when the restriction is re-applied under it.
    func panelIsOpen() -> Bool? {
        return Self.isPanelOpen()
    }

    /// The cheap half of `panelIsOpen` for the engine's poll: any panel-like
    /// Notification Center window counts. A banner looks the same here, which
    /// only keeps the hiding lifted a little longer; the click decisions still
    /// use the content check above.
    func panelIsOnScreen() -> Bool? {
        guard let pid = Self.processIdentifier(of: Self.notificationCenter) else { return false }
        guard let dialogs = Self.systemDialogs(of: pid) else { return nil }
        return !dialogs.isEmpty
    }

    // MARK: - The clock

    /// The clock's slot in Accessibility (top-left origin) coordinates. Used
    /// to park the invisible visibility anchor at the trailing end.
    static func clockFrame() -> CGRect? {
        return clockItem()?.frame
    }

    // Replays a click on the clock's own slot. AXPress used to do this job, but
    // on macOS 27.2 it returns success and opens nothing (measured on the clock,
    // with the bar unrestricted); a real click still works. The point is the
    // item's frame, not the pointer: the clock is trailing-anchored, so its slot
    // stays put while the hidden icons pop out to the left. The generated events
    // reach the global monitor too, hence isReplayingClick.
    private func press(_ item: Item) {
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        isReplayingClick = true
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replayClickDownTime) {
            CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left
            )?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.replayClickLinger) {
                [weak self] in
                self?.isReplayingClick = false
            }
        }
    }

    // MenuBarAgent hosts macOS's own items, each in a slot (an AXGroup as tall
    // as the bar) under its AXExtrasMenuBar.
    private static func clockItem() -> Item? {
        guard let agent = application(menuBarAgent),
            let bar = elementAttribute(agent, "AXExtrasMenuBar")
        else { return nil }
        for slot in children(of: bar) {
            for element in [slot] + children(of: slot)
            where string(element, kAXIdentifierAttribute) == clock {
                let slotFrame = AccessibilityMenuBarInventory.frame(of: slot) ?? .null
                let frame = slotFrame.union(
                    AccessibilityMenuBarInventory.frame(of: element) ?? .null)
                guard !frame.isNull else { return nil }
                return Item(frame: frame)
            }
        }
        return nil
    }

    // Accessibility frames use a top-left origin on the primary screen; event
    // locations a bottom-left one.
    private static func accessibilityPoint(of event: NSEvent) -> CGPoint {
        let location = event.screenLocation
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: primaryTop - location.y)
    }

    // MARK: - Whether the panel is open

    // Whether Notification Center shows the calendar/widgets panel; nil when
    // that cannot be told. Asked of Accessibility alone: macOS 27.2 stopped
    // listing Notification Center's panel in CGWindowList, so the old cheap
    // "has a raised window" gate answered false with the panel wide open.
    private static func isPanelOpen() -> Bool? {
        guard let pid = processIdentifier(of: notificationCenter) else { return false }
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
    // banners); nil when Accessibility does not answer.
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
