//
//  NotchDropdownItem.swift
//  iMonitor
//
//  The little dropdown that surfaces the menu-bar icons hidden behind the Mac
//  camera notch. Built on the NotchOverflowController ported from
//  dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

// A single small chevron status item that opens the Notch Overflow menu: the
// icons squeezed off past the notch's left edge cannot be clicked directly, so
// this lists them (and the currently visible ones) and activates a chosen item
// through Accessibility.
//
// Only created when the machine actually has a notch and the user keeps the
// feature on; on clamshell / no-notch setups it never appears.
final class NotchDropdownItem: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let overflowController = NotchOverflowController()

    // Whether the user's hardware can use this at all.
    static var isSupported: Bool {
        return NotchOverflowController.hasNotch
    }

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = HiddenBarAssets.notchDropdownImage
            button.toolTip = "Menu-bar icons hidden behind the camera notch"
            button.target = self
            button.action = #selector(open)
        }
        statusItem.autosaveName = "imonitor_notchdropdown"
        // See HiddenBarController: participates in the system menu-bar management
        // flow so the user can (re)enable it in System Settings › Control Center.
        statusItem.behavior = [.removalAllowed]
        statusItem.isVisible = true
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Remove the item. Used when the user turns the feature off (the settings
    /// pane restarts the app right after).
    func tearDown() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Open the overflow menu anchored to this dropdown. Also called from
    /// iMonitor's own menu-bar menu.
    func openOverflow() {
        NSApp.activate(ignoringOtherApps: true)
        overflowController.showOverflowMenu(near: statusItem) {
            HiddenBarAccessibility.presentHelp()
        }
    }

    /// The popup can rearrange menu-bar icons by ⌘-dragging its rows, which
    /// needs the Hidden Bar expanded for the duration of the drag.
    func configureRearrangement(
        prepare: @escaping (@escaping (Bool) -> Void) -> Void,
        collapse: @escaping (Bool) -> Void
    ) {
        overflowController.prepareForRearrangement = prepare
        overflowController.collapseAfterRearrangement = collapse
    }

    @objc private func open() {
        openOverflow()
    }
}
