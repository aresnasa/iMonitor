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
    /// The item's own Accessibility identifier (`com.apple.menuextra.clock`...).
    /// MenuBarAgent hosts several distinctly named items under one bundle, so
    /// without it they would all read as one "MenuBarAgent" row.
    let identifier: String?
    /// The item's localized Accessibility description ("时钟", "电池"...),
    /// which is the only human-readable name most system items expose.
    let axDescription: String?
    let pid: pid_t
    let position: CGPoint
    let size: CGSize

    /// macOS's own items (clock, Wi-Fi, battery, Control Center...) plus the
    /// input source menu. Their visibility is governed by macOS, not by the
    /// Hidden Bar's bundle sections, so the popup never offers to hide them.
    var isSystemItem: Bool {
        if identifier?.hasPrefix("com.apple.menuextra.") == true { return true }
        guard let bundleIdentifier else { return false }
        return MenuBarLayoutResolver.systemItemOwners.contains(bundleIdentifier)
    }

    /// Whether macOS currently draws the item on the bar. A zero frame means it
    /// has been removed by hiding (or the read failed); the row still belongs
    /// in the list, but has no position to classify.
    var isDrawnOnBar: Bool {
        return size.width > 0 && size.height > 0
    }

    /// What a row shows. System items have no AXTitle; their description is the
    /// localized name, with a status suffix for Wi-Fi ("Wi‑Fi，已接入，3格") that
    /// is not part of the name.
    var displayName: String {
        if isSystemItem {
            if let description = axDescription, !description.isEmpty,
                let name = Self.firstNamePart(description)
            {
                return name
            }
            if bundleIdentifier == "com.apple.TextInputMenuAgent" {
                return "Input Source"
            }
            if let identifier = identifier {
                return Self.systemName(for: identifier)
            }
        }
        if let title = title, !title.isEmpty { return title }
        return appName
    }

    /// The app icon is meaningless for a MenuBarAgent item (it would show the
    /// agent's generic icon); a symbol says what the item is. The same applies
    /// to owners whose app icon is a placeholder (SystemUIServer) and to the
    /// input source menu. The image keeps its natural proportions: the row
    /// draws it aspect-fit instead of stretching it into a square.
    var displayIcon: NSImage? {
        if let identifier = identifier {
            // The battery's own description carries its state
            // ("电池，80%"); reflect it instead of always drawing a full
            // battery next to an 80% bar item.
            if identifier == "com.apple.menuextra.battery" {
                return Self.symbol(Self.batterySymbol(for: axDescription))
            }
            if let symbolName = Self.systemSymbol(for: identifier) {
                return Self.symbol(symbolName)
            }
        }
        if let bundleIdentifier {
            if InputSourceVisibility.bundles.contains(bundleIdentifier) {
                return Self.symbol("globe")
            }
            if let symbolName = Self.ownerSymbols[bundleIdentifier] {
                return Self.symbol(symbolName)
            }
        }
        return appIcon ?? Self.symbol("menubar.rectangle")
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// Symbols for items whose owning app has no usable icon of its own.
    private static let ownerSymbols: [String: String] = [
        "com.apple.systemuiserver": "menubar.rectangle",
        "com.apple.MenuBarAgent": "menubar.rectangle",
    ]

    private static func firstNamePart(_ description: String) -> String? {
        let name = description.split(whereSeparator: {
            $0 == "," || $0 == "，" || $0 == ":" || $0 == "："
        }).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name : nil
    }

    private static let systemNames: [String: String] = [
        "com.apple.menuextra.clock": "Clock",
        "com.apple.menuextra.wifi": "Wi‑Fi",
        "com.apple.menuextra.battery": "Battery",
        "com.apple.menuextra.controlcenter": "Control Center",
        "com.apple.menuextra.bluetooth": "Bluetooth",
        "com.apple.menuextra.sound": "Sound",
        "com.apple.menuextra.display": "Display",
        "com.apple.menuextra.focusmode": "Focus",
        "com.apple.menuextra.now-playing": "Now Playing",
        "com.apple.menuextra.airdrop": "AirDrop",
        "com.apple.menuextra.screen-mirroring": "Screen Mirroring",
        "com.apple.menuextra.keyboard-brightness": "Keyboard Brightness",
        "com.apple.menuextra.user": "Fast User Switching",
        "com.apple.menuextra.vpn": "VPN",
        "com.apple.menuextra.timer": "Timer",
        "com.apple.menuextra.audiovideo": "Audio/Video",
        "com.apple.menuextra.hearing": "Hearing",
        "com.apple.menuextra.musicrecognition": "Music Recognition",
        "com.apple.menuextra.voice-control": "Voice Control",
        "com.apple.menuextra.accessibility-shortcuts": "Accessibility Shortcuts",
        "com.apple.menuextra.faceTime": "FaceTime",
        "com.apple.menuextra.energy-mode": "Energy Mode",
        "com.apple.menuextra.textinput": "Input Source",
    ]

    private static func systemName(for identifier: String) -> String {
        if let name = systemNames[identifier] { return name }
        let suffix = identifier.replacingOccurrences(of: "com.apple.menuextra.", with: "")
        return suffix.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    /// A battery symbol matching the charge (and charging state) in the
    /// item's Accessibility description. Falls back to a full battery when the
    /// description carries no percentage.
    private static func batterySymbol(for description: String?) -> String {
        guard let description,
            let regex = try? NSRegularExpression(pattern: #"(\d{1,3})\s*[%％]"#),
            let match = regex.firstMatch(
                in: description, range: NSRange(description.startIndex..., in: description)),
            let range = Range(match.range(at: 1), in: description),
            let percent = Int(description[range])
        else { return "battery.100" }
        if description.contains("充电")
            || description.localizedCaseInsensitiveContains("charging")
        {
            return "battery.100.bolt"
        }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private static func systemSymbol(for identifier: String) -> String? {
        switch identifier {
        case "com.apple.menuextra.clock": return "clock"
        case "com.apple.menuextra.wifi": return "wifi"
        case "com.apple.menuextra.battery": return "battery.100"
        case "com.apple.menuextra.controlcenter": return "switch.2"
        case "com.apple.menuextra.bluetooth": return "dot.radiowaves.left.and.right"
        case "com.apple.menuextra.sound": return "speaker.wave.2"
        case "com.apple.menuextra.display": return "display"
        case "com.apple.menuextra.focusmode": return "moon"
        case "com.apple.menuextra.now-playing": return "play.circle"
        case "com.apple.menuextra.textinput": return "globe"
        default: return nil
        }
    }
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
///
/// The boundary is the Hidden Bar arrow's X while that feature hides icons,
/// and the notch's clear zone otherwise: both put the out-of-sight icons on
/// the same side of it.
enum MenuBarExtraClassifier {
    /// Two items whose frames overlap by more than this are treated as crammed
    /// into the same slot. Items that merely touch measure as 1–3pt of overlap
    /// because of AX rounding, so that noise is ignored.
    static let overlapTolerance: CGFloat = 4

    static func classify(
        _ extras: [MenuBarExtraInfo],
        boundary: CGFloat,
        isLTR: Bool = true,
        hidesPerBundle: Bool = false,
        overrides: [String: Bool] = [:]
    ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
        // A zero-frame item is one macOS is not drawing (native hiding removed
        // it from the bar, or the read failed). It has no position to judge,
        // but dropping it would hide it from the list as well - exactly the
        // icons the user needs to find and bring back. It goes to the hidden
        // bucket, which is what "not drawn on the bar" means.
        let renderable = extras.filter { $0.isDrawnOnBar }
        let unmeasured = extras.filter { !$0.isDrawnOnBar }
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
        for i in sorted.indices {
            // The boundary is the arrow's midX: icons on its hidden side hide.
            // In an RTL bar the hidden side is the right one.
            let onHiddenSide =
                isLTR
                ? sorted[i].position.x < boundary
                : sorted[i].position.x > boundary
            if onHiddenSide { isHidden[i] = true }
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

        // Native hiding is per owning app: macOS keeps every icon of a bundle
        // when any of its icons is on the visible side (the same "most visible
        // wins" rule as MenuBarLayoutResolver). Mirror that here, or the popup
        // would mark an icon hidden while the collapsed bar still shows it.
        var visibleBundleKeys = Set<String>()
        if hidesPerBundle {
            for (index, item) in sorted.enumerated() where !isHidden[index] {
                if let key = MenuBarArrangementStore.key(of: item) { visibleBundleKeys.insert(key) }
            }
            for index in sorted.indices where isHidden[index] {
                if let key = MenuBarArrangementStore.key(of: sorted[index]),
                    visibleBundleKeys.contains(key)
                {
                    isHidden[index] = false
                }
            }
        }

        var hidden: [MenuBarExtraInfo] = []
        var visible: [MenuBarExtraInfo] = []
        for (index, item) in sorted.enumerated() {
            if let bundle = item.bundleIdentifier, let pinned = overrides[bundle] {
                // Manual pins win over the arrow position and the bundle rule.
                if pinned { hidden.append(item) } else { visible.append(item) }
            } else if isHidden[index] {
                hidden.append(item)
            } else {
                visible.append(item)
            }
        }
        for item in unmeasured {
            if let bundle = item.bundleIdentifier, let pinned = overrides[bundle] {
                if pinned { hidden.append(item) } else { visible.append(item) }
                continue
            }
            let siblingIsVisible =
                hidesPerBundle
                && MenuBarArrangementStore.key(of: item).map { visibleBundleKeys.contains($0) }
                    == true
            if siblingIsVisible { visible.append(item) } else { hidden.append(item) }
        }
        return (
            hidden.sorted { $0.position.x > $1.position.x },
            visible.sorted { $0.position.x > $1.position.x }
        )
    }
}

// MARK: - NotchOverflowController

/// The dropdown's and the Settings list's shared view of the menu bar. Both
/// must group rows identically, or the same icon would read Hidden in one
/// place and Visible in the other.
struct MenuBarItemsSnapshot {
    let hidden: [MenuBarExtraInfo]
    let visible: [MenuBarExtraInfo]
    /// Always-visible items (clock, Wi-Fi, battery, Control Center, the input
    /// source...). They are also part of `visible`; this is the subset the
    /// Settings list shows separately.
    let system: [MenuBarExtraInfo]

    var flat: [MenuBarExtraInfo] { hidden + visible }
}

enum MenuBarItemsResolver {
    static func resolve(
        extras: [MenuBarExtraInfo],
        hiddenBoundary: CGFloat?,
        notchBoundary: CGFloat,
        hasNotch: Bool,
        hidesPerBundle: Bool,
        isLTR: Bool,
        overrides: [String: Bool] = MenuBarSectionOverrides.current
    ) -> MenuBarItemsSnapshot {
        let hasSections = hasNotch || hiddenBoundary != nil
        let boundaryX = hiddenBoundary ?? notchBoundary
        let systemItems = extras.filter { $0.isSystemItem }
            .sorted { $0.position.x > $1.position.x }
        let otherItems = extras.filter { !$0.isSystemItem }
        let classified: (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) =
            hasSections
            ? MenuBarExtraClassifier.classify(
                otherItems, boundary: boundaryX, isLTR: isLTR,
                hidesPerBundle: hidesPerBundle, overrides: overrides)
            : (hidden: [], visible: otherItems)
        let visibleWithSystem = (classified.visible + systemItems)
            .sorted { $0.position.x > $1.position.x }
        let arranged = MenuBarArrangementStore.arranged(
            hidden: classified.hidden, visible: visibleWithSystem)
        return MenuBarItemsSnapshot(
            hidden: arranged.hidden, visible: arranged.visible, system: systemItems)
    }
}

class NotchOverflowController: NSObject, NSMenuDelegate {

    /// The status item whose menu is waiting on the Accessibility grant, so the
    /// menu can be re-opened the moment the user returns from System Settings.
    private weak var itemAwaitingPermission: NSStatusItem?

    /// Rearrangement hooks, filled in by whoever owns the Hidden Bar engine: a
    /// status item can only be ⌘-dragged while the bar shows it, so a collapsed
    /// bar is expanded for the duration of a move and re-collapsed after.
    var prepareForRearrangement: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var collapseAfterRearrangement: (Bool) -> Void = { _ in }

    /// Called from the Hidden Bar controller and from the menu-bar dropdown
    /// owner: returns the Hidden Bar arrow's X, the boundary between the icons
    /// a collapsed bar hides and the ones it keeps. nil when the feature is off
    /// or the arrow is not on the bar, in which case the notch boundary stands
    /// in.
    var hiddenBoundary: (() -> CGFloat?)?
    /// Whether the hiding engine hides a whole app rather than each icon's
    /// slot. Native visibility is per bundle; the popup groups the same way so
    /// its Hidden/Visible split matches what the collapsed bar actually does.
    var hidesByBundle: (() -> Bool)?
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
        // The Hidden Bar arrow is the boundary that matters while the feature
        // hides icons: everything on its hidden side is what the collapsed bar
        // hides, notch overflow included. Without it (feature off, arrow off
        // the bar), the notch boundary stands in. With neither, one flat list
        // is right.
        let barBoundary = hiddenBoundary?()
        let boundaryX = barBoundary ?? resolvedBoundary
        let hasSections = Self.hasNotch || barBoundary != nil
        let hidesPerBundle = hidesByBundle?() ?? false
        // System items (clock, Wi-Fi, battery, Control Center...) are always
        // visible: the native hiding keeps them whatever their position. They
        // stay out of the hide/show split so the popup cannot offer to hide
        // something the bar never hides.
        let systemItems = allExtras.filter { $0.isSystemItem }
        let otherItems = allExtras.filter { !$0.isSystemItem }
        let classified: (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) =
            hasSections
            ? MenuBarExtraClassifier.classify(
                otherItems, boundary: boundaryX, isLTR: MenuBarOrder.isUsingLTRLanguage,
                hidesPerBundle: hidesPerBundle)
            : (hidden: [], visible: otherItems)
        let visibleWithSystem = (classified.visible + systemItems)
            .sorted { $0.position.x > $1.position.x }
        // The arrangement the user set in this popup only orders the rows: the
        // Hidden/Visible section always follows the live bar, so the popup
        // cannot claim an icon is hidden while the bar is showing it.
        let (hiddenExtras, visibleExtras) = MenuBarArrangementStore.arranged(
            hidden: classified.hidden, visible: visibleWithSystem)
        AppLogger.info(
            "NotchOverflow: boundary \(Int(boundaryX)); perBundle \(hidesPerBundle); hidden "
                + "\(hiddenExtras.map(\.displayName)); visible "
                + "\(visibleExtras.map(\.displayName))")
        let unmeasured = (hiddenExtras + visibleExtras).filter { !$0.isDrawnOnBar }
        if !unmeasured.isEmpty {
            AppLogger.info(
                "NotchOverflow: not drawn on the bar: \(unmeasured.map(\.displayName))")
        }
        // Flat list for notch-less screens; rows keep their arrangement section
        // flag, so an order set on a notched display survives here.
        let flatExtras = hiddenExtras + visibleExtras

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Title
        menu.addItem(makeSectionHeader(title: "Menu-bar Items", fontSize: 12))
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
        if hasSections {
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

        if hasSections {
            if !hiddenExtras.isEmpty {
                // The hidden bucket holds both kinds: icons iMonitor tucked
                // away when the bar collapsed, and icons macOS squeezed off
                // past the notch. One label covers both.
                menu.addItem(makeSectionHeader(title: "Hidden (\(hiddenExtras.count))"))
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
        let title = info.displayName
        // Kept for Accessibility even though the row view paints the visible
        // content: Assistive clients read the item's title. The drawn eye
        // marker is invisible to them, so hidden rows say so in words.
        item.title = OverflowRowView.accessibilityTitle(title: title, hidden: hidden)

        let row = OverflowRowView(rowIndex: rowIndex, info: info, hidden: hidden, width: width)
        // System items are always visible; dragging them between the sections
        // would promise a hide the bar never does.
        if !info.isSystemItem {
            row.onCommandDrag = { [weak self] row in self?.beginRearrangeDrag(row) }
        } else {
            row.toolTip = "System items stay visible while the icons are hidden"
        }
        if !info.isDrawnOnBar {
            row.toolTip = "macOS is not drawing this icon on the bar right now"
        }
        row.onActivate = { [weak self] info in self?.activateRow(info) }
        item.view = row

        item.representedObject = info
        item.target = self
        item.action = #selector(activateItem(_:))
        return item
    }

    private func row(for info: MenuBarExtraInfo, hidden: Bool) -> OverflowDragSession.Row {
        return OverflowDragSession.Row(
            info: info, title: info.displayName, isHiddenRow: hidden)
    }

    /// One width for every row view, from the widest title, so the menu sizes
    /// itself like a normal menu instead of one lumpy column.
    private static let rearrangementHint =
        "⌘-drag between Hidden/Visible to choose what hides; system items stay visible"

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
                "NotchOverflow: could not press \(info.displayName) item (AX error \(result.rawValue))"
            )
        }
    }

    // MARK: - Rearrangement (⌘-drag)

    /// A ⌘-click on a row starts a reordering drag. The menu cannot stay up for
    /// it: AppKit owns the menu's tracking loop, and the drag needs a normal
    /// event stream, so the menu is closed and replaced by a transparent
    /// replica (OverflowDragSession) tracking the mouse. The drop is then
    /// applied to the real bar by MenuBarItemMover.
    private func beginRearrangeDrag(_ row: OverflowRowView) {
        // System items stay visible; their rows have no drag handler, but a
        // stale row from an earlier build must not start one either.
        guard !row.info.isSystemItem else { return }
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
        var targetIndex = min(insertIndex, remaining.count - 1)
        // System rows sit at the end of the Visible section. Dropping above
        // one means "the end of the app icons"; aiming the synthetic drag at
        // the clock/battery would either fail or move the icon into the
        // system area.
        if remaining[targetIndex].info.isSystemItem,
            let nonSystem = remaining[..<targetIndex].lastIndex(where: {
                !$0.info.isSystemItem
            })
        {
            targetIndex = nonSystem
        }
        let target = remaining[targetIndex]

        // Remember the arrangement the drop just made, regardless of what
        // becomes of the physical move below: on a Mac where the synthetic
        // drag does not land, the popup still opens the way the user set it up.
        rememberArrangement(rows: rows, droppedAt: draggedIndex, insertion: insertIndex)

        AppLogger.info(
            "NotchOverflow: rearranging \(source.info.displayName) \u{2192} \(target.info.displayName)"
        )

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

        var placements: [(key: String, section: MenuBarSection)] = []
        for (index, row) in reordered.enumerated() {
            guard let key = MenuBarArrangementStore.key(of: row.info) else { continue }
            let hidden = index == newIndex ? adopted : row.isHiddenRow
            placements.append((key, hidden ? .hidden : .visible))
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
                AXUIElementSetMessagingTimeout(child, 0.1)
                let slotFrame = frame(of: child)
                for element in items(in: child) {
                    AXUIElementSetMessagingTimeout(element, 0.1)
                    let itemFrame = frame(of: element) ?? slotFrame
                    results.append(
                        MenuBarExtraInfo(
                            element: element,
                            appName: app.localizedName ?? "Unknown",
                            appIcon: app.icon,
                            title: string(element, kAXTitleAttribute),
                            bundleIdentifier: app.bundleIdentifier,
                            identifier: string(element, kAXIdentifierAttribute),
                            axDescription: string(element, kAXDescriptionAttribute),
                            pid: app.processIdentifier,
                            position: itemFrame?.origin ?? .zero,
                            size: itemFrame?.size ?? .zero
                        ))
                }
            }
        }
        return results
    }

    /// MenuBarAgent wraps each system item in a full-height slot group; other
    /// owners expose the item directly. Flatten both so a row names the item,
    /// not the hosting group (four slots would all read "MenuBarAgent").
    private static func items(in child: AXUIElement) -> [AXUIElement] {
        guard string(child, kAXRoleAttribute) == "AXGroup" else { return [child] }
        var childrenRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &childrenRef)
                == .success,
            let children = childrenRef as? [AXUIElement], !children.isEmpty
        else { return [child] }
        let items = children.filter {
            string($0, kAXSubroleAttribute) == "AXMenuExtra"
                || string($0, kAXRoleAttribute) == "AXMenuBarItem"
        }
        return items.isEmpty ? [child] : items
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
                == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
                == .success,
            let positionValue = positionRef, let sizeValue = sizeRef
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
