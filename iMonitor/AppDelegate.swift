import Cocoa
import ServiceManagement
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Shared instance. `@NSApplicationMain` wires `NSApp.delegate` to this
    /// instance on launch; this convenience lets SwiftUI views reach the
    /// update flow without walking `NSApp.delegate` casts.
    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    var statusBarItem: NSStatusItem!
    var statusBarIcon: StatusBarIconView!
    var panel: NSPanel!
    var contentView: ContentView!
    var network: Network!
    // Hidden Bar feature (ported from dwarvesf/hidden): the arrow/separator pair
    // that hides menu-bar icons, and the menu-bar items dropdown (popped from
    // the main icon - double-click or the menu entry - so it owns no status
    // item and can be toggled live).
    var hiddenBarController: HiddenBarController?
    var menuBarOverflowController: NotchOverflowController?
    // First-launch Accessibility walkthrough. Non-nil only while its window is
    // open; set up on demand and dropped when the user is done.
    private var permissionOnboardingController: PermissionOnboardingController?
    private var didSetupMenuBarFeatures = false
    let updateManager = UpdateManager()
    @ObservedObject var globalModel = SharedStore.globalModel
    @ObservedObject var systemDataModel = SharedStore.systemDataModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    private var refreshTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?
    private var mouseExitWorkItem: DispatchWorkItem?
    // Set while the panel was opened without the mouse on it (from a menu-bar
    // menu): the leave-to-close rule waits until the user has moved into the
    // panel once, so it is not yanked away before they can reach it.
    private var panelAwaitingMouseCustody = false

    /// Default size for the first run; afterwards the panel frame is autosaved
    /// under `panelFrameAutosaveName`, size and position both.
    private static let defaultPanelSize = NSSize(width: 420, height: 460)
    /// Content floor: narrower and the fixed CPU/MEM/GPU/network columns run
    /// out of room and their labels start stacking letters vertically.
    private static let minimumPanelSize = NSSize(width: 380, height: 260)
    /// Upper bound for the content, user-resized or restored. A remembered frame
    /// can be corrupt (a resize that ran past the screen, a display that is
    /// gone); restoring it unchecked leaves the settings section - the content's
    /// top - below the screen.
    private static let maximumPanelSize = NSSize(width: 2400, height: 2400)
    private static let panelFrameAutosaveName = "iMonitorMainPanel"

    static func quit() {
        AppLogger.info("iMonitor quitting")
        NSApplication.shared.terminate(self)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppLogger.installCrashHandlers()

        // Register as login item (auto-launch at startup)
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        } else {
            SMLoginItemSetEnabled("com.aresnasa.iMonitor" as CFString, true)
        }

        self.contentView = ContentView()
        self.network = SharedStore.network

        // Width: bars(4*3+2*2=16) + gap(4) + net text(~48)
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: 68)
        // The stats icon is half of iMonitor's entire UI, so it gets the same
        // permanence as the chevron and the Hidden Bar arrow: an autosave name
        // gives macOS's menu-bar management (System Settings › Control Center)
        // a stable identity instead of the positional "Item-0", and forcing
        // visibility at every launch self-heals an accidental ⌘-drag removal or
        // Control Center toggle.
        self.statusBarItem.autosaveName = "imonitor_stats"
        self.statusBarItem.isVisible = true

        if let button = self.statusBarItem.button {
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            self.statusBarIcon = StatusBarIconView()
            statusBarIcon.frame = NSRect(
                x: 0, y: 0, width: 68, height: NSStatusBar.system.thickness)
            statusBarIcon.autoresizingMask = [.width, .height]

            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(statusBarIcon)
        }

        self.network.startListenNetwork()
        updateStatusBar()
        // A grant that is already in place is remembered before the features
        // start, so a later missing grant can be explained as "another
        // build/copy holds it" instead of looking like a first run.
        AccessibilityPermission.rememberGrantIfTrusted()
        startMenuBarFeaturesIfPossible()
        syncMenuBarOverflowController()
        // The dropdown owns no status item, so its on/off toggle can apply
        // live: keep the controller in step with the settings flag.
        NotificationCenter.default.addObserver(
            self, selector: #selector(overflowPreferencesChanged),
            name: AppConfig.preferencesChangedNotification, object: nil)

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.statusBarRefreshInterval, repeats: true
        ) { [weak self] _ in
            self?.updateStatusBar()
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.charactersIgnoringModifiers == "m" {
                DispatchQueue.main.async { self?.togglePanel(self) }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.charactersIgnoringModifiers == "m" {
                self?.togglePanel(self)
                return nil
            }
            return event
        }
    }

    /// Fired after the user comes back from System Settings (usually to grant
    /// Accessibility). Broadcasts so the menu-bar components re-read the permission.
    func applicationDidBecomeActive(_ notification: Notification) {
        NotificationCenter.default.post(
            name: AccessibilityPermission.mayHaveChangedNotification, object: nil)
        AccessibilityPermission.rememberGrantIfTrusted()
        // The first launch holds the menu-bar features back until Accessibility
        // is granted; the user comes back from System Settings with it granted,
        // so start them now.
        if !didSetupMenuBarFeatures, AccessibilityPermission.isGranted {
            setupHiddenBarFeatures()
        }
    }

    // MARK: - Hidden Bar features (ported from dwarvesf/hidden)

    /// Open System Settings straight to the Accessibility list. Used by the
    /// Hidden Bar context menu.
    func openAccessibilitySettingsPane() {
        AccessibilityPermission.openSystemSettings()
    }

    /// Start the menu-bar features right away when Accessibility is already
    /// granted or the first-launch walkthrough has been dealt with before.
    /// Otherwise the walkthrough runs first and the features start the moment
    /// the grant lands, so granting never needs a relaunch.
    private func startMenuBarFeaturesIfPossible() {
        if AccessibilityPermission.isGranted || AppConfig.permissionOnboardingCompleted {
            setupHiddenBarFeatures()
            return
        }
        presentPermissionOnboarding()
    }

    /// The walkthrough that points at System Settings › Privacy & Security ›
    /// Accessibility. Also offered from the gear menu, so a setup postponed
    /// with "Not Now" can be resumed later.
    func presentPermissionOnboarding() {
        if permissionOnboardingController == nil {
            let controller = PermissionOnboardingController()
            controller.onGranted = { [weak self] in
                self?.setupHiddenBarFeatures()
            }
            controller.onFinished = { [weak self] in
                self?.permissionOnboardingController = nil
                self?.setupHiddenBarFeatures()
            }
            permissionOnboardingController = controller
        }
        permissionOnboardingController?.present()
    }

    private func setupHiddenBarFeatures() {
        guard !didSetupMenuBarFeatures else { return }
        didSetupMenuBarFeatures = true
        AppLogger.info(
            "HiddenBar: launch flags hideMenuBar=\(AppConfig.hideMenuBarEnabled) "
                + "notchOverflow=\(AppConfig.notchOverflowEnabled) hasNotch=\(NotchOverflowController.hasNotch)"
        )
        if AppConfig.hideMenuBarEnabled {
            hiddenBarController = HiddenBarController()
        }
    }

    /// Keep the menu-bar items dropdown in step with its settings toggle.
    /// Unlike the arrow/separator, the dropdown owns no status item - it pops
    /// from the main icon on double-click or via the gear menu - so it can
    /// appear and disappear live, without a restart.
    private func syncMenuBarOverflowController() {
        if AppConfig.notchOverflowEnabled {
            guard menuBarOverflowController == nil else { return }
            let controller = NotchOverflowController()
            // Rearrangement drags borrow the Hidden Bar engine: icons are
            // only ⌘-draggable while the bar is expanded.
            controller.prepareForRearrangement = { [weak self] completion in
                guard let hiddenBar = self?.hiddenBarController else {
                    completion(false)
                    return
                }
                hiddenBar.temporarilyExpandForRearrangement(completion: completion)
            }
            controller.collapseAfterRearrangement = { [weak self] expanded in
                self?.hiddenBarController?.restoreAfterRearrangement(expanded: expanded)
            }
            menuBarOverflowController = controller
        } else {
            menuBarOverflowController = nil
        }
    }

    @objc private func overflowPreferencesChanged() {
        syncMenuBarOverflowController()
    }

    /// Whether any of this app's windows is on screen. The auto-collapse timer
    /// defers while one is, so the menu bar does not reshuffle mid-task.
    var containerIsVisible: Bool {
        return panel?.isVisible ?? false
    }

    /// Open the panel with the settings section showing (menu-bar menu entry).
    func showSettingsFromMenuBar() {
        if panel?.isVisible != true {
            // Opened from a menu: the mouse is not on the panel, so hold it
            // open until the user has moved into it (see handleMouseCheck).
            presentPanel(autoHidesOnMouseLeave: false)
        }
        NotificationCenter.default.post(name: ContentView.showSettingsNotification, object: nil)
    }

    /// Prompt to relaunch after a setting that only applies at launch changed.
    static func presentRestartPrompt() {
        let alert = NSAlert()
        alert.messageText = "Restart iMonitor"
        alert.informativeText = "This menu-bar change needs a restart to take effect."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            quit()
        }
    }

    private func updateStatusBar() {
        guard let icon = statusBarIcon else { return }

        let themeColors = SharedStore.themeModel.colors
        icon.usedColor = themeColors.used.nsColor
        icon.overloadedColor = themeColors.overloaded.nsColor
        icon.freeColor = themeColors.free.nsColor

        icon.cpuUsage = systemDataModel.cpuUsage
        icon.memoryUsage =
            systemDataModel.memoryTotal > 0
            ? Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) : 0
        icon.gpuUsage = systemDataModel.gpuUsage
        icon.totalInBytes = statusDataModel.totalInBytes
        icon.totalOutBytes = statusDataModel.totalOutBytes

        let cpuPct = Int(round(systemDataModel.cpuUsage * 100))
        let memPct =
            systemDataModel.memoryTotal > 0
            ? Int(
                round(
                    Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) * 100))
            : 0
        let gpuPct = Int(round(systemDataModel.gpuUsage * 100))
        let memUsed = formatBytes(Int(systemDataModel.memoryUsed))
        let memTotal = formatBytes(Int(systemDataModel.memoryTotal))
        let upStr = formatBytes(statusDataModel.totalOutBytes) + "/s"
        let dnStr = formatBytes(statusDataModel.totalInBytes) + "/s"

        statusBarItem.button?.toolTip = """
            CPU: \(cpuPct)%
            Memory: \(memUsed)/\(memTotal) (\(memPct)%)
            GPU: \(gpuPct)%
            ↑ Upload: \(upStr)
            ↓ Download: \(dnStr)
            """
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0K" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1fM", mb) }
        let gb = mb / 1024
        return String(format: "%.1fG", gb)
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        // Right-click on the status bar item opens the gear menu instead of
        // toggling the panel. `sendAction(on: [.leftMouseUp, .rightMouseUp])`
        // is set on the button, so we inspect the current event type.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusBarMenu()
            return
        }

        // Double-click opens the menu-bar items dropdown instead of the panel.
        // The first click of the pair toggled the panel already; close it so
        // the list replaces it rather than stacking.
        if let event = NSApp.currentEvent, event.type == .leftMouseUp,
            event.clickCount > 1
        {
            if panel?.isVisible == true {
                closePanel()
            }
            showMenuBarItemsDropdown()
            return
        }

        updateStatusBar()

        if let panel = panel, panel.isVisible {
            closePanel()
            return
        }

        presentPanel()
    }

    /// The open half of the status-item click: activate, build and show the
    /// panel. Deliberately inspects no events, so menu actions can present it
    /// no matter which (possibly stale) event is current.
    private func presentPanel(autoHidesOnMouseLeave: Bool = true) {
        panelAwaitingMouseCustody = !autoHidesOnMouseLeave

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        globalModel.viewShowing = true

        if panel == nil {
            // Resizable, so the process list can be widened past the fixed
            // minimum every row needs; the frame (size *and* position) is
            // autosaved, so the user's sizing survives the next launch.
            let hostingView = NSHostingView(rootView: contentView.withGlobalEnvironmentObjects())
            // The panel's size belongs to the user (and to the frame autosave):
            // without this, showing the settings section lets the hosting view's
            // fitting size grow the window (measured: 419 -> 3349 points tall,
            // most of the panel below the screen).
            if #available(macOS 13.0, *) {
                hostingView.sizingOptions = []
            }
            hostingView.frame.size = NSSize(
                width: Self.defaultPanelSize.width, height: Self.defaultPanelSize.height)

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
                styleMask: [.titled, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.contentView = hostingView
            panel.title = "iMonitor"
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.delegate = self
            // Narrower than this and the fixed metrics lose their slots; a
            // height floor keeps the title bar, overview and a few rows
            // visible whatever is loaded.
            panel.contentMinSize = Self.minimumPanelSize
            panel.contentMaxSize = Self.maximumPanelSize
            // Anchor at the top-right under the menu bar on the first run;
            // afterwards the autosave restores the frame the user sized,
            // however it is now.
            if !panel.setFrameUsingName(Self.panelFrameAutosaveName) {
                positionPanelTopRight(panel)
            } else {
                Self.correctPanelFrame(of: panel)
            }
            panel.setFrameAutosaveName(Self.panelFrameAutosaveName)
            // Persist the corrected frame right away: AppKit would otherwise
            // keep the broken one until the panel next moves or resizes.
            panel.saveFrame(usingName: Self.panelFrameAutosaveName)
            self.panel = panel
        }

        // A panel that grew past the screen (a stale autosave, a display change,
        // a content-driven resize) would put the settings section at its top
        // below the screen; clamp it every time it is shown.
        Self.correctPanelFrame(of: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        startMouseMonitoring()
    }

    private func closePanel() {
        stopMouseMonitoring()
        panel.orderOut(self)
        globalModel.viewShowing = false
        panelAwaitingMouseCustody = false
    }

    /// Build and pop up the status-bar context menu (gear menu).
    /// Shown on right-click of the status item. The exact same menu the
    /// Hidden Bar arrow/separator shows (see makeConfigurationMenu).
    private func showStatusBarMenu() {
        let menu = makeConfigurationMenu()
        if let button = statusBarItem.button {
            // Pop up below the status item. `popUp(positioning:at:in:)` expects
            // a view; the button itself is a valid coordinate space. We place
            // the menu just below the button's bottom edge.
            let loc = NSPoint(x: 0, y: button.bounds.maxY + 4)
            menu.popUp(positioning: nil, at: loc, in: button)
        }
    }

    // MARK: - Shared menu-bar menu

    /// The one configuration menu, shared by every entry point: the main
    /// icon's gear menu and the Hidden Bar arrow/separator context menu are
    /// the same definition, and every action is handled here, so the entries
    /// cannot drift and configuration stays reachable from whichever icon the
    /// user can reach. (The gear menu used to lack Settings and the Auto
    /// Collapse toggle - chevron-only before, so they vanished whenever the
    /// chevron was hidden behind the notch or removed via Control Center -
    /// and the Hidden Bar menu lacked the update check.)
    func makeConfigurationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Check for Updates…
        let updateItem = NSMenuItem(
            title: updateManager.isUpdating ? "Updating…" : "Check for Updates…",
            action: #selector(performUpdateFromMenu(_:)),
            keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = !updateManager.isUpdating
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        var hasBarSection = false

        // Menu-bar dropdown: lists the icons (hidden ones included) and
        // activates them. Offered whenever the dropdown feature is enabled -
        // it pops from this icon (double-click works too), and doubles as a
        // backdoor when the hidden-bar arrow was removed via Control Center.
        if AppConfig.notchOverflowEnabled, menuBarOverflowController != nil {
            let overflowItem = NSMenuItem(
                title: "Show Menu-bar Items\u{2026}",
                action: #selector(showNotchItemsFromMenu(_:)),
                keyEquivalent: "")
            overflowItem.target = self
            menu.addItem(overflowItem)
            hasBarSection = true
        }

        // Collapsed bar: full expansion. A click on the arrow does the same,
        // but this menu is also the main icon's gear menu - the way in when
        // the arrow sits behind the notch or was removed via Control Center.
        if let controller = hiddenBarController, controller.isCollapsed {
            let expandItem = NSMenuItem(
                title: "Expand Menu Bar",
                action: #selector(expandMenuBarFromMenu(_:)),
                keyEquivalent: "")
            expandItem.target = self
            menu.addItem(expandItem)
            hasBarSection = true
        }

        // Auto Collapse flips the Hidden Bar's own timer, so the item only
        // exists while that feature is running. A setting, so a checkmark
        // shows its state, like any macOS menu toggle.
        if hiddenBarController != nil {
            let autoCollapseItem = NSMenuItem(
                title: "Auto Collapse",
                action: #selector(toggleAutoCollapseFromMenu(_:)),
                keyEquivalent: "")
            autoCollapseItem.target = self
            autoCollapseItem.state = AppConfig.hideAutoCollapseEnabled ? .on : .off
            if #available(macOS 26.0, *) {
                // macOS 26+ menus reserve the leading checkmark column only
                // while some item shows a state image: unchecked, the toggle
                // would leave every title flush against the edge, and checking
                // it would shift them all sideways. An invisible checkmark
                // keeps the column - the usual menu indentation - in both states.
                autoCollapseItem.offStateImage = Self.uncheckedStatePlaceholder()
            }
            menu.addItem(autoCollapseItem)
            hasBarSection = true
        }

        if hasBarSection {
            menu.addItem(NSMenuItem.separator())
        }

        // Settings… opens the panel with the settings section showing.
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Missing Accessibility: offer the walkthrough right where a user who
        // noticed the menu-bar features doing nothing would look. When a grant
        // existed before, it belongs to another build/copy, so the item turns
        // into the targeted fix flow instead. With the permission in place,
        // a plain deep link to the pane is enough.
        let accessibilityItem: NSMenuItem
        if AccessibilityPermission.isGranted {
            accessibilityItem = NSMenuItem(
                title: "Accessibility Settings\u{2026}",
                action: #selector(openAccessibilityPaneFromMenu(_:)),
                keyEquivalent: "")
        } else {
            accessibilityItem = NSMenuItem(
                title: AppConfig.accessibilityGrantedOnce
                    ? "Fix Accessibility Permission\u{2026}"
                    : "Accessibility Setup\u{2026}",
                action: #selector(showPermissionSetupFromMenu(_:)),
                keyEquivalent: "")
        }
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit iMonitor",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// A transparent stand-in for the menu checkmark, at the size the system
    /// draws it: the "checkmark" symbol at the menu font's size, small scale,
    /// semibold (13×11 pt at the default size, measured on macOS 27). The
    /// default onStateImage cannot be measured instead - it reports 18×17 and
    /// is scaled down when drawn, while a custom image is drawn as-is.
    private static func uncheckedStatePlaceholder() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold, scale: .small)
        let size =
            NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.size ?? NSSize(width: 13, height: 11)
        return NSImage(size: size, flipped: false) { _ in true }
    }

    @objc private func performUpdateFromMenu(_ sender: AnyObject?) {
        performUpdate()
    }

    @objc private func showNotchItemsFromMenu(_ sender: AnyObject?) {
        showMenuBarItemsDropdown()
    }

    /// The menu-bar items dropdown, popped from the main icon. Shared by the
    /// gear menu's entry and the status item's double-click. Safe to call from
    /// that button's own action: the list is only shown after an async
    /// snapshot (see NotchOverflowController.showOverflowMenu).
    func showMenuBarItemsDropdown() {
        AppLogger.info("Panel: showing the menu-bar items dropdown")
        guard let controller = menuBarOverflowController else { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.showOverflowMenu(near: statusBarItem)
    }

    @objc private func showPermissionSetupFromMenu(_ sender: AnyObject?) {
        if AppConfig.accessibilityGrantedOnce, !AccessibilityPermission.isGranted {
            // The old grant no longer applies to this build; the alert walks
            // through removing the stale entries and re-adding this copy.
            AccessibilityPermission.presentHelp()
        } else {
            presentPermissionOnboarding()
        }
    }

    @objc private func quitFromMenu(_ sender: AnyObject?) {
        AppDelegate.quit()
    }

    @objc private func openSettingsFromMenu(_ sender: AnyObject?) {
        // Menu actions fire while the menu's tracking loop is still unwinding
        // (the gear menu itself pops from inside togglePanel's right-click
        // branch); activating the app and making the panel key in that state
        // does not stick. Let the loop unwind first.
        DispatchQueue.main.async { [weak self] in
            self?.showSettingsFromMenuBar()
        }
    }

    @objc private func openAccessibilityPaneFromMenu(_ sender: AnyObject?) {
        openAccessibilitySettingsPane()
    }

    @objc private func toggleAutoCollapseFromMenu(_ sender: AnyObject?) {
        hiddenBarController?.toggleAutoHide()
    }

    @objc private func expandMenuBarFromMenu(_ sender: AnyObject?) {
        hiddenBarController?.expandMenuBar()
    }

    /// Run the Homebrew self-update flow and relaunch on success.
    /// Shows an alert on failure with an option to open Terminal for manual update.
    func performUpdate() {
        guard !updateManager.isUpdating else { return }

        // If the app isn't running from /Applications, warn early — the
        // upgrade would install to /Applications but this running copy
        // wouldn't be the one replaced, and the relaunch path would be wrong.
        if Bundle.main.bundlePath != UpdateManager.installedAppPath {
            presentAlert(
                title: "Self-update unavailable",
                message: UpdateManager.UpdateError.notInstalledViaBrew.errorDescription ?? "",
                buttons: ["OK"]
            )
            return
        }

        updateManager.performUpdate(
            onProgress: { [weak self] in
                self?.presentUpdatingSheet()
            },
            onComplete: { [weak self] result in
                self?.dismissUpdatingSheet()
                switch result {
                case .success:
                    // Relaunch is already scheduled by UpdateManager.
                    break
                case .failure(let error):
                    self?.presentUpdateFailure(error)
                }
            }
        )
    }

    // MARK: - Update UI helpers

    private var updatingAlert: NSAlert?

    private func presentUpdatingSheet() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Updating iMonitor…"
        alert.informativeText =
            "Running `brew update && brew upgrade --cask imonitor`.\nThe app will relaunch automatically when done."
        alert.addButton(withTitle: "Cancel")
        // Non-blocking: run modal-ish via a detached panel so brew keeps running.
        // We don't actually cancel the brew process — the button just dismisses
        // the alert; the update will still complete in the background.
        alert.buttons.first?.action = #selector(dismissUpdatingAlertFromButton(_:))
        alert.buttons.first?.target = self
        updatingAlert = alert
        if let panel = panel, panel.isVisible {
            alert.beginSheetModal(for: panel) { _ in }
        } else {
            // No panel visible — show as a standalone window so the user gets feedback.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func dismissUpdatingAlertFromButton(_ sender: AnyObject?) {
        dismissUpdatingSheet()
    }

    private func dismissUpdatingSheet() {
        guard let alert = updatingAlert else { return }
        updatingAlert = nil
        if let panel = panel, panel.isVisible, panel.sheetParent != nil,
            panel.attachedSheet === alert.window
        {
            panel.endSheet(alert.window)
        } else {
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func presentUpdateFailure(_ error: UpdateManager.UpdateError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = error.errorDescription ?? "Unknown error."
        alert.addButton(withTitle: "Open in Terminal")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openTerminalForManualUpdate()
        }
    }

    /// Open Terminal with a pre-typed update command so the user can run it manually.
    private func openTerminalForManualUpdate() {
        let script = "brew update && brew upgrade --cask imonitor"
        let appleScript = """
            tell application \"Terminal\"
                activate
                do script \"\(script)\"
            end tell
            """
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }

    private func presentAlert(title: String, message: String, buttons: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()

        mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] _ in
            self?.handleMouseCheck()
        }
        mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] event in
            self?.handleMouseCheck()
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let monitor = mouseGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseGlobalMonitor = nil
        }
        if let monitor = mouseLocalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseLocalMonitor = nil
        }
        mouseExitWorkItem?.cancel()
        mouseExitWorkItem = nil
    }

    private func handleMouseCheck() {
        guard let panel = panel, panel.isVisible else {
            stopMouseMonitoring()
            return
        }

        // Mid-resize the pointer sits on (or just past) the window's edge, and
        // its coordinates trail the frame as the drag moves it: the leave-to-
        // close check below would read "outside" and shut the panel the user
        // is resizing.
        if panel.inLiveResize { return }

        let mouseLoc = NSEvent.mouseLocation
        let panelFrame = panel.frame

        // Check if mouse is over the status bar button
        if let button = statusBarItem.button {
            let buttonFrame =
                button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            if buttonFrame.contains(mouseLoc) { return }
        }

        if panelFrame.contains(mouseLoc) {
            // Mouse is inside the panel — cancel any pending close; from now
            // on the normal leave-to-close applies.
            panelAwaitingMouseCustody = false
            mouseExitWorkItem?.cancel()
            mouseExitWorkItem = nil
        } else if panelAwaitingMouseCustody {
            // The panel was opened from a menu while the mouse was elsewhere;
            // keep it until the user has reached it once (or closes it via the
            // status item).
            return
        } else {
            // Mouse is outside — schedule close with a small delay to avoid flicker
            if mouseExitWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if let panel = self.panel, panel.isVisible {
                        let loc = NSEvent.mouseLocation
                        if !panel.frame.contains(loc) {
                            // Check status bar button too
                            if let button = self.statusBarItem.button {
                                let btnFrame =
                                    button.window?.convertToScreen(
                                        button.convert(button.bounds, to: nil)) ?? .zero
                                if btnFrame.contains(loc) { return }
                            }
                            self.closePanel()
                        }
                    }
                }
                mouseExitWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
            }
        }
    }

    private func positionPanelTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: screenRect.maxX - 440, y: screenRect.maxY - 10))
    }

    /// A restored frame can be stale or broken: clamp it into the screen it
    /// belongs to and to the allowed size, so the panel - and the settings
    /// section at its top - stays reachable.
    private static func correctPanelFrame(of panel: NSPanel) {
        let current = panel.frame
        let screen =
            NSScreen.screens.first { $0.visibleFrame.intersects(current) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let chrome = current.height - panel.contentRect(forFrameRect: current).height
        var content = panel.contentRect(forFrameRect: current).size
        content.width = min(max(content.width, minimumPanelSize.width), maximumPanelSize.width)
        content.height = min(max(content.height, minimumPanelSize.height), maximumPanelSize.height)
        content.width = min(content.width, visible.width)
        content.height = min(
            content.height, max(visible.height - chrome, minimumPanelSize.height))
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        // Keep the remembered top-left corner where it still fits.
        frame.origin.x = current.minX
        frame.origin.y = current.maxY - frame.height
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        guard frame != current else { return }
        AppLogger.info("Panel: correcting the remembered frame \(current) to \(frame)")
        panel.setFrame(frame, display: false)
    }

    func applicationWillResignActive(_ aNotification: Notification) {
        self.globalModel.viewShowing = false
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        globalModel.viewShowing = false
    }
}
