//
//  MenuBarHoverZone.swift
//  iMonitor
//
//  Where hover-to-expand may fire: only on an empty stretch of the menu bar on
//  the arrow's hidden side - never over the frontmost app's menus or any icon -
//  so a pointer heading for something already visible never reveals the
//  hidden icons.
//

import ApplicationServices
import Cocoa

/// What lies under a point of the menu bar.
enum MenuBarHit: Equatable {
    /// Bare menu bar: neither an app menu title nor a status icon.
    case emptySpace
    /// A title of the frontmost app's menus, or the strip before the first one.
    case appMenu
    /// Another app's or macOS's status icon, its padding included.
    case statusItem
    /// One of this app's own status items.
    case ownItem
    /// Accessibility could not tell (permission missing, timeout...).
    case unknown
}

enum MenuBarHitClassifier {
    /// Maps an Accessibility hit-test result, as observed on macOS 26/27:
    /// wherever nothing is drawn, hit-testing falls through to the frontmost
    /// app's own menu bar (role AXMenuBar); menu titles are AXMenuBarItems;
    /// icons are AXMenuBarItem/AXMenuExtra, flanked by AXButton/AXImage/
    /// AXUnknown slivers and by their owner's extras bar (also role AXMenuBar,
    /// but owned by an app that is not frontmost).
    static func classify(
        role: String?, subrole: String?, pid: pid_t?, frontmostPID: pid_t?, ownPID: pid_t
    ) -> MenuBarHit {
        guard let role = role, let pid = pid else { return .unknown }
        if role == kAXMenuBarRole {
            return pid == frontmostPID ? .emptySpace : .statusItem
        }
        if pid == ownPID {
            return .ownItem
        }
        if role == kAXMenuBarItemRole, subrole != "AXMenuExtra" {
            return .appMenu
        }
        return .statusItem
    }
}

/// Accessibility hit-testing of the menu bar. Runs off the main thread: the
/// element under the pointer may be this app's own, whose main thread has to
/// answer the request, and a hung app must not stall the UI.
enum MenuBarHitTester {
    private static let queue = DispatchQueue(
        label: "com.aresnasa.iMonitor.menu-bar-hit-test", qos: .userInitiated)
    // Set per element only: a timeout set on the system-wide element would
    // apply to every Accessibility call this process makes.
    private static let messagingTimeout: Float = 0.25

    /// Classifies what lies under `point` (AppKit global coordinates) and calls
    /// `completion` on the main queue.
    static func probe(at point: CGPoint, completion: @escaping (MenuBarHit) -> Void) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isLTR = MenuBarOrder.isUsingLTRLanguage
        // Accessibility measures from the primary display's top-left corner.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: point.x, y: primaryMaxY - point.y)
        queue.async {
            let hit = classify(
                at: axPoint, ownPID: ownPID, frontmostPID: frontmostPID, isLTR: isLTR)
            DispatchQueue.main.async { completion(hit) }
        }
    }

    private static func classify(
        at point: CGPoint, ownPID: pid_t, frontmostPID: pid_t?, isLTR: Bool
    ) -> MenuBarHit {
        var hitElement: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hitElement)
                == .success,
            let element = hitElement
        else { return .unknown }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var pid: pid_t = 0
        let hasPID = AXUIElementGetPid(element, &pid) == .success
        let hit = MenuBarHitClassifier.classify(
            role: stringAttribute(kAXRoleAttribute, of: element),
            subrole: stringAttribute(kAXSubroleAttribute, of: element),
            pid: hasPID ? pid : nil, frontmostPID: frontmostPID, ownPID: ownPID)
        // The bare bar also runs before the Apple menu, where hidden icons never
        // appear; only the stretch past the app's menus counts. When the menus
        // cannot be read, that sliver is the only thing let through.
        guard hit == .emptySpace, let frontmostPID = frontmostPID,
            let menus = appMenusSpan(of: frontmostPID)
        else { return hit }
        let isPastMenus = isLTR ? point.x > menus.maxX : point.x < menus.minX
        return isPastMenus ? .emptySpace : .appMenu
    }

    /// The horizontal span of the frontmost app's menu titles, Apple menu included.
    private static func appMenusSpan(of pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var barValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue)
                == .success,
            let barRef = barValue, CFGetTypeID(barRef) == AXUIElementGetTypeID()
        else { return nil }
        let bar = barRef as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, messagingTimeout)
        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue)
                == .success,
            let titles = childrenValue as? [AXUIElement],
            let first = titles.first.flatMap(AccessibilityMenuBarInventory.frame(of:)),
            let last = titles.last.flatMap(AccessibilityMenuBarInventory.frame(of:))
        else { return nil }
        return first.union(last)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}

enum MenuBarHoverZone {
    /// Whether `x`, on the screen with frame `screenFrame`, lies on the arrow's
    /// hidden side - where the hidden icons show up once revealed - and clear
    /// of the camera notch. Status items keep their distance from the bar's
    /// trailing edge on every display, so the arrow's slot is carried over
    /// from the screen it was measured on.
    static func contains(
        x: CGFloat, screenFrame: CGRect, arrowFrame: CGRect, arrowScreenFrame: CGRect,
        notch: ClosedRange<CGFloat>?, isLTR: Bool
    ) -> Bool {
        let isOnHiddenSide: Bool
        if isLTR {
            let arrowMinX = screenFrame.maxX - (arrowScreenFrame.maxX - arrowFrame.minX)
            isOnHiddenSide = x >= screenFrame.minX && x < arrowMinX
        } else {
            let arrowMaxX = screenFrame.minX + (arrowFrame.maxX - arrowScreenFrame.minX)
            isOnHiddenSide = x > arrowMaxX && x <= screenFrame.maxX
        }
        return isOnHiddenSide && !(notch?.contains(x) ?? false)
    }

    /// The camera housing's horizontal span on `screen`, in global coordinates;
    /// nil on a display without a notch.
    static func notchSpan(of screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard screen.safeAreaInsets.top > 0,
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else { return nil }
        // The left area starts at the screen's left edge; normalise to global
        // coordinates whichever space the system reports them in (see
        // NotchGeometry).
        let offset = abs(leftArea.minX - screen.frame.minX) < 1 ? 0 : screen.frame.minX
        let lower = leftArea.maxX + offset
        let upper = rightArea.minX + offset
        return lower < upper ? lower...upper : nil
    }
}
