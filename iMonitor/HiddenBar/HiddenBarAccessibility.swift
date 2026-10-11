//
//  HiddenBarAccessibility.swift
//  iMonitor
//
//  Compatibility shim: the shared prompt and deep link now live in
//  AccessibilityPermission, so every caller gets the same wording and behaviour.
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//

import Cocoa

/// Showing which icons sit behind the notch needs the Accessibility permission
/// (reading every other app's status items). Use `AccessibilityPermission`
/// directly in new code.
enum HiddenBarAccessibility {

    static func presentHelp() {
        AccessibilityPermission.presentHelp()
    }

    /// Deep link into the Accessibility list in System Settings.
    static func openSystemSettings() {
        AccessibilityPermission.openSystemSettings()
    }
}
