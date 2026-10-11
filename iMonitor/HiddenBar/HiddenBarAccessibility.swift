//
//  HiddenBarAccessibility.swift
//  iMonitor
//
//  Shared prompt used by every entry point into the notch-overflow feature.
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

/// Showing which icons sit behind the notch needs the Accessibility permission
/// (reading every other app's status items). Offering to open the exact settings
/// pane is much more use than a bare failure, so all callers share this prompt.
enum HiddenBarAccessibility {

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

    /// Deep link into the Accessibility list in System Settings.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
