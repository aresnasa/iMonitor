//
//  NotchOverflow.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import ApplicationServices
import Cocoa

// MARK: - Menu Bar Extra Info

struct MenuBarExtraInfo {
    let element: AXUIElement
    let appName: String
    let appIcon: NSImage?
    let title: String?
    let pid: pid_t
    let position: CGPoint
    let size: CGSize
}

// MARK: - Notch Geometry

/// Pure geometry: where the notch is and which X coordinates on the menu-bar
/// row it makes unreachable. Kept free of NSScreen/AppKit calls so it can be
/// unit-tested with synthetic screen values instead of live hardware.
struct NotchBoundary: Equatable {
    let hasNotch: Bool
    /// The leftmost X, in screen coordinates, at which a status item is
    /// guaranteed clear of the notch. Items positioned left of this are
    /// either under the notch or squeezed off past its left edge.
    let overflowThresholdX: CGFloat
}

enum NotchGeometry {
    // Matches the pre-fix behavior's default (half of a common 1728pt-wide
    // screen) so a screen that unexpectedly can't report safeAreaInsets still
    // gets a sane threshold instead of 0.
    static let fallbackThresholdX: CGFloat = 972

    /// - Parameters:
    ///   - screenFrame: the candidate screen's full frame (`NSScreen.frame`).
    ///   - safeAreaInsetsTop: `NSScreen.safeAreaInsets.top`; > 0 on notched Macs.
    ///   - auxiliaryTopRightAreaMinX: `NSScreen.auxiliaryTopRightArea?.minX`,
    ///     Apple's own safe-rect boundary for content right of the notch.
    ///     May be reported in global screen coordinates rather than the screen's
    ///     own space; the latter is detected and normalized here so callers can
    ///     pass either.
    static func computeBoundary(
        screenFrame: CGRect,
        safeAreaInsetsTop: CGFloat,
        auxiliaryTopRightAreaMinX: CGFloat?
    ) -> NotchBoundary {
        let hasNotch = safeAreaInsetsTop > 0
        guard hasNotch, var thresholdX = auxiliaryTopRightAreaMinX else {
            return NotchBoundary(hasNotch: hasNotch, overflowThresholdX: fallbackThresholdX)
        }
        if !screenFrame.contains(CGRect(x: thresholdX, y: 0, width: 1, height: 1)) {
            thresholdX += screenFrame.origin.x
        }
        return NotchBoundary(hasNotch: true, overflowThresholdX: thresholdX)
    }
}

// MARK: - Extras Classification

/// Pure classification of already-fetched extras against a boundary. Split
/// from AX enumeration so the sorting/filtering rules are testable without
/// a live Accessibility permission or other running apps.
enum MenuBarExtraClassifier {
    static func classify(
        _ extras: [MenuBarExtraInfo],
        boundary: CGFloat
    ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
        let renderable = extras.filter { $0.size.width > 0 && $0.size.height > 0 }
        let hidden =
            renderable
            .filter { $0.position.x < boundary }
            .sorted { $0.position.x > $1.position.x }
        let visible =
            renderable
            .filter { $0.position.x >= boundary }
            .sorted { $0.position.x > $1.position.x }
        return (hidden, visible)
    }
}

// MARK: - NotchOverflowController

class NotchOverflowController: NSObject {

    /// The status item whose menu is waiting on the Accessibility grant, so the
    /// menu can be re-opened the moment the user returns from System Settings.
    private weak var itemAwaitingPermission: NSStatusItem?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAccessibilityMayHaveChanged),
            name: AccessibilityPermission.mayHaveChangedNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notch Detection

    // The notched display, if any is attached and awake. A notched Mac drives
    // the menu bar on the built-in display; with the lid closed there is no
    // notch to overflow under.
    private static var notchedScreen: NSScreen? {
        guard #available(macOS 12.0, *) else { return nil }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private static func currentBoundary() -> NotchBoundary {
        guard #available(macOS 12.0, *), let screen = notchedScreen else {
            return NotchBoundary(
                hasNotch: false, overflowThresholdX: NotchGeometry.fallbackThresholdX)
        }
        return NotchGeometry.computeBoundary(
            screenFrame: screen.frame,
            safeAreaInsetsTop: screen.safeAreaInsets.top,
            auxiliaryTopRightAreaMinX: screen.auxiliaryTopRightArea?.minX
        )
    }

    static var hasNotch: Bool {
        currentBoundary().hasNotch
    }

    /// Show the overflow menu anchored to a status item. Safe to call from that
    /// item's own action: the menu is only *shown* after an async snapshot, by
    /// which time the originating click has finished dispatching (never call
    /// performClick re-entrantly from within the button's own action).
    func showOverflowMenu(near item: NSStatusItem, denied: (() -> Void)? = nil) {
        guard Permission.isGranted else {
            requestAuthorization()
            presentPermissionGuidedMenu(for: item)
            denied?()
            return
        }
        let boundary = Self.currentBoundary().overflowThresholdX
        item.button?.highlight(true)
        getAllMenuBarExtras { [weak self] extras in
            item.button?.highlight(false)
            guard let self = self else { return }
            let menu = self.buildOverflowMenu(extras: extras, boundary: boundary)
            item.menu = menu
            item.button?.performClick(nil)
            // Detach so the next left click runs the button action again instead
            // of re-opening a stale menu.
            DispatchQueue.main.async {
                item.menu = nil
            }
        }
    }

    // Keeps every entry point onto the same wording and deep link.
    private func requestAuthorization() {
        Permission.request()
    }

    // Looks exactly like the real overflow menu, but explains the permission
    // instead of leaving the user with "No items found".
    private func presentPermissionGuidedMenu(for item: NSStatusItem) {
        itemAwaitingPermission = item
        item.menu = buildOverflowMenu(needsAccessibilityHelp: true)
        item.button?.performClick(nil)
        DispatchQueue.main.async {
            item.menu = nil
        }
    }

    // Re-open the live menu once the user comes back from System Settings with
    // the permission granted, so granting does not first look like a no-op.
    @objc private func handleAccessibilityMayHaveChanged() {
        guard Permission.isGranted else { return }
        guard let item = itemAwaitingPermission else { return }
        itemAwaitingPermission = nil
        DispatchQueue.main.async { [weak self] in
            self?.showOverflowMenu(near: item)
        }
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        Permission.openSystemSettings()
    }

    // MARK: - Menu Building

    /// - Parameter needsAccessibilityHelp: show the accessibility-permission section
    ///   (and no live extras) when Accessibility is not granted. Without it the menu
    ///   would just read "No items found", which looks like a plain bug.
    func buildOverflowMenu(
        extras: [MenuBarExtraInfo]? = nil,
        boundary: CGFloat? = nil,
        needsAccessibilityHelp: Bool = false
    ) -> NSMenu {
        let allExtras = extras ?? []
        let resolvedBoundary = boundary ?? Self.currentBoundary().overflowThresholdX
        let (hiddenExtras, visibleExtras) = MenuBarExtraClassifier.classify(
            allExtras, boundary: resolvedBoundary)

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Title
        menu.addItem(makeSectionHeader(title: "Notch Overflow", fontSize: 12))
        menu.addItem(NSMenuItem.separator())

        if needsAccessibilityHelp {
            let explanation = NSMenuItem(
                title: "Grant Accessibility in System Settings to list the icons behind the notch.",
                action: nil, keyEquivalent: "")
            explanation.isEnabled = false
            menu.addItem(explanation)

            let grantItem = NSMenuItem(
                title: "Open System Settings\u{2026}",
                action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grantItem.target = self
            menu.addItem(grantItem)
            return menu
        }

        // Hidden section
        if !hiddenExtras.isEmpty {
            menu.addItem(makeSectionHeader(title: "Hidden Behind Notch (\(hiddenExtras.count))"))
            menu.addItem(NSMenuItem.separator())

            for info in hiddenExtras {
                menu.addItem(makeMenuItem(for: info, hidden: true))
            }
        }

        // Visible section
        if !visibleExtras.isEmpty {
            if !hiddenExtras.isEmpty { menu.addItem(NSMenuItem.separator()) }
            menu.addItem(makeSectionHeader(title: "Visible (\(visibleExtras.count))"))
            menu.addItem(NSMenuItem.separator())

            for info in visibleExtras {
                menu.addItem(makeMenuItem(for: info, hidden: false))
            }
        }

        // Empty state
        if hiddenExtras.isEmpty && visibleExtras.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No items found (check Accessibility permission)",
                action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        return menu
    }

    // Disabled, non-interactive label. Bold + labelColor (full contrast) rather
    // than secondaryLabelColor/AppKit's default disabled-item dimming, which
    // read poorly against a dark selection highlight.
    private func makeSectionHeader(title: String, fontSize: CGFloat = 13) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
        return item
    }

    private func makeMenuItem(for info: MenuBarExtraInfo, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        let displayTitle = (info.title?.isEmpty == false) ? info.title! : info.appName

        if hidden {
            // Color alone isn't an accessible way to convey "hidden" (colorblind
            // users get nothing from it, and systemOrange reads poorly against a
            // dark selection highlight). A glyph + bold weight works in any theme.
            item.attributedTitle = NSAttributedString(
                string: "\u{26A0}\u{FE0F} \(displayTitle)",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ])
        } else {
            item.title = displayTitle
        }

        if let icon = info.appIcon {
            item.image = hidden ? icon.resizedForMenu(tinted: true) : icon.resizedForMenu()
        }
        item.representedObject = info
        item.target = self
        item.action = #selector(activateItem(_:))
        return item
    }

    @objc private func activateItem(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? MenuBarExtraInfo else { return }
        let result = AXUIElementPerformAction(info.element, kAXPressAction as CFString)
        if result != .success {
            AppLogger.warn(
                "NotchOverflow: could not press \(info.appName) item (AX error \(result.rawValue))")
        }
    }

    // MARK: - Accessibility

    private typealias Permission = AccessibilityPermission

    // MARK: - AX Enumeration

    // Runs off the main thread: Accessibility round-trips to every app take about
    // a second in total and the default per-app timeout is several seconds.
    private func getAllMenuBarExtras(completion: @escaping ([MenuBarExtraInfo]) -> Void) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Only app bundles own status items. Skipping the rest (dozens of WebKit
        // and XPC helpers, each of which would sit out the timeout) cuts the walk
        // from ~2.8s to ~1s.
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != myPID && $0.bundleURL?.pathExtension == "app" }
        DispatchQueue.global(qos: .userInitiated).async {
            let results = Self.extras(of: apps)
            DispatchQueue.main.async { completion(results) }
        }
    }

    private static func extras(of apps: [NSRunningApplication]) -> [MenuBarExtraInfo] {
        var results: [MenuBarExtraInfo] = []

        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // The default timeout is several seconds per app; one busy or hung app
            // would otherwise stall the whole walk (measured: ~18s).
            AXUIElementSetMessagingTimeout(axApp, 0.1)
            var extrasRef: AnyObject?
            let err = AXUIElementCopyAttributeValue(
                axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
            guard err == .success else { continue }

            var childrenRef: AnyObject?
            let childErr = AXUIElementCopyAttributeValue(
                extrasRef as! AXUIElement,
                kAXChildrenAttribute as CFString, &childrenRef)
            guard childErr == .success,
                let children = childrenRef as? [AXUIElement]
            else { continue }

            for child in children {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)

                var posRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
                var pos = CGPoint.zero
                if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }

                var sizeRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
                var size = CGSize.zero
                if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

                results.append(
                    MenuBarExtraInfo(
                        element: child,
                        appName: app.localizedName ?? "Unknown",
                        appIcon: app.icon,
                        title: titleRef as? String,
                        pid: app.processIdentifier,
                        position: pos,
                        size: size
                    ))
            }
        }
        return results
    }
}

// MARK: - NSImage Extension

extension NSImage {
    fileprivate func resizedForMenu(tinted: Bool = false) -> NSImage {
        let target = NSSize(width: 18, height: 18)
        return NSImage(size: target, flipped: false) { rect in
            self.draw(
                in: rect,
                from: NSRect(origin: .zero, size: self.size),
                operation: .sourceOver, fraction: tinted ? 0.5 : 1.0)
            return true
        }
    }
}
