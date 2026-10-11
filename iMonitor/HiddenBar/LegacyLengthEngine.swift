//
//  LegacyLengthEngine.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

// Hides icons by inflating the separator until everything to its left leaves the
// visible bar. macOS <= 26 reflows around any length, so the length only has to
// be large enough to cover the widest attached display.
final class LegacyLengthEngine: MenuBarEngine {
    private weak var items: HiddenMenuItemProvider?

    private let expandedLength: CGFloat = 20

    // On macOS 27 the menu bar re-architecture means inflating the separator may
    // no longer push items off-screen; NativeVisibilityEngine handles that OS
    // instead. This flag only guards a one-shot diagnostic log.
    private var hideMechanismChecked = false

    init(items: HiddenMenuItemProvider) {
        self.items = items
    }

    // Derived from the live length rather than stored, and compared with > rather
    // than ==, so the state survives the collapse length being recomputed while
    // collapsed.
    var state: MenuBarEngineState {
        guard let separator = items?.separatorItem else { return .expanded }
        return separator.length > expandedLength ? .collapsed : .expanded
    }

    private var collapsedLength: CGFloat {
        // The menubar replicates across every attached display, so the collapse
        // length must cover the WIDEST screen, not NSScreen.main (the focused one);
        // sizing from a narrower screen leaks hidden icons on wider displays.
        // frame.width, not visibleFrame: the menubar spans the full frame width.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        // Keep collapse length bounded to avoid pathological layout/memory
        // behavior; macOS enforces a hard 10,000pt maximum on NSStatusItem.length.
        return max(500, min(screenWidth * 2, 10_000))
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        items?.separatorItem.length = collapsedLength
        completion(.collapsed)
        verifyHideMechanismIfNeeded()
    }

    func expand() {
        items?.separatorItem.length = expandedLength
    }

    // The separator is what widens, so it must sit between the hidden icons and
    // the arrow.
    var isArrangementValid: Bool {
        return MenuBarOrder.isItem(items?.separatorItem, onHiddenSideOf: items?.toggleItem)
    }

    func invalidateLayout() {
        guard state == .collapsed else { return }
        items?.separatorItem.length = collapsedLength
    }

    // After a collapse, confirm on the next runloop tick (so layout settles) that
    // the separator actually claimed its inflated width. Diagnostics only: a
    // macOS that ignores NSStatusItem.length leaves the slot narrow, which is
    // exactly what this log would reveal. Checked once per launch.
    private func verifyHideMechanismIfNeeded() {
        guard !hideMechanismChecked else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.state == .collapsed else { return }
            // Need the separator's backing window to measure. If it is not up yet
            // (early launch), do NOT burn the one-shot check: return and let a
            // later collapse retry once the window exists.
            guard let separator = self.items?.separatorItem,
                let separatorButton = separator.button,
                let window = separatorButton.window
            else { return }
            self.hideMechanismChecked = true
            let requested = self.collapsedLength
            let windowWidth = window.frame.width
            let buttonWidth = separatorButton.frame.width
            AppLogger.info(
                "HideMechanism: requested=\(requested) windowWidth=\(windowWidth) "
                    + "buttonWidth=\(buttonWidth) length=\(separator.length)")
        }
    }
}
