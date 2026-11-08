//
//  MenuBarManagerCompatibility.swift
//  iMonitor
//
//  Another manager's side of the macOS 27 native restriction. OnlySwitch (and
//  the older OneSwitch) hide icons by naming the bundles on the trailing side
//  of their own divider, and macOS intersects every active allow-list. While one
//  of them is running, iMonitor must own an item on that side too, or its arrow
//  and stats icons vanish with the other manager's section as soon as that
//  manager's hiding is switched on.
//

import Cocoa

enum MenuBarManagerCompatibility {

    /// The managers seen alongside iMonitor that use the same native
    /// restriction.
    static let bundleIdentifiers = [
        "jacklandrin.OnlySwitch",
        "studio.fireball.OneSwitch",
    ]

    /// Whether a compatible manager is running at all. The compatibility anchor
    /// is kept for as long as one is: the manager's hiding switch can be flipped
    /// from its own menu at any moment, and by then iMonitor's arrow may already
    /// sit on that manager's hidden side - too late to place the anchor, since a
    /// status item created under an active restriction may never be drawn.
    /// Having the anchor there beforehand is what keeps the arrow on the bar.
    static func isAnotherManagerRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleIdentifier)
        }
    }

    /// Whether a running manager is hiding icons right now. Only used to explain
    /// in the log why an anchor was added; the anchor's presence is decided by
    /// `isAnotherManagerRunning`, because this state can flip without notice.
    ///
    /// The manager's own state is read instead of the bar's layout: status-item
    /// frames in the AX tree go stale for everything the bar stops drawing, and
    /// an arrangement read that way cannot be trusted to decide this.
    static func isAnotherManagerHidingIcons() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier,
                bundleIdentifiers.contains(bundleIdentifier)
            else { continue }
            if let hiding = hidingState(of: bundleIdentifier) {
                if hiding { return true }
            } else {
                // No readable state (OneSwitch, or a future OnlySwitch key):
                // assume the feature is in use rather than risk hiding iMonitor.
                return true
            }
        }
        return false
    }

    // OnlySwitch persists its "Hide Menu Bar Icons" feature and switch under
    // these keys: the feature defaults to on, the switch to off. Both must be on
    // for the manager to be hiding icons; the value is stored as data
    // ("true"/"false"), so every representation is accepted.
    private static func hidingState(of bundleIdentifier: String) -> Bool? {
        guard bundleIdentifier == "jacklandrin.OnlySwitch" else { return nil }
        let featureOn = boolPreference("menubarCollapsableKey", of: bundleIdentifier) ?? true
        guard featureOn else { return false }
        return boolPreference("isMenubarCollapseKey", of: bundleIdentifier) ?? false
    }

    private static func boolPreference(_ key: String, of bundleIdentifier: String) -> Bool? {
        guard
            let value = CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString)
        else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return (text as NSString).boolValue }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            return (text as NSString).boolValue
        }
        // The key exists in a shape this build does not know: assume the feature
        // is on rather than let a future OnlySwitch quietly remove the anchor.
        return true
    }
}
