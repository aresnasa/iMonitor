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

    private static let expandedArrowTooltip = "Hide the menu-bar icons to the left of this arrow"
    private static let collapsedArrowTooltip = "Show the hidden menu-bar icons"

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
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
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
            button.toolTip = Self.expandedArrowTooltip
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

    // Hover-to-expand, two zones:
    // - the arrow itself: always active, expands after the configurable
    //   `hideHoverExpandSeconds` dwell (0 = immediately). Delivered by a
    //   tracking area on the button, because a global event monitor never
    //   sees events over this app's own status-item windows.
    // - the whole menu-bar band: opt-in via `hideHoverToExpandEnabled`, read
    //   live so the settings toggle needs no restart; a fixed short dwell so
    //   a pointer merely passing through doesn't expand.
    private func setupHoverToExpandIfEnabled() {
        setupToggleButtonHoverTracking()
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard AppConfig.hideHoverToExpandEnabled,
                self.isCollapsed && self.isMouseInMenuBar
            else {
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

    private func setupToggleButtonHoverTracking() {
        guard let button = toggleItem.button else { return }
        button.addTrackingArea(
            NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self))
    }

    // Entered the arrow's bounds: arm the configured dwell (or expand at once
    // when it is 0). Suppressed while the click debounce is running, or the
    // slide that follows a collapse would instantly re-expand under a pointer
    // that is still resting on the arrow's new position.
    @objc func mouseEntered(with event: NSEvent) {
        guard isCollapsed, !isToggle else { return }
        hoverDwellTimer?.invalidate()
        let delay = AppConfig.hideHoverExpandSeconds
        guard delay > 0 else {
            expandMenubar()
            return
        }
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self = self else { return }
            self.hoverDwellTimer = nil
            if self.isCollapsed {
                self.expandMenubar()
            }
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }

    // MARK: - State

    /// Read by the shared menu (AppDelegate.makeConfigurationMenu) to decide
    /// whether the "Expand Menu Bar" entry is needed.
    var isCollapsed: Bool {
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
        // Collapsed, the arrow opens the hidden-items dropdown instead of
        // expanding: the bar never reshuffles, and every hidden icon stays
        // clickable and ⌘-draggable from the one list. Full expansion remains
        // in the context menu for the one thing the list cannot do - ⌘-dragging
        // the separator on the real bar.
        if isCollapsed, AppConfig.notchOverflowEnabled {
            // Open on the next tick: showOverflowMenu ends in performClick on
            // this same button (menu tracking), which must not re-enter the
            // click currently being dispatched.
            DispatchQueue.main.async { [weak self] in
                self?.openOverflowMenu()
            }
        } else if isCollapsed {
            expandMenubar()
        } else {
            collapseIfPossible()
        }
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
                    // Ask for the permission only while prompting can still help
                    // (first-time setup, once per launch); otherwise the setup
                    // paths in the gear menu and Settings own the guidance.
                    AccessibilityPermission.promptOnDemand()
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
            button.toolTip = Self.expandedArrowTooltip
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
            button.toolTip = Self.collapsedArrowTooltip
        }
    }

    private func expandMenubar() {
        guard self.isCollapsed else { return }
        menuBarEngine.expand()
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
            button.toolTip = Self.expandedArrowTooltip
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
        // The one shared menu (see AppDelegate.makeConfigurationMenu): the
        // gear menu and this context menu are the same definition with the
        // same handlers, so the entries cannot drift.
        guard let delegate = NSApp.delegate as? AppDelegate else {
            // Defensive: the delegate is always there in practice. Keep the
            // item alive with quit rather than showing a dead menu.
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(
                NSMenuItem(
                    title: "Quit iMonitor",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q"))
            return menu
        }
        return delegate.makeConfigurationMenu()
    }

    /// Every menu-bar icon in one dropdown: the fully hidden ones and the ones
    /// squeezed behind the notch, clickable, and ⌘-draggable to rearrange.
    /// The shared menu's "Show Menu-bar Items…" action lands here when the
    /// standalone chevron is off (anchored to the arrow).
    func openOverflowMenu() {
        notchOverflowController.showOverflowMenu(near: toggleItem)
    }

    /// Full expansion for the shared menu's "Expand Menu Bar" action.
    func expandMenuBar() {
        expandMenubar()
    }

    /// Backing of the shared menu's Auto Collapse item: applies the flipped
    /// value to the live timer right away (the settings pane goes through the
    /// preferences-changed notification instead).
    func toggleAutoHide() {
        AppConfig.hideAutoCollapseEnabled.toggle()
        if AppConfig.hideAutoCollapseEnabled {
            autoCollapseIfNeeded()
        } else {
            timer?.invalidate()
            timer = nil
        }
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
