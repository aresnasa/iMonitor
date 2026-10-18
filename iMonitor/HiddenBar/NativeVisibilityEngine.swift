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
//   The clock stays inert while the restriction holds, though; a click on it
//   is passed through by lifting the restriction for a moment (see
//   liftHidingBriefly).
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
    // Bumped whenever a pending activation must no longer win (an expand, a newer
    // activation); a late success is then invalidated straight away.
    private var generation = 0
    private var lastUnavailableReason: String?

    // Set from the release of a brief lift (liftHidingBriefly) until its hiding
    // is back on; an expand() cancels it. liftID tells a stale step apart.
    private var isLifted = false
    private var liftID = 0

    // Timings of a brief lift, measured on macOS 27.0.1. AXPress on the clock
    // opened its panel 0.01 s after the release and did nothing at 0 s: the
    // release takes a moment to reach the bar (5x margin here).
    private static let liftSettleDelay: TimeInterval = 0.05
    // The panel the press opens survives re-applying the restriction anywhere
    // from right after AXPress returns to 0.2 s later; in between, the hidden
    // icons show for a short flash.
    private static let liftHoldAfterPress: TimeInterval = 0.1

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
        isLifted = false
        releaseAssertion()
        setItemsHidden(false)
    }

    // Native hiding does not depend on display geometry, so only drop the cached
    // sections; the next read from an unrestricted bar replaces them. A brief
    // lift is not an unrestricted bar: it puts the cached sections back.
    func invalidateLayout() {
        if assertion == nil, !isLifted {
            layout = nil
        }
    }

    // The assessment mode behind this engine shows the clock but blocks its
    // calendar/widgets panel, whatever the allow-list holds (measured: allowing
    // MenuBarAgent, chronod or more system item ids changes nothing).
    var blocksSystemItemClicks: Bool {
        return true
    }

    // Releases the restriction, presses once the clock responds, and re-applies
    // the cached sections: a fresh read takes about a second - far longer than
    // the flash this is meant to be - and nothing was rearranged meanwhile.
    // The separator stays off the bar throughout.
    func liftHidingBriefly(
        for press: @escaping () -> Void, completion: @escaping (CollapseResult) -> Void
    ) -> Bool {
        guard state == .collapsed, !isLifted, assertion != nil, let layout = layout else {
            return false
        }
        isLifted = true
        liftID += 1
        let liftID = self.liftID
        releaseAssertion()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftSettleDelay) { [weak self] in
            guard let self = self, self.isLifted, liftID == self.liftID else { return }
            press()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftHoldAfterPress) {
                [weak self] in
                guard let self = self, self.isLifted, liftID == self.liftID else { return }
                self.activate(allowing: layout.bundles(in: [.visible])) { [weak self] succeeded in
                    guard let self = self, self.isLifted, liftID == self.liftID else { return }
                    self.isLifted = false
                    if succeeded {
                        self.layout = layout
                        completion(.collapsed)
                    } else {
                        // Fail open, as a collapse does.
                        self.state = .expanded
                        self.setItemsHidden(false)
                        completion(.unavailable)
                    }
                }
            }
        }
        return true
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
            // Kept for re-applying the same hiding without a read, which only
            // an unrestricted bar answers correctly (see liftHidingBriefly).
            self.layout = layout
            body(layout)
        }
    }

    // Activates the new restriction before dropping the old one, so switching
    // between collapsed and expanded never flashes the whole bar visible.
    private func activate(allowing bundles: [String], completion: @escaping (Bool) -> Void) {
        generation += 1
        let generation = self.generation
        // Notification Center owns the calendar/widgets panel the clock opens.
        // Without its bundle in the allow-list, re-applying the restriction
        // dismisses that panel; with it, the panel survives while the apps'
        // icons go back into hiding. (Measured: re-applying anywhere from right
        // after the press to 0.2 s later keeps the panel open.) With Control
        // Center allowed, its items (Wi-Fi, Control Center...) also keep
        // working while the icons are hidden, and their menus stay open.
        let systemUIBundles = ["com.apple.notificationcenterui", "com.apple.controlcenter"]
        let allowed = (ownBundleIdentifier.map { [$0] } ?? []) + bundles + systemUIBundles
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
