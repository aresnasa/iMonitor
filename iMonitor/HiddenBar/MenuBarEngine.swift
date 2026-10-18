//
//  MenuBarEngine.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

// HiddenBarController decides WHAT the user wants (collapsed or expanded); an
// engine decides HOW the menu bar is made to do it. Keeping the mechanics behind
// this protocol lets an OS release that changes menu-bar layout (e.g. macOS 27)
// get its own engine without version checks spreading through the controller.
protocol MenuBarEngine: AnyObject {
    var state: MenuBarEngineState { get }

    func collapse(completion: @escaping (CollapseResult) -> Void)
    func expand()

    // Whether the user's ⌘-drag arrangement lets the engine hide anything: its
    // hiding boundary must sit on the hidden side of the arrow. The controller
    // does not collapse otherwise.
    var isArrangementValid: Bool { get }

    // Display geometry changed. Re-applies the collapse to the live items when
    // collapsed, so a hot-plug does not leave a stale length behind.
    func invalidateLayout()

    // MARK: - macOS's own items

    // Whether this engine's hiding leaves one of macOS's own menu-bar items -
    // the clock, which opens the calendar/widgets panel - visible but inert, so
    // a click on it has to be helped through (see SystemItemClickForwarder).
    // macOS 27's native hiding does; the legacy length engine never touches it.
    var blocksSystemItemClicks: Bool { get }

    // Lifts the hiding for a moment - the hidden icons pop out - runs `press`
    // once the clock responds again, then puts the hiding back. The state
    // stays .collapsed throughout, since the hiding the user asked for still
    // stands. Returns false, running nothing, when there is no hiding to
    // lift. The completion reports the re-applied hiding on the main queue;
    // it is not called when an expand() overtook the lift.
    func liftHidingBriefly(
        for press: @escaping () -> Void, completion: @escaping (CollapseResult) -> Void
    ) -> Bool
}

extension MenuBarEngine {
    var blocksSystemItemClicks: Bool { return false }

    func liftHidingBriefly(
        for press: @escaping () -> Void, completion: @escaping (CollapseResult) -> Void
    ) -> Bool {
        return false
    }
}

enum MenuBarEngineState {
    case expanded
    case calibrating
    case collapsed
    case unavailable
}

enum CollapseResult {
    case collapsed
    case unavailable
}

enum MenuBarOrder {
    // True when `item` sits on the hidden side of `boundary`: to its left in a
    // left-to-right layout, to its right otherwise. False when either is not on
    // screen, since nothing can be judged then.
    static func isItem(_ item: NSStatusItem?, onHiddenSideOf boundary: NSStatusItem?) -> Bool {
        guard let itemX = item?.button?.window?.frame.origin.x,
            let boundaryX = boundary?.button?.window?.frame.origin.x
        else { return false }
        return isUsingLTRLanguage ? boundaryX >= itemX : boundaryX <= itemX
    }

    // Inlined from Hidden Bar's `Constant.isUsingLTRLanguage`.
    static var isUsingLTRLanguage: Bool {
        return NSApp.userInterfaceLayoutDirection == .leftToRight
    }
}

// The controller owns and recreates the status items; engines only borrow them.
protocol HiddenMenuItemProvider: AnyObject {
    var toggleItem: NSStatusItem { get }
    var separatorItem: NSStatusItem { get }
}
