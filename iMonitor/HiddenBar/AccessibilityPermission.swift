//
//  AccessibilityPermission.swift
//  iMonitor
//
//  Single place that answers "may iMonitor use Accessibility?" and that points
//  the user at the right System Settings pane. The notch-overflow feature cannot
//  read other apps' status items without the permission, and the native menu-bar
//  hiding cannot map icons to apps without it, so every caller shares this.
//
//  macOS shows its own "grant access" prompt at most once per app per launch;
//  afterwards a denied app silently gets nothing back from Accessibility. The
//  helper keeps the state explicit so callers can say WHAT is wrong instead of
//  appearing broken.
//

import Cocoa

enum AccessibilityPermission {

    enum State {
        case granted
        /// Denied before, or awaiting a first grant: only the user can fix it.
        case needsUserAction
    }

    /// Whether iMonitor may use Accessibility right now. Never prompts.
    static var state: State {
        return AXIsProcessTrusted() ? .granted : .needsUserAction
    }

    static var isGranted: Bool { state == .granted }

    /// Ask macOS to show the grant prompt and open the Accessibility pane in
    /// System Settings. A second call in the same launch is a no-op; denied
    /// users go through `openSystemSettings()` instead.
    @discardableResult
    static func request() -> Bool {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Deep link into the Accessibility list in System Settings.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Offer to open the exact settings pane, used when the user asked for
    /// something that needs the permission and it is not granted.
    static func presentHelp() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
            To list the menu-bar icons hidden behind the camera notch, iMonitor \
            needs the Accessibility permission (System Settings › Privacy & \
            Security › Accessibility).
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// Posted after the app returns to the foreground, so a view or controller
    /// can re-read `state` once the user had a chance to grant the permission.
    static let mayHaveChangedNotification = Notification.Name("iMonitorAccessibilityMayHaveChanged")
}
