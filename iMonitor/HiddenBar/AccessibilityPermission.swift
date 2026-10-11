//
//  AccessibilityPermission.swift
//  iMonitor
//
//  Single place that answers "may iMonitor use Accessibility?" and that points
//  the user at the right System Settings pane. The notch-overflow feature cannot
//  read other apps' status items without the permission, and the native menu-bar
//  hiding cannot map icons to apps without it, so every caller shares this.
//
//  macOS pins each Accessibility grant to the exact app build: a build signed
//  with iMonitor's signing certificate keeps its grant across rebuilds, while an
//  ad-hoc build gets a new identity every time - its old grant stays visibly on
//  in System Settings but no longer applies. `AppConfig.accessibilityGrantedOnce`
//  remembers that a grant existed, so that state gets its own explanation
//  instead of looking like a first run.
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

    /// Whether a failed feature should still ask macOS for the prompt on its
    /// own. False once the user dealt with the setup walkthrough or granted
    /// before: a missing grant then belongs to a rebuild or another copy, and
    /// an auto-prompt from a click could only nag - the guidance UIs
    /// (`presentHelp()`, the notch menu) explain the fix instead.
    static var shouldPromptOnDemand: Bool {
        return !isGranted
            && !AppConfig.accessibilityGrantedOnce
            && !AppConfig.permissionOnboardingCompleted
    }

    /// Set once a grant is seen, so a later missing grant can be told apart
    /// from a first-time setup (see the file comment).
    static func rememberGrantIfTrusted() {
        if isGranted {
            AppConfig.accessibilityGrantedOnce = true
        }
    }

    private static var didPromptOnDemandThisLaunch = false

    /// Ask macOS to show the grant prompt and open the Accessibility pane in
    /// System Settings. For user-initiated flows (the walkthrough, the Settings
    /// row, the help menus); feature code that would prompt on a failed click
    /// goes through `promptOnDemand()` instead.
    @discardableResult
    static func request() -> Bool {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The implicit prompt for a feature that just failed without the
    /// permission. Only before the user dealt with setup, and at most once per
    /// launch: repeated failed clicks must not re-nag.
    static func promptOnDemand() {
        guard shouldPromptOnDemand, !didPromptOnDemandThisLaunch else { return }
        didPromptOnDemandThisLaunch = true
        request()
    }

    /// Deep link into the Accessibility list in System Settings.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Offer to open the exact settings pane, used when the user asked for
    /// something that needs the permission and it is not granted. When a grant
    /// existed before, the switch(es) in the pane belong to another build, so
    /// the alert explains how to hand the grant over to the running copy.
    static func presentHelp() {
        let staleGrant = AppConfig.accessibilityGrantedOnce
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        if staleGrant {
            alert.informativeText = """
                iMonitor was granted Accessibility before, but that grant is pinned to a \
                different build or copy: macOS ties the permission to the exact app build, \
                and a build made without iMonitor's signing certificate gets a new identity \
                every time it is rebuilt.

                To fix it: remove every iMonitor entry in the list with the "\u{2212}" button, \
                then choose "Fix Accessibility Permission\u{2026}" again - the running copy \
                re-adds itself to the list when asked. If it still does not appear, relaunch \
                iMonitor first.
                """
        } else {
            alert.informativeText = """
                To list the menu-bar icons hidden behind the camera notch, iMonitor \
                needs the Accessibility permission (System Settings › Privacy & \
                Security › Accessibility).
                """
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if staleGrant {
                // Make sure the running copy is (re-)listed: after the user
                // removes the stale entries this ask is what adds this build
                // back; macOS ignores it while a fresh entry already exists.
                request()
            }
            openSystemSettings()
        }
    }

    /// Posted after the app returns to the foreground, so a view or controller
    /// can re-read `state` once the user had a chance to grant the permission.
    static let mayHaveChangedNotification = Notification.Name("iMonitorAccessibilityMayHaveChanged")
}
