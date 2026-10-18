//
//  NativeVisibilityEngine.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

// macOS 27 hiding for the non-sandboxed build. Instead of inflating the
// separator, which macOS 27 ejects from the layout once it is too wide, this
// reads which apps the user placed to the left of the arrow and asks macOS to
// show only those. macOS then hides the rest and reflows the bar itself, so the
// result does not depend on display width, the notch or the frontmost app's menus.
//
// The arrow is the boundary: apps left of it (LTR) are hidden, apps right of it
// stay visible. The regular separator is not needed and is taken out of the bar.
//
// Limits, all from what macOS 27 exposes:
// - Hiding is per app: an app with several icons hides or shows them together
//   (the most visible section wins).
// - macOS's own items (clock, Wi-Fi, Control Center...) are always kept visible:
//   Accessibility cannot tell them apart, so they cannot be mapped to sections.
// - Sections are read only while nothing is hidden, because hidden items report
//   stale positions. They are re-read on the next collapse from an unrestricted
//   bar, so an app launched while collapsed stays hidden until then, the same as
//   a new icon landing in the hidden section under the legacy mechanism.
final class NativeVisibilityEngine: MenuBarEngine {
    // System item identifiers to keep visible. Unknown identifiers are ignored,
    // so the range covers items a given Mac does not have.
    static let systemItemsToKeep = Array(0..<64)

    private weak var items: HiddenMenuItemProvider?
    private let inventory: MenuBarInventoryProviding
    private let visibility: NativeVisibilityProviding
    private let ownBundleIdentifier: String?
    private let itemFrame: (NSStatusItem) -> CGRect?
    private let isLTR: () -> Bool

    // .calibrating stands for "an activation is in flight".
    private(set) var state: MenuBarEngineState = .expanded
    private(set) var layout: MenuBarLayout?

    private var assertion: NativeVisibilityAssertion?
    // macOS's own items (clock/calendar, Wi-Fi, Control Center...) as last read
    // from an unrestricted bar. Their positions are trailing-anchored, so the
    // pre-collapse read is still where they are once the apps' items hide.
    private(set) var systemItemFrames: [CGRect] = []
    // The items the restriction is hiding, from the same read. While the
    // restriction is briefly lifted for a system-item click, these frames are
    // covered so the hidden icons never appear on screen.
    private(set) var hiddenItemFrames: [CGRect] = []
    // Bumped whenever a pending activation must no longer win (an expand, a newer
    // activation); a late success is then invalidated straight away.
    private var generation = 0
    private var lastUnavailableReason: String?

    init(
        items: HiddenMenuItemProvider,
        inventory: MenuBarInventoryProviding = AccessibilityMenuBarInventory(),
        visibility: NativeVisibilityProviding = NativeVisibilityBridge(),
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        itemFrame: @escaping (NSStatusItem) -> CGRect? = { $0.button?.window?.frame },
        isLTR: @escaping () -> Bool = { MenuBarOrder.isUsingLTRLanguage }
    ) {
        self.items = items
        self.inventory = inventory
        self.visibility = visibility
        self.ownBundleIdentifier = ownBundleIdentifier
        self.itemFrame = itemFrame
        self.isLTR = isLTR
        items.separatorItem.isVisible = false
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        switch state {
        case .collapsed:
            return completion(.collapsed)
        case .calibrating:
            // The activation in flight answers the request that started it.
            return
        case .expanded, .unavailable:
            break
        }
        setItemsHidden(false)

        guard visibility.isAvailable else {
            logUnavailableOnce(
                "the native menu-bar visibility API is not available in this build or on this macOS"
            )
            state = .unavailable
            return completion(.unavailable)
        }
        guard inventory.isAuthorized else {
            // Without Accessibility the sections cannot be read, and guessing
            // would hide icons the user kept visible. Not latched: it works as
            // soon as the permission is granted.
            inventory.requestAuthorization()
            logUnavailableOnce("Accessibility permission is needed to read the menu-bar sections")
            return completion(.unavailable)
        }
        state = .calibrating
        withLayout { [weak self] layout in
            guard let self = self else { return }
            guard let layout = layout else {
                self.logUnavailableOnce("the arrow's position cannot be read yet")
                self.state = .expanded
                return completion(.unavailable)
            }
            let hidden = layout.bundles(in: [.hidden])
            guard !hidden.isEmpty else {
                // Nothing sits to the arrow's hidden side yet. Reporting success
                // here would flip the arrow and claim the bar is hidden while it
                // is untouched - exactly the "the toggle does nothing" symptom.
                // Stay expanded and say what to do instead.
                self.state = .expanded
                self.logUnavailableOnce(
                    "nothing to hide yet: \u{2318}-drag other menu-bar icons across the arrow "
                        + "so they sit on its hidden side, then collapse again")
                return completion(.unavailable)
            }
            self.activate(allowing: layout.bundles(in: [.visible])) { [weak self] succeeded in
                guard let self = self else { return }
                self.state = succeeded ? .collapsed : .expanded
                if succeeded {
                    self.setItemsHidden(true)
                }
                completion(succeeded ? .collapsed : .unavailable)
            }
        }
    }

    func expand() {
        state = .expanded
        releaseAssertion()
        setItemsHidden(false)
    }

    // Native hiding does not depend on display geometry, so only drop the cached
    // sections; the next read from an unrestricted bar replaces them.
    func invalidateLayout() {
        if assertion == nil {
            layout = nil
        }
    }

    // The sections as the user arranged them. Read fresh only from an
    // unrestricted bar; while a restriction is active the cached ones stand in.
    private func withLayout(_ body: @escaping (MenuBarLayout?) -> Void) {
        if assertion != nil {
            return body(layout)
        }
        guard let arrow = items?.toggleItem,
            let boundary = itemFrame(arrow)
        else { return body(nil) }
        let isLTR = self.isLTR()
        generation += 1
        let generation = self.generation
        inventory.snapshot { [weak self] inventory in
            guard let self = self, generation == self.generation else { return }
            let layout = MenuBarLayoutResolver.resolve(
                inventory: inventory,
                separatorFrame: boundary,
                isLTR: isLTR,
                excludingBundle: self.ownBundleIdentifier)
            AppLogger.info(
                "NativeVisibility: arrow at x=\(boundary.midX); visible "
                    + "\(layout.bundles(in: [.visible])), hidden \(layout.bundles(in: [.hidden]))")
            // Remember where macOS's own items are, so a click on one (the
            // clock/calendar in particular, which the restriction would
            // otherwise leave inert) can be forwarded through a temporary
            // release.
            self.systemItemFrames = inventory.filter { item in
                guard let bundle = item.bundleIdentifier else { return false }
                return MenuBarLayoutResolver.systemItemOwners.contains(bundle)
            }.map(\.frame)
            // Same read, the other half: where the icons the restriction is
            // about to hide sit. These are the frames the temporary reveal
            // covers so they never show while a system item is clicked.
            let hiddenBundles = Set(layout.bundles(in: [.hidden]))
            self.hiddenItemFrames = inventory.filter { item in
                guard let bundle = item.bundleIdentifier else { return false }
                return hiddenBundles.contains(bundle)
            }.map(\.frame)
            self.layout = layout
            body(layout)
        }
    }

    // Activates the new restriction before dropping the old one, so switching
    // between collapsed and expanded never flashes the whole bar visible.
    private func activate(allowing bundles: [String], completion: @escaping (Bool) -> Void) {
        generation += 1
        let generation = self.generation
        let allowed = (ownBundleIdentifier.map { [$0] } ?? []) + bundles
        visibility.activate(
            allowedSystemItems: Self.systemItemsToKeep,
            allowedBundleIdentifiers: allowed
        ) { [weak self] result in
            guard let self = self, generation == self.generation else {
                if case .success(let stale) = result { stale.invalidate() }
                return
            }
            switch result {
            case .success(let newAssertion):
                let old = self.assertion
                self.assertion = newAssertion
                old?.invalidate()
                completion(true)
            case .failure(let error):
                // Fail open: never leave icons hidden after an error.
                AppLogger.error(error, context: "NativeVisibility: activation failed")
                self.releaseAssertion()
                completion(false)
            }
        }
    }

    // Mirrors the engine's hiding state onto what the bar shows for this
    // feature: while hidden, the separator goes off the bar entirely (native
    // hiding does not use it) and the arrow's context menu offers help while
    // Accessibility is missing. Restoring flips both back.
    private func setItemsHidden(_ hidden: Bool) {
        // The separator goes off the bar entirely under native hiding.
        items?.separatorItem.isVisible = !hidden
    }

    // Any arrangement works: whatever sits left of the arrow is the hidden section.
    var isArrangementValid: Bool {
        return true
    }

    // The assessment mode this engine activates keeps macOS's own items visible
    // but inert, Notification Center included. The controller lets a click on
    // one through with the restriction lifted for a moment.
    var blocksSystemItemClicks: Bool {
        return true
    }

    func releaseForSystemItemClick() {
        state = .expanded
        releaseAssertion()
        setItemsHidden(false)
    }

    private func releaseAssertion() {
        generation += 1
        assertion?.invalidate()
        assertion = nil
    }

    // Logged when the reason changes, so a retried collapse does not spam.
    private func logUnavailableOnce(_ reason: String) {
        guard reason != lastUnavailableReason else { return }
        lastUnavailableReason = reason
        AppLogger.warn("NativeVisibility: hiding unavailable: \(reason)")
    }
}
