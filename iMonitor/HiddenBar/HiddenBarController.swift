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
//  - opt-in hover-to-expand limited to EMPTY menu-bar space: a pointer heading
//    for an app menu or another icon, or a click in the bar, never reveals
//    the hidden icons
//  - the context menu carries iMonitor's own actions (Settings, Quit)
//  - hiding mechanics live in a MenuBarEngine (legacy length inflation on
//    macOS <= 26, native visibility on macOS 27)
//  - on macOS 27 a click on macOS's own items (clock/calendar, Wi-Fi, Control
//    Center), which native hiding leaves inert, is passed through by
//    SystemItemClickForwarder
//

import Cocoa

class HiddenBarController: NSObject, HiddenMenuItemProvider {

    // MARK: - Bar items

    let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let separatorItem = NSStatusBar.system.statusItem(withLength: 1)

    private let notchOverflowController = NotchOverflowController()
    private lazy var menuBarEngine: MenuBarEngine = MenuBarEngineFactory.make(items: self)
    private lazy var systemItemClickForwarder = SystemItemClickForwarder(
        isActive: { [weak self] in self?.forwardsSystemItemClicks ?? false },
        liftHiding: { [weak self] press in self?.liftHidingForSystemItem(press) ?? false })

    private var timer: Timer?
    private var isToggle = false
    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    // Where the pointer came to rest. Moving further than hoverRestTolerance
    // restarts the dwell, so only a pointer that actually stops can reveal.
    private var hoverAnchor: NSPoint?
    // Set by a click in the menu bar - the user is busy with something already
    // visible - and cleared once the pointer leaves the bar.
    private var isHoverSuppressed = false
    private var isHoverProbeInFlight = false
    // The current expansion is a hover peek: it hides again shortly after the
    // pointer leaves the bar, unless a click turned it into a regular one.
    private var isExpandedByHover = false
    // Whether the pointer was in the bar at the global monitor's last event,
    // to catch it leaving.
    private var isPointerInMenuBar = false
    // Set when the user asked for a state change that stalled on the missing
    // Accessibility permission; the matching applicationDidBecomeActive retries it.
    private var isWaitingForAuthorization = false

    // The user's intended hiding state. The engine's own state is derived from
    // what the bar currently shows, so a foreign menu's relayout resetting the
    // separator would make it read "expanded" and no one would put the hiding
    // back; this records what the user actually asked for.
    private var wantsCollapsed = false
    // Whether some menu (this app's or another app's) is tracking. While one
    // is, auto-collapse defers and hover never reveals; after one closes, a
    // collapsed bar re-asserts its hiding (see scheduleCollapseReassertion).
    private var isExternalMenuTracking = false
    private var collapseReassertWorkItem: DispatchWorkItem?
    private var menuBarClickMonitor: Any?

    // Set while a menu that this feature spawned is on screen, so the
    // auto-collapse timer can defer instead of closing the menu under the user.
    private(set) static var isMenuPresented = false

    private static let expandedArrowTooltip = "Hide the menu-bar icons to the left of this arrow"
    private static let collapsedArrowTooltip = "Show the hidden menu-bar icons"

    // Pointer jitter tolerated while it counts as resting.
    private static let hoverRestTolerance: CGFloat = 4
    // How soon a hover peek hides again once the pointer has left the bar.
    private static let hoverPeekRehideDelay: TimeInterval = 1.0

    // Every app's menu tracking - this app's included - is broadcast under
    // HIToolbox's names; NSMenuDidBeginTrackingNotification is only ever
    // posted to the tracking app's own notification center.
    private static let menuTrackingBeganNotification = NSNotification.Name(
        "com.apple.HIToolbox.beginMenuTrackingNotification")
    private static let menuTrackingEndedNotification = NSNotification.Name(
        "com.apple.HIToolbox.endMenuTrackingNotification")

    // MARK: - Init

    override init() {
        super.init()
        setupUI()
        restoreRemovedStatusItems()
        setupPointerMonitors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePreferencesChanged),
            name: AppConfig.preferencesChangedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // Fired for EVERY menu on the system, this app's included: opening or
        // closing a menu-bar menu makes macOS 26 relayout the bar, which can
        // reset the inflated separator and pop the hidden icons back out
        // exactly when the user clicks another app's icon. Deliver-immediately,
        // so AppKit's suspension of distributed notifications while the app is
        // inactive (a menu-bar app nearly always is) never holds them back.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleExternalMenuTrackingBegan),
            name: Self.menuTrackingBeganNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleExternalMenuTrackingEnded),
            name: Self.menuTrackingEndedNotification, object: nil,
            suspensionBehavior: .deliverImmediately)

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
        DistributedNotificationCenter.default().removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = menuBarClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Remove every status item this feature owns. Used when the user turns the
    /// feature off (the settings pane restarts the app right after).
    func tearDown() {
        timer?.invalidate()
        timer = nil
        cancelHoverDwell()
        systemItemClickForwarder.cancel()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
        if let monitor = menuBarClickMonitor {
            NSEvent.removeMonitor(monitor)
            menuBarClickMonitor = nil
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

    // MARK: - Pointer monitoring

    // Global monitors never see events over this app's own windows (the arrow,
    // the panel). That suits hover-to-expand, which is about the bar's empty
    // stretch; clicks on the arrow arrive through its own action instead.
    private func setupPointerMonitors() {
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] _ in
            self?.handlePointerMoved()
        }
        // Clicks in the bar suppress hover reveals until the pointer leaves it.
        // They also schedule a re-assertion, a self-heal in case the
        // menu-tracking broadcasts ever stop arriving: a hiding that a foreign
        // menu's relayout reset comes back on its own. Left clicks on macOS's
        // own items go to SystemItemClickForwarder too, releases included.
        menuBarClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.handleGlobalClick(event)
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            // Wherever it lands: the forwarder only acts on the release of a
            // press it saw begin on one of macOS's items.
            systemItemClickForwarder.mouseUp(event)
        case .leftMouseDown:
            // A new press supersedes one whose release this monitor never saw
            // (released over this app's own windows).
            systemItemClickForwarder.cancel()
            guard isMouseInMenuBar else { return }
            handleMenuBarClick()
            systemItemClickForwarder.mouseDown(event)
        default:
            guard isMouseInMenuBar else { return }
            handleMenuBarClick()
        }
    }

    // MARK: - Hover to expand

    // Opt-in via `hideHoverToExpandEnabled`, read live so the settings toggle
    // needs no restart. Only an EMPTY stretch of the bar counts - on the
    // arrow's hidden side, past the frontmost app's menus, on no icon - and
    // only once the pointer has come to rest there for
    // `hideHoverExpandSeconds`. A pointer passing through on its way to an app
    // menu or another icon, or any click in the bar, never reveals the hidden
    // icons. The arrow itself never hover-expands: a click on it expands, and
    // a hover expansion would turn that click into a collapse. A reveal is a
    // peek that hides again once the pointer leaves
    // the bar (see pointerDidLeaveMenuBar).
    private func handlePointerMoved() {
        let isInBar = isMouseInMenuBar
        if isInBar != isPointerInMenuBar {
            isPointerInMenuBar = isInBar
            if !isInBar {
                pointerDidLeaveMenuBar()
            }
        }
        guard isInBar, mayRevealOnHover else {
            cancelHoverDwell()
            return
        }
        let location = NSEvent.mouseLocation
        if hoverDwellTimer != nil, let anchor = hoverAnchor,
            hypot(location.x - anchor.x, location.y - anchor.y) <= Self.hoverRestTolerance
        {
            return  // Still resting: let the running dwell finish.
        }
        hoverAnchor = location
        hoverDwellTimer?.invalidate()
        let dwell = max(AppConfig.hideHoverExpandSeconds, AppConfig.minimumHoverExpandSeconds)
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) {
            [weak self] _ in
            self?.hoverDwellElapsed()
        }
    }

    private func hoverDwellElapsed() {
        hoverDwellTimer = nil
        let location = NSEvent.mouseLocation
        guard !isHoverProbeInFlight, isClearToRevealOnHover,
            let probePoint = hoverProbePoint(for: location)
        else { return }
        isHoverProbeInFlight = true
        MenuBarHitTester.probe(at: probePoint) { [weak self] hit in
            guard let self = self else { return }
            self.isHoverProbeInFlight = false
            let isEmpty =
                hit == .emptySpace
                || (hit == .ownItem && self.isOverInflatedSeparator(location))
            let now = NSEvent.mouseLocation
            // Re-checked: the hit-test took a moment, and the pointer may have
            // moved on or a menu opened since.
            guard isEmpty, self.isClearToRevealOnHover,
                hypot(now.x - location.x, now.y - location.y) <= Self.hoverRestTolerance
            else { return }
            self.expandMenubar(reason: "hover on empty menu-bar space")
            self.isExpandedByHover = true
        }
    }

    // Cheap enough to check on every mouse move.
    private var mayRevealOnHover: Bool {
        return AppConfig.hideHoverToExpandEnabled && wantsCollapsed && isCollapsed
            && !isHoverSuppressed
    }

    // Checked once a dwell completes, before and after the hit-test.
    private var isClearToRevealOnHover: Bool {
        return mayRevealOnHover && isMouseInMenuBar && NSEvent.pressedMouseButtons == 0
            && !isOwnPanelVisible && !Self.isMenuPresented && !isExternalMenuTracking
            && !Self.isPopUpMenuOnScreen
    }

    /// Where to hit-test for a pointer at `location`, or nil when it is not on
    /// the arrow's hidden side of a menu bar. Probes the bar's vertical middle,
    /// so a pointer pinned against the screen's top edge still lands on the
    /// bar's content.
    private func hoverProbePoint(for location: NSPoint) -> NSPoint? {
        guard let screen = Self.menuBarScreen(containing: location),
            let arrowWindow = toggleItem.button?.window
        else { return nil }
        let arrowScreen = arrowWindow.screen ?? screen
        guard
            MenuBarHoverZone.contains(
                x: location.x, screenFrame: screen.frame, arrowFrame: arrowWindow.frame,
                arrowScreenFrame: arrowScreen.frame,
                notch: MenuBarHoverZone.notchSpan(of: screen),
                isLTR: MenuBarOrder.isUsingLTRLanguage)
        else { return nil }
        return NSPoint(x: location.x, y: (screen.visibleFrame.maxY + screen.frame.maxY) / 2)
    }

    // On macOS <= 26 the collapsed bar's empty stretch is this app's own
    // inflated separator, which hit-tests as one of its own items. Under native
    // hiding the separator is off the bar while collapsed.
    private func isOverInflatedSeparator(_ location: NSPoint) -> Bool {
        guard separatorItem.isVisible, let frame = separatorItem.button?.window?.frame
        else { return false }
        return frame.contains(location)
    }

    // Some app's menu is open: windows at the pop-up menu level are menus (or
    // similar transient pop-ups). Ground truth that needs no broadcast.
    private static var isPopUpMenuOnScreen: Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    private func pointerDidLeaveMenuBar() {
        isHoverSuppressed = false
        cancelHoverDwell()
        if isExpandedByHover {
            startTimerToAutoHide(after: Self.hoverPeekRehideDelay)
        }
    }

    // A click in the bar is aimed at something already visible: no reveal may
    // land under it, and a peek the user clicked into (opening one of the
    // revealed icons) becomes a regular expansion under the auto-collapse
    // setting, so it is not pulled away from under that icon's menu.
    private func handleMenuBarClick() {
        isHoverSuppressed = true
        cancelHoverDwell()
        if isExpandedByHover {
            isExpandedByHover = false
            timer?.invalidate()
            timer = nil
            autoCollapseIfNeeded()
        }
        scheduleCollapseReassertion(after: 1.0)
    }

    private func cancelHoverDwell() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
        hoverAnchor = nil
    }

    // MARK: - macOS's own items under native hiding

    /// Whether a click on one of macOS's own items needs passing through: only
    /// while the user wants the bar collapsed and the engine's hiding leaves
    /// those items inert (macOS 27's native hiding).
    private var forwardsSystemItemClicks: Bool {
        return wantsCollapsed && isCollapsed && menuBarEngine.blocksSystemItemClicks
    }

    /// Lifts the hiding around one press on a system item: the hidden icons pop
    /// out for a moment and hide again, while the panel or menu the press
    /// opened stays up.
    private func liftHidingForSystemItem(_ press: @escaping () -> Void) -> Bool {
        return menuBarEngine.liftHidingBriefly(for: press) { [weak self] result in
            switch result {
            case .collapsed:
                self?.didCollapseMenuBar()
            case .unavailable:
                self?.didFailToCollapseMenuBar()
            }
        }
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
        return Self.menuBarScreen(containing: NSEvent.mouseLocation) != nil
    }

    private static func menuBarScreen(containing point: NSPoint) -> NSScreen? {
        return NSScreen.screens.first { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX
                && point.y >= screen.visibleFrame.maxY && point.y <= screen.frame.maxY
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
            || isExternalMenuTracking
    }

    // MARK: - Actions

    @objc private func toggleButtonPressed(sender: NSStatusBarButton) {
        // A click on the arrow is a click in the bar too, one the global
        // monitor never sees: no hover reveal may follow right after it.
        isHoverSuppressed = true
        cancelHoverDwell()
        let event = NSApp.currentEvent
        // clickCount is only defined for mouse events (reading it off any other
        // event raises).
        let clickCount = event?.type == .leftMouseUp ? event?.clickCount ?? 1 : 1
        // AXPress synthesis carries no NSEvent; the resolver maps nil to .toggle
        // so VoiceOver can operate the bar.
        switch ExpandCollapseActionResolver.action(
            eventType: event?.type,
            optionPressed: event?.modifierFlags.contains(.option) ?? false,
            clickCount: clickCount)
        {
        case .toggle:
            toggleExpandedCollapsed()
        case .showItemsList:
            showItemsListAfterDoubleClick()
        case .ignore:
            break
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
        // A click reveals the hidden icons on the bar itself, to the arrow's
        // left; a double-click pops them down as a list instead (see
        // showItemsListAfterDoubleClick).
        // wantsCollapsed, not the derived engine state: a foreign menu's
        // relayout can reset the separator and make the engine misread the bar
        // as expanded, which would turn this click into a collapse.
        if wantsCollapsed {
            expandMenubar(reason: "arrow click")
        } else {
            collapseIfPossible()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }

    // The second click of a double-click on the arrow: every menu-bar icon in
    // one list popped down from the arrow, over a collapsed bar - the list
    // stands in for the reveal, so the bar does not reshuffle under it. The
    // pair's first click has toggled the bar already; put the hiding back if
    // that click revealed it (the same undo as a double-click on iMonitor's
    // own icon, whose first click opened the panel). Without the dropdown
    // feature a double-click is just a click, and the first one's toggle
    // stands.
    private func showItemsListAfterDoubleClick() {
        AppLogger.info("HiddenBar: arrow double-click -> menu-bar items list")
        guard AppConfig.notchOverflowEnabled else { return }
        if !wantsCollapsed {
            // Mid-collapse (the first click collapsed an expanded bar), the
            // engine ignores this request and the one in flight finishes.
            collapseIfPossible()
        }
        // Next tick: showOverflowMenu ends in performClick on this same button
        // (menu tracking), which must not re-enter the click currently being
        // dispatched.
        DispatchQueue.main.async { [weak self] in
            self?.openOverflowMenu()
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
        wantsCollapsed = false
        isExpandedByHover = false
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
            button.toolTip = Self.expandedArrowTooltip
        }
    }

    private func didCollapseMenuBar() {
        wantsCollapsed = true
        isExpandedByHover = false
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.collapseImage
            button.toolTip = Self.collapsedArrowTooltip
        }
    }

    // Logged with its trigger, so "the hidden icons came back by themselves"
    // can be traced to what asked for it.
    private func expandMenubar(reason: String) {
        AppLogger.info("HiddenBar: expanding the menu bar (\(reason))")
        wantsCollapsed = false
        isExpandedByHover = false
        // The bar is about to be unrestricted: a click on one of macOS's items
        // in progress goes through by itself now.
        systemItemClickForwarder.cancel()
        menuBarEngine.expand()
        if let button = toggleItem.button {
            button.image = HiddenBarAssets.expandImage
            button.toolTip = Self.expandedArrowTooltip
        }
        autoCollapseIfNeeded()
    }

    // The app came back to the foreground (usually straight from System Settings
    // › Accessibility). Re-attempt the collapse the user had asked for.
    @objc private func handleApplicationDidBecomeActive() {
        guard isWaitingForAuthorization, AccessibilityPermission.isGranted else { return }
        isWaitingForAuthorization = false
        collapseIfPossible()
    }

    // MARK: - Foreign menu-bar menus

    // Opening or closing any menu-bar menu makes macOS relayout the bar, and on
    // macOS 26 that relayout can reset the inflated separator - the hidden
    // icons pop back out exactly when the user clicks another app's icon. While
    // such a menu tracks, auto-collapse also defers; when one closes, a
    // collapsed bar puts its hiding back.
    @objc private func handleExternalMenuTrackingBegan() {
        isExternalMenuTracking = true
        collapseReassertWorkItem?.cancel()
        collapseReassertWorkItem = nil
        scheduleCollapseReassertion(after: 0.3)
    }

    @objc private func handleExternalMenuTrackingEnded() {
        isExternalMenuTracking = false
        scheduleCollapseReassertion(after: 0.3)
    }

    /// Puts the hiding back if the user wanted the bar collapsed: a short delay
    /// lets the relayout that reset the separator settle first. Idempotent when
    /// nothing was reset.
    private func scheduleCollapseReassertion(after delay: TimeInterval) {
        guard wantsCollapsed else { return }
        collapseReassertWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantsCollapsed else { return }
            self.menuBarEngine.invalidateLayout()
            self.collapseIfPossible()
        }
        collapseReassertWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
        expandMenubar(reason: "rearranging icons")
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

    private func startTimerToAutoHide(
        after interval: TimeInterval = AppConfig.hideAutoCollapseSeconds
    ) {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            guard let self = self else { return }
            // A hover peek hides again by itself even with auto-collapse off;
            // any other expansion follows the setting.
            guard self.isExpandedByHover || AppConfig.hideAutoCollapseEnabled else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons) or an iMonitor panel is
            // open, defer and re-arm. Intentionally unbounded; each re-arm
            // invalidates the previous timer, so deferral never accumulates timers.
            if self.shouldDeferAutoCollapse {
                self.startTimerToAutoHide(
                    after: self.isExpandedByHover
                        ? Self.hoverPeekRehideDelay : AppConfig.hideAutoCollapseSeconds)
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
    /// Popped down from the arrow by a double-click on it.
    func openOverflowMenu() {
        notchOverflowController.showOverflowMenu(near: toggleItem)
    }

    /// Full expansion for the shared menu's "Expand Menu Bar" action.
    func expandMenuBar() {
        expandMenubar(reason: "Expand Menu Bar menu item")
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
        // display hot-plug leaves the separator at a stale length. wantsCollapsed,
        // not the derived engine state: the very relayout being repaired can
        // make the engine misread the bar as expanded.
        let wasCollapsed = wantsCollapsed
        menuBarEngine.invalidateLayout()
        if wasCollapsed {
            collapseIfPossible()
        }
    }
}
