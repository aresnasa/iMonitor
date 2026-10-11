//
//  HiddenBarController.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//
//  Menu-bar icon hiding, adapted to iMonitor:
//  - the arrow and separator live beside iMonitor's own status item
//  - auto-collapse timer with an in-menu-bar deferral (never yanks the bar shut
//    while the pointer is in it, or while an iMonitor panel is open)
//  - the context menu carries iMonitor's own actions (Settings, Quit)
//  - hiding mechanics live in a MenuBarEngine (legacy length inflation on
//    macOS <= 26, native visibility on macOS 27)
//

import Cocoa

class HiddenBarController: NSObject, HiddenMenuItemProvider {

    // MARK: - Bar items

    let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let separatorItem = NSStatusBar.system.statusItem(withLength: 1)

    private let notchOverflowController = NotchOverflowController()
    private lazy var menuBarEngine: MenuBarEngine = MenuBarEngineFactory.make(items: self)

    private var timer: Timer?
    private var isToggle = false
    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    // Set when the user asked for a state change that stalled on the missing
    // Accessibility permission; the matching applicationDidBecomeActive retries it.
    private var isWaitingForAuthorization = false

    // Set while a menu that this feature spawned is on screen, so the
    // auto-collapse timer can defer instead of closing the menu under the user.
    private(set) static var isMenuPresented = false

    // MARK: - Init

    override init() {
        super.init()
        setupUI()
        restoreRemovedStatusItems()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePreferencesChanged),
            name: AppConfig.preferencesChangedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        // Collapse shortly after launch, mirroring Hidden Bar: the hidden zone is
        // hidden until the user asks for it. Deferred so the bar has settled: the
        // native engine reads the bar's arrangement on the first collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, AppConfig.hideMenuBarEnabled else { return }
            self.collapseIfPossible()
        }

        // The notch overflow popup can rearrange icons by ⌘-dragging its rows;
        // such a drag needs the bar expanded, so it borrows the collapse engine.
        notchOverflowController.prepareForRearrangement = { [weak self] completion in
            guard let self = self else {
                completion(false)
                return
            }
            self.temporarilyExpandForRearrangement(completion: completion)
        }
        notchOverflowController.collapseAfterRearrangement = { [weak self] expanded in
            self?.restoreAfterRearrangement(expanded: expanded)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Remove every status item this feature owns. Used when the user turns the
    /// feature off (the settings pane restarts the app right after).
    func tearDown() {
        timer?.invalidate()
        timer = nil
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
        menuBarEngine.expand()
        NSStatusBar.system.removeStatusItem(toggleItem)
        NSStatusBar.system.removeStatusItem(separatorItem)
    }

    // MARK: - Setup

    private func setupUI() {
        if let button = separatorItem.button {
            button.image = HiddenBarAssets.separatorImage
            button.target = self
            button.action = #selector(showContextMenuFromSeparator(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
            button.target = self
            button.action = #selector(toggleButtonPressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Hide or show the menu-bar icons to the left of this arrow"
        }

        toggleItem.autosaveName = "imonitor_hiddenbar_expandcollapse"
        separatorItem.autosaveName = "imonitor_hiddenbar_separate"
        // Removal is allowed so the items participate in the system menu-bar
        // management flow (on macOS 26+ the user manages them in System Settings
        // › Control Center › Menu Bar). The controller re-adds them at launch.
        toggleItem.behavior = [.removalAllowed]
        separatorItem.behavior = [.removalAllowed]
    }

    private func restoreRemovedStatusItems() {
        // ⌘-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the feature unreachable. These items are the
        // feature's only UI, so they self-restore at launch.
        toggleItem.isVisible = true
        separatorItem.isVisible = true
        // Create the engine now so one that does not use the separator (macOS 27
        // native hiding) takes it back out before it is ever drawn.
        _ = menuBarEngine
    }

    // Opt-in: expand when the pointer dwells in the menu bar. No monitor is
    // installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard AppConfig.hideHoverToExpandEnabled else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
                [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
            }
        }
    }

    // MARK: - State

    private var isCollapsed: Bool {
        return menuBarEngine.state == .collapsed
    }

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height
    // there). On fullscreen spaces the menubar is hidden and the band collapses
    // to ~zero, so this returns false there: intentional, no visible menubar =
    // no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // An open iMonitor panel (or its settings) is an ordinary window, not in the
    // menu bar, so the mouse guard does not cover it. Collapsing while it is open
    // would shuffle the bar under the user mid-task.
    private var isOwnPanelVisible: Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        return delegate.containerIsVisible
    }

    private var shouldDeferAutoCollapse: Bool {
        return isMouseInMenuBar || isOwnPanelVisible || Self.isMenuPresented
    }

    // MARK: - Actions

    @objc private func toggleButtonPressed(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // AXPress synthesis carries no NSEvent; the resolver maps nil to .toggle
        // so VoiceOver can operate the bar.
        switch ExpandCollapseActionResolver.action(
            eventType: event?.type,
            optionPressed: event?.modifierFlags.contains(.option) ?? false)
        {
        case .toggle:
            toggleExpandedCollapsed()
        case .contextMenu:
            showContextMenu(from: sender)
        case .toggleSeparators:
            // Separators have no show/hide toggle here; reach for the menu.
            showContextMenu(from: sender)
        }
    }

    @objc private func showContextMenuFromSeparator(sender: NSStatusBarButton) {
        showContextMenu(from: sender)
    }

    func toggleExpandedCollapsed() {
        // Prevent rapid clicks from stacking hide/show animations.
        if isToggle { return }
        isToggle = true
        self.isCollapsed ? self.expandMenubar() : self.collapseIfPossible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }

    // MARK: - Collapse / expand

    private func collapseIfPossible() {
        guard menuBarEngine.isArrangementValid else {
            autoCollapseIfNeeded()
            return
        }

        menuBarEngine.collapse { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .collapsed:
                self.didCollapseMenuBar()
            case .unavailable:
                self.didFailToCollapseMenuBar()
                if !AccessibilityPermission.isGranted {
                    // Remember that a later applicationDidBecomeActive should retry,
                    // which is exactly what happens after the user grants the
                    // permission in System Settings and comes back.
                    self.isWaitingForAuthorization = true
                    AccessibilityPermission.request()
                }
            }
        }
    }

    // Nothing was hidden (the engine cannot hide on this system, the bar has no
    // hidden section yet, or a permission is pending), so show the bar as
    // expanded.
    private func didFailToCollapseMenuBar() {
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
        }
    }

    // The app came back to the foreground (usually straight from System Settings
    // › Accessibility). Re-attempt the collapse the user had asked for.
    @objc private func handleApplicationDidBecomeActive() {
        guard isWaitingForAuthorization, AccessibilityPermission.isGranted else { return }
        isWaitingForAuthorization = false
        collapseIfPossible()
    }

    private func didCollapseMenuBar() {
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.collapseImage
        }
    }

    private func expandMenubar() {
        guard self.isCollapsed else { return }
        menuBarEngine.expand()
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
        }
        autoCollapseIfNeeded()
    }

    // MARK: - Rearrangement support

    /// Expand the bar if collapsed so a status item can be ⌘-dragged on the
    /// real bar — macOS offers no other way to move one. The completion runs on
    /// the main queue; `true` means the caller must call
    /// `restoreAfterRearrangement` when the drag is done.
    func temporarilyExpandForRearrangement(completion: @escaping (Bool) -> Void) {
        guard isCollapsed else {
            completion(false)
            return
        }
        expandMenubar()
        // Nothing may yank the bar shut while the synthetic drag is in flight.
        timer?.invalidate()
        timer = nil
        // Let the reveal settle before events land on the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            completion(true)
        }
    }

    /// Re-collapse after a rearrangement drag, if it required expanding first.
    func restoreAfterRearrangement(expanded: Bool) {
        guard expanded else { return }
        collapseIfPossible()
    }

    private func autoCollapseIfNeeded() {
        guard AppConfig.hideAutoCollapseEnabled else { return }
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.hideAutoCollapseSeconds, repeats: false
        ) { [weak self] _ in
            guard let self = self, AppConfig.hideAutoCollapseEnabled else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons) or an iMonitor panel is
            // open, defer and re-arm. Intentionally unbounded; each re-arm
            // invalidates the previous timer, so deferral never accumulates timers.
            if self.shouldDeferAutoCollapse {
                self.startTimerToAutoHide()
            } else {
                self.collapseIfPossible()
            }
        }
    }

    // MARK: - Context menu

    // Builds a brand-new NSMenu for every presentation rather than mutating a
    // reused one via a delegate callback (content changes on an
    // already-displayed-before NSMenu instance could leave its backing window at
    // a stale size until an unrelated redraw corrected it).
    //
    // Uses popUp(at:), not performClick(nil): this method is ITSELF called from
    // this same button's own action handler (a real click already in progress).
    // performClick(nil) here would re-enter NSStatusBarButtonCell's own
    // sendAction dispatch, recursing into this handler again.
    //
    // Anchored at the button's top edge (y: 0 on the flipped status button), not
    // at bounds.maxY: for a menu-bar item that is the physical bottom of the
    // screen band, so once "Show Notch Items" makes the menu one row taller the
    // top row lands in the sliver above the visible screen and AppKit shows its
    // "content doesn't fit here" scroll caret instead of rendering it.
    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = buildContextMenu()
        Self.isMenuPresented = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        Self.isMenuPresented = false
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Notch overflow entry: only on notch Macs, and only when enabled.
        if NotchOverflowController.hasNotch && AppConfig.notchOverflowEnabled {
            let overflowItem = NSMenuItem(
                title: "Show Notch Items\u{2026}",
                action: #selector(showNotchOverflow),
                keyEquivalent: "")
            overflowItem.target = self
            menu.addItem(overflowItem)
            menu.addItem(NSMenuItem.separator())
        }

        let toggleAutoHideItem = NSMenuItem(
            title: AppConfig.hideAutoCollapseEnabled
                ? "Disable Auto Collapse" : "Enable Auto Collapse",
            action: #selector(toggleAutoHide),
            keyEquivalent: "")
        toggleAutoHideItem.target = self
        menu.addItem(toggleAutoHideItem)

        let prefItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: "")
        prefItem.target = self
        menu.addItem(prefItem)

        // Same deep link the permission prompt uses, so a user who denied the
        // permission can always get back to the exact pane.
        let accessibilityItem = NSMenuItem(
            title: "Accessibility Settings\u{2026}",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit iMonitor", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func showNotchOverflow() {
        notchOverflowController.showOverflowMenu(near: toggleItem) {
            HiddenBarAccessibility.presentHelp()
        }
    }

    @objc private func toggleAutoHide() {
        AppConfig.hideAutoCollapseEnabled.toggle()
        if AppConfig.hideAutoCollapseEnabled {
            autoCollapseIfNeeded()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    @objc private func openSettings() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.showSettingsFromMenuBar()
    }

    @objc private func openAccessibilitySettings() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openAccessibilitySettingsPane()
        } else {
            AccessibilityPermission.openSystemSettings()
        }
    }

    @objc private func quit() {
        AppDelegate.quit()
    }

    // MARK: - Notifications

    @objc private func handlePreferencesChanged() {
        autoCollapseIfNeeded()
    }

    @objc private func handleScreenParametersChanged() {
        // Re-apply the recomputed length to the LIVE item when collapsed, or a
        // display hot-plug leaves the separator at a stale length.
        let wasCollapsed = isCollapsed
        menuBarEngine.invalidateLayout()
        if wasCollapsed {
            collapseIfPossible()
        }
    }
}
