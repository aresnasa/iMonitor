//
//  NotchOverflow.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import ApplicationServices
import Cocoa

// MARK: - Menu Bar Extra Info

struct MenuBarExtraInfo {
    let element: AXUIElement
    let appName: String
    let appIcon: NSImage?
    let title: String?
    let bundleIdentifier: String?
    let pid: pid_t
    let position: CGPoint
    let size: CGSize
}

// MARK: - Notch Geometry

/// Pure geometry: where the notch is and which X coordinates on the menu-bar
/// row it makes unreachable. Kept free of NSScreen/AppKit calls so it can be
/// unit-tested with synthetic screen values instead of live hardware.
struct NotchBoundary: Equatable {
    let hasNotch: Bool
    /// The leftmost X, in screen coordinates, at which a status item is
    /// guaranteed clear of the notch. Items positioned left of this are
    /// either under the notch or squeezed off past its left edge.
    let overflowThresholdX: CGFloat
}

enum NotchGeometry {
    // Matches the pre-fix behavior's default (half of a common 1728pt-wide
    // screen) so a screen that unexpectedly can't report safeAreaInsets still
    // gets a sane threshold instead of 0.
    static let fallbackThresholdX: CGFloat = 972

    /// - Parameters:
    ///   - screenFrame: the candidate screen's full frame (`NSScreen.frame`).
    ///   - safeAreaInsetsTop: `NSScreen.safeAreaInsets.top`; > 0 on notched Macs.
    ///   - auxiliaryTopRightAreaMinX: `NSScreen.auxiliaryTopRightArea?.minX`,
    ///     Apple's own safe-rect boundary for content right of the notch.
    ///     May be reported in global screen coordinates rather than the screen's
    ///     own space; the latter is detected and normalized here so callers can
    ///     pass either.
    static func computeBoundary(
        screenFrame: CGRect,
        safeAreaInsetsTop: CGFloat,
        auxiliaryTopRightAreaMinX: CGFloat?
    ) -> NotchBoundary {
        let hasNotch = safeAreaInsetsTop > 0
        guard hasNotch, var thresholdX = auxiliaryTopRightAreaMinX else {
            return NotchBoundary(hasNotch: hasNotch, overflowThresholdX: fallbackThresholdX)
        }
        if !screenFrame.contains(CGRect(x: thresholdX, y: 0, width: 1, height: 1)) {
            thresholdX += screenFrame.origin.x
        }
        return NotchBoundary(hasNotch: true, overflowThresholdX: thresholdX)
    }
}

// MARK: - Extras Classification

/// Pure classification of already-fetched extras against a boundary. Split
/// from AX enumeration so the sorting/filtering rules are testable without
/// a live Accessibility permission or other running apps.
enum MenuBarExtraClassifier {
    /// Two items whose frames overlap by more than this are treated as crammed
    /// into the same slot. Items that merely touch measure as 1–3pt of overlap
    /// because of AX rounding, so that noise is ignored.
    static let overlapTolerance: CGFloat = 4

    static func classify(
        _ extras: [MenuBarExtraInfo],
        boundary: CGFloat
    ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
        let renderable = extras.filter { $0.size.width > 0 && $0.size.height > 0 }
        let sorted = renderable.sorted { $0.position.x < $1.position.x }

        // Items count as "hidden behind the notch" when the system renders them
        // out of reach, which happens in two ways:
        //  1. They sit left of the notch's clear zone (x < boundary): macOS
        //     parks overflow entries over there.
        //  2. They are squeezed against the notch's right edge until their
        //     slots overlap into one pile of indistinguishable, unclickable
        //     icons. A calm bar never overlaps its items, so an overlapping
        //     run is exactly the set the user lost.
        var isHidden = [Bool](repeating: false, count: sorted.count)
        for i in sorted.indices where sorted[i].position.x < boundary {
            isHidden[i] = true
        }
        var i = 0
        while i < sorted.count {
            var runEnd = sorted[i].position.x + sorted[i].size.width
            var j = i + 1
            while j < sorted.count, sorted[j].position.x + Self.overlapTolerance < runEnd {
                runEnd = max(runEnd, sorted[j].position.x + sorted[j].size.width)
                j += 1
            }
            if j > i + 1 {
                for k in i..<j { isHidden[k] = true }
                i = j
            } else {
                i += 1
            }
        }

        var hidden: [MenuBarExtraInfo] = []
        var visible: [MenuBarExtraInfo] = []
        for (index, item) in sorted.enumerated() {
            if isHidden[index] { hidden.append(item) } else { visible.append(item) }
        }
        return (
            hidden.sorted { $0.position.x > $1.position.x },
            visible.sorted { $0.position.x > $1.position.x }
        )
    }
}

// MARK: - NotchOverflowController

class NotchOverflowController: NSObject, NSMenuDelegate {

    /// The status item whose menu is waiting on the Accessibility grant, so the
    /// menu can be re-opened the moment the user returns from System Settings.
    private weak var itemAwaitingPermission: NSStatusItem?

    /// Rearrangement hooks, filled in by whoever owns the Hidden Bar engine: a
    /// status item can only be ⌘-dragged while the bar shows it, so a collapsed
    /// bar is expanded for the duration of a move and re-collapsed after.
    var prepareForRearrangement: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var collapseAfterRearrangement: (Bool) -> Void = { _ in }

    /// Called with the hosting item just before its menu starts tracking and
    /// again right after the menu closes, so the item can reflect that state in
    /// its glyph. Unused by the hidden-bar arrow, which opens this menu as a
    /// fallback but keeps its own left/right chevrons.
    var onMenuWillPresent: ((NSStatusItem) -> Void)?
    var onMenuDidDismiss: ((NSStatusItem) -> Void)?

    private var dragSession: OverflowDragSession?
    /// The reorderable rows of the menu last built, in display order.
    private var menuRows: [OverflowDragSession.Row] = []
    private var lastHighlightedMenuItem: NSMenuItem?
    /// Guards against one click reaching both the row view and the item action,
    /// which would press a status item twice.
    private var lastActivation: (element: AXUIElement, time: TimeInterval)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAccessibilityMayHaveChanged),
            name: AccessibilityPermission.mayHaveChangedNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notch Detection

    // The notched display, if any is attached and awake. A notched Mac drives
    // the menu bar on the built-in display; with the lid closed there is no
    // notch to overflow under.
    private static var notchedScreen: NSScreen? {
        guard #available(macOS 12.0, *) else { return nil }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private static func currentBoundary() -> NotchBoundary {
        guard #available(macOS 12.0, *), let screen = notchedScreen else {
            return NotchBoundary(
                hasNotch: false, overflowThresholdX: NotchGeometry.fallbackThresholdX)
        }
        return NotchGeometry.computeBoundary(
            screenFrame: screen.frame,
            safeAreaInsetsTop: screen.safeAreaInsets.top,
            auxiliaryTopRightAreaMinX: screen.auxiliaryTopRightArea?.minX
        )
    }

    static var hasNotch: Bool {
        currentBoundary().hasNotch
    }

    /// Show the overflow menu anchored to a status item. Safe to call from that
    /// item's own action: the menu is only *shown* after an async snapshot, by
    /// which time the originating click has finished dispatching (never call
    /// performClick re-entrantly from within the button's own action).
    func showOverflowMenu(near item: NSStatusItem) {
        guard Permission.isGranted else {
            // Prompt only while it can still help (first-time setup); once the
            // user dealt with setup - or holds a grant for another build - the
            // guided menu below explains the fix instead of re-prompting.
            Permission.promptOnDemand()
            presentPermissionGuidedMenu(for: item)
            return
        }
        let boundary = Self.currentBoundary().overflowThresholdX
        item.button?.highlight(true)
        getAllMenuBarExtras { [weak self] extras in
            item.button?.highlight(false)
            guard let self = self else { return }
            let menu = self.buildOverflowMenu(extras: extras, boundary: boundary)
            item.menu = menu
            self.onMenuWillPresent?(item)
            item.button?.performClick(nil)
            // performClick runs the menu's tracking loop, so this line is only
            // reached once the menu has closed.
            self.onMenuDidDismiss?(item)
            // Detach so the next left click runs the button action again instead
            // of re-opening a stale menu.
            DispatchQueue.main.async {
                item.menu = nil
            }
        }
    }

    // Looks exactly like the real overflow menu, but explains the permission
    // instead of leaving the user with "No items found".
    private func presentPermissionGuidedMenu(for item: NSStatusItem) {
        itemAwaitingPermission = item
        item.menu = buildOverflowMenu(needsAccessibilityHelp: true)
        onMenuWillPresent?(item)
        item.button?.performClick(nil)
        onMenuDidDismiss?(item)
        DispatchQueue.main.async {
            item.menu = nil
        }
    }

    // Re-open the live menu once the user comes back from System Settings with
    // the permission granted, so granting does not first look like a no-op.
    @objc private func handleAccessibilityMayHaveChanged() {
        guard Permission.isGranted else { return }
        guard let item = itemAwaitingPermission else { return }
        itemAwaitingPermission = nil
        DispatchQueue.main.async { [weak self] in
            self?.showOverflowMenu(near: item)
        }
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        Permission.openSystemSettings()
    }

    // Stale-grant case: re-ask macOS so the running copy gets (back) into the
    // Accessibility list - after the user removes the old entries this is what
    // adds this build - and open the pane to do the removing.
    @objc private func grantThisCopy(_ sender: NSMenuItem) {
        Permission.request()
        Permission.openSystemSettings()
    }

    // MARK: - Menu Building

    /// - Parameter needsAccessibilityHelp: show the accessibility-permission section
    ///   (and no live extras) when Accessibility is not granted. Without it the menu
    ///   would just read "No items found", which looks like a plain bug.
    func buildOverflowMenu(
        extras: [MenuBarExtraInfo]? = nil,
        boundary: CGFloat? = nil,
        needsAccessibilityHelp: Bool = false
    ) -> NSMenu {
        let allExtras = extras ?? []
        let resolvedBoundary = boundary ?? Self.currentBoundary().overflowThresholdX
        // The notch split only means something on notched hardware; anywhere
        // else every icon goes into one flat list.
        let classified: (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) =
            Self.hasNotch
            ? MenuBarExtraClassifier.classify(allExtras, boundary: resolvedBoundary)
            : (hidden: [], visible: allExtras)
        // The arrangement the user set in this popup wins for the rows they
        // have arranged; rows they never arranged keep following the live bar.
        let (hiddenExtras, visibleExtras) = MenuBarArrangementStore.arranged(
            hidden: classified.hidden, visible: classified.visible)
        // Flat list for notch-less screens; rows keep their arrangement section
        // flag, so an order set on a notched display survives here.
        let flatExtras = hiddenExtras + visibleExtras

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Title
        menu.addItem(
            makeSectionHeader(
                title: Self.hasNotch ? "Notch Overflow" : "Menu-bar Items", fontSize: 12))
        menu.addItem(NSMenuItem.separator())

        if needsAccessibilityHelp {
            // Two states, two fixes: a first-time grant, or a grant held by an
            // older build/copy (macOS pins grants to the exact app build).
            let staleGrant = AppConfig.accessibilityGrantedOnce
            menu.addItem(
                makeHelpLabel(
                    staleGrant
                        ? "Accessibility is granted to another iMonitor build or copy."
                        : "Grant Accessibility in System Settings to list the icons behind the notch."
                ))
            if staleGrant {
                menu.addItem(
                    makeHelpLabel("Remove the old iMonitor entries in System Settings first."))
            }

            let grantItem = NSMenuItem(
                title: staleGrant ? "Grant This Copy\u{2026}" : "Open System Settings\u{2026}",
                action: staleGrant
                    ? #selector(grantThisCopy) : #selector(openAccessibilitySettings),
                keyEquivalent: "")
            grantItem.target = self
            menu.addItem(grantItem)
            return menu
        }

        // The reorderable rows, in display order; shared with the drag session
        // so a ⌘-drag can map a drop position back onto these items.
        if Self.hasNotch {
            menuRows =
                hiddenExtras.map { row(for: $0, hidden: true) }
                + visibleExtras.map { row(for: $0, hidden: false) }
        } else {
            menuRows = flatExtras.enumerated().map { (index, info) in
                row(for: info, hidden: index < hiddenExtras.count)
            }
        }
        let rowWidth = Self.rowWidth(for: menuRows)

        // Discoverability: rows support a gesture that nothing else advertises.
        if !menuRows.isEmpty {
            menu.addItem(makeHintItem())
        }

        if Self.hasNotch {
            // Hidden section
            if !hiddenExtras.isEmpty {
                menu.addItem(
                    makeSectionHeader(title: "Hidden Behind Notch (\(hiddenExtras.count))"))
                menu.addItem(NSMenuItem.separator())

                for (index, info) in hiddenExtras.enumerated() {
                    menu.addItem(
                        makeMenuItem(for: info, hidden: true, rowIndex: index, width: rowWidth))
                }
            }

            // Visible section
            if !visibleExtras.isEmpty {
                if !hiddenExtras.isEmpty { menu.addItem(NSMenuItem.separator()) }
                menu.addItem(makeSectionHeader(title: "Visible (\(visibleExtras.count))"))
                menu.addItem(NSMenuItem.separator())

                for (index, info) in visibleExtras.enumerated() {
                    menu.addItem(
                        makeMenuItem(
                            for: info, hidden: false,
                            rowIndex: hiddenExtras.count + index, width: rowWidth))
                }
            }
        } else {
            // One flat section: without a notch the notch sections would be
            // meaningless; every icon is listed, click to activate.
            for (index, info) in flatExtras.enumerated() {
                menu.addItem(
                    makeMenuItem(
                        for: info, hidden: index < hiddenExtras.count,
                        rowIndex: index, width: rowWidth))
            }
        }

        // Empty state
        if hiddenExtras.isEmpty && visibleExtras.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No items found (check Accessibility permission)",
                action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        return menu
    }

    // Disabled, non-interactive explanation line for the permission section.
    private func makeHelpLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Disabled, non-interactive label. Bold + labelColor (full contrast) rather
    // than secondaryLabelColor/AppKit's default disabled-item dimming, which
    // read poorly against a dark selection highlight.
    private func makeSectionHeader(title: String, fontSize: CGFloat = 13) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
        return item
    }

    private func makeMenuItem(
        for info: MenuBarExtraInfo, hidden: Bool = false, rowIndex: Int = 0, width: CGFloat = 240
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let title = (info.title?.isEmpty == false) ? info.title! : info.appName
        // Kept for Accessibility even though the row view paints the visible
        // content: Assistive clients read the item's title. The drawn eye
        // marker is invisible to them, so hidden rows say so in words.
        item.title = OverflowRowView.accessibilityTitle(title: title, hidden: hidden)

        let row = OverflowRowView(rowIndex: rowIndex, info: info, hidden: hidden, width: width)
        row.onCommandDrag = { [weak self] row in self?.beginRearrangeDrag(row) }
        row.onActivate = { [weak self] info in self?.activateRow(info) }
        item.view = row

        item.representedObject = info
        item.target = self
        item.action = #selector(activateItem(_:))
        return item
    }

    private func row(for info: MenuBarExtraInfo, hidden: Bool) -> OverflowDragSession.Row {
        let title = (info.title?.isEmpty == false) ? info.title! : info.appName
        return OverflowDragSession.Row(info: info, title: title, isHiddenRow: hidden)
    }

    /// One width for every row view, from the widest title, so the menu sizes
    /// itself like a normal menu instead of one lumpy column.
    private static let rearrangementHint =
        "Hold \u{2318} and drag an icon to rearrange the menu bar"

    private static func rowWidth(for rows: [OverflowDragSession.Row]) -> CGFloat {
        let widestRow =
            rows.map { OverflowRowView.preferredWidth(forTitle: $0.title, hidden: $0.isHiddenRow) }
            .max() ?? 230
        let hint =
            (rearrangementHint as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 28
        return min(max(max(widestRow + 16, hint), 230), 420)
    }

    // Muted line teaching the ⌘-drag gesture the row views cannot advertise.
    private func makeHintItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.rearrangementHint, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: Self.rearrangementHint,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return item
    }

    @objc private func activateItem(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? MenuBarExtraInfo else { return }
        pressExtra(info)
    }

    /// A click on a custom row view never runs the item action, so the view
    /// calls this instead; the wait lets the popup close first, or the pressed
    /// item's own menu would open behind ours.
    private func activateRow(_ info: MenuBarExtraInfo) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pressExtra(info)
        }
    }

    /// Press the item's real menu-bar element through Accessibility.
    private func pressExtra(_ info: MenuBarExtraInfo) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastActivation, CFEqual(last.element, info.element), now - last.time < 0.5 {
            // One click can arrive through both the row view and the item
            // action; never press the same element twice.
            return
        }
        lastActivation = (info.element, now)

        let result = AXUIElementPerformAction(info.element, kAXPressAction as CFString)
        if result != .success {
            AppLogger.warn(
                "NotchOverflow: could not press \(info.appName) item (AX error \(result.rawValue))")
        }
    }

    // MARK: - Rearrangement (⌘-drag)

    /// A ⌘-click on a row starts a reordering drag. The menu cannot stay up for
    /// it: AppKit owns the menu's tracking loop, and the drag needs a normal
    /// event stream, so the menu is closed and replaced by a transparent
    /// replica (OverflowDragSession) tracking the mouse. The drop is then
    /// applied to the real bar by MenuBarItemMover.
    private func beginRearrangeDrag(_ row: OverflowRowView) {
        guard menuRows.count > 1,
            let menu = row.enclosingMenuItem?.menu,
            let menuWindow = row.window
        else { return }

        // A fast ⌘-click can leave a session whose mouse-up the menu's tracking
        // loop ate before the session even started; that leftover must not
        // block this drag (and must not keep its event monitors alive).
        if let stale = dragSession {
            AppLogger.info("NotchOverflow: clearing a stale rearrangement session")
            stale.cancel()
            dragSession = nil
        }

        // The replica must draw every row where the user saw it. A naive list
        // would misplace them (the menu's headers and separators take vertical
        // space), and a drop one row off is exactly the bug this avoids.
        let rowRects: [NSRect] = menu.items.compactMap { item in
            guard let view = item.view else { return nil }
            return menuWindow.convertToScreen(view.convert(view.bounds, to: nil))
        }

        let session = OverflowDragSession(
            rows: menuRows,
            draggedIndex: row.rowIndex,
            menuFrame: menuWindow.frame,
            rowRects: rowRects)
        // Identity-checked so a superseded session's late events cannot move an
        // item out from under the current one.
        session.onFinish = { [weak self, weak session] draggedIndex, gap in
            guard let self = self, let session = session, self.dragSession === session else {
                return
            }
            self.dragSession = nil
            self.applyRearrangement(draggedIndex: draggedIndex, gap: gap)
        }
        session.onCancel = { [weak self, weak session] in
            guard let self = self, let session = session, self.dragSession === session else {
                return
            }
            self.dragSession = nil
        }
        dragSession = session

        menu.cancelTracking()
        // The tracking loop must unwind before the replica appears, or its
        // window would be torn down after ours is already up.
        DispatchQueue.main.async {
            session.start()
        }
    }

    /// `gap` is a position among the menu's rows (0...count) with the dragged
    /// row's own slot counted in place. Translate it into the drop target: the
    /// row the dragged one should end up just above in the list, which is the
    /// row whose slot it takes on the bar (that is exactly what a ⌘-drag does
    /// when released over an icon).
    private func applyRearrangement(draggedIndex: Int, gap: Int) {
        let rows = menuRows
        guard rows.indices.contains(draggedIndex) else { return }

        let insertIndex = gap > draggedIndex ? gap - 1 : gap
        guard insertIndex != draggedIndex else { return }  // dropped back in place

        var remaining = rows
        let source = remaining.remove(at: draggedIndex)
        guard !remaining.isEmpty else { return }
        let target = remaining[min(insertIndex, remaining.count - 1)]

        // Remember the arrangement the drop just made, regardless of what
        // becomes of the physical move below: on a Mac where the synthetic
        // drag does not land, the popup still opens the way the user set it up.
        rememberArrangement(rows: rows, droppedAt: draggedIndex, insertion: insertIndex)

        AppLogger.info(
            "NotchOverflow: rearranging \(source.info.appName) \u{2192} \(target.info.appName)")

        prepareForRearrangement { [weak self] expanded in
            MenuBarItemMover.move(
                source: source.info, target: target.info,
                allExtras: rows.map { $0.info }
            ) { moved in
                if moved {
                    AppLogger.info("NotchOverflow: rearrangement applied")
                }
                self?.collapseAfterRearrangement(expanded)
            }
        }
    }

    /// Saves the arrangement the drop created: the rows in their new order,
    /// with the dropped row joining the section of the row it was dropped
    /// above (or, at the very end of the list, of the row above it).
    private func rememberArrangement(
        rows: [OverflowDragSession.Row], droppedAt draggedIndex: Int, insertion: Int
    ) {
        guard rows.indices.contains(draggedIndex) else { return }
        var reordered = rows
        let source = reordered.remove(at: draggedIndex)
        let newIndex = min(insertion, reordered.count)
        reordered.insert(source, at: newIndex)

        let adopted =
            MenuBarArrangementStore.adoptedHiddenFlag(
                afterDropAt: newIndex, in: reordered.map { $0.isHiddenRow })
            ?? source.isHiddenRow

        var placements: [(bundle: String, section: MenuBarSection)] = []
        for (index, row) in reordered.enumerated() {
            guard let bundle = MenuBarArrangementStore.key(of: row.info) else { continue }
            let hidden = index == newIndex ? adopted : row.isHiddenRow
            placements.append((bundle, hidden ? .hidden : .visible))
        }
        MenuBarArrangementStore.record(placements)
    }

    // MARK: - NSMenuDelegate

    /// View-based rows paint their own selection, but AppKit does not know to
    /// redraw them when the highlight moves, so nudge the two rows involved.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        lastHighlightedMenuItem?.view?.needsDisplay = true
        item?.view?.needsDisplay = true
        lastHighlightedMenuItem = item
    }

    // MARK: - Accessibility

    private typealias Permission = AccessibilityPermission

    // MARK: - AX Enumeration

    // Runs off the main thread: Accessibility round-trips to every app take about
    // a second in total and the default per-app timeout is several seconds.
    private func getAllMenuBarExtras(completion: @escaping ([MenuBarExtraInfo]) -> Void) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Only app bundles own status items. Skipping the rest (dozens of WebKit
        // and XPC helpers, each of which would sit out the timeout) cuts the walk
        // from ~2.8s to ~1s.
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != myPID && $0.bundleURL?.pathExtension == "app" }
        DispatchQueue.global(qos: .userInitiated).async {
            let results = Self.extras(of: apps)
            DispatchQueue.main.async { completion(results) }
        }
    }

    private static func extras(of apps: [NSRunningApplication]) -> [MenuBarExtraInfo] {
        var results: [MenuBarExtraInfo] = []

        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // The default timeout is several seconds per app; one busy or hung app
            // would otherwise stall the whole walk (measured: ~18s).
            AXUIElementSetMessagingTimeout(axApp, 0.1)
            var extrasRef: AnyObject?
            let err = AXUIElementCopyAttributeValue(
                axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
            guard err == .success else { continue }

            var childrenRef: AnyObject?
            let childErr = AXUIElementCopyAttributeValue(
                extrasRef as! AXUIElement,
                kAXChildrenAttribute as CFString, &childrenRef)
            guard childErr == .success,
                let children = childrenRef as? [AXUIElement]
            else { continue }

            for child in children {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)

                var posRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
                var pos = CGPoint.zero
                if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }

                var sizeRef: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
                var size = CGSize.zero
                if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

                results.append(
                    MenuBarExtraInfo(
                        element: child,
                        appName: app.localizedName ?? "Unknown",
                        appIcon: app.icon,
                        title: titleRef as? String,
                        bundleIdentifier: app.bundleIdentifier,
                        pid: app.processIdentifier,
                        position: pos,
                        size: size
                    ))
            }
        }
        return results
    }
}
