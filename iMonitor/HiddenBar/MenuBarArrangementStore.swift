//
//  MenuBarArrangementStore.swift
//  iMonitor
//
//  Remembers the icon arrangement the user set in the notch-overflow popup.
//
//  The popup used to re-derive its rows from the live bar on every open, so a
//  ⌘-drag rearrangement - and especially one macOS refused to carry out on the
//  real bar - was gone the next time it opened and the user had to do it
//  again. This store keeps the arrangement the user last set: rows they have
//  arranged stay in the order and section they were dropped into; rows they
//  never arranged keep following the live bar, so new icons still appear where
//  their position puts them.
//

import Foundation

enum MenuBarArrangementStore {

    // MARK: - Identity

    /// How a row is remembered. One entry per bundle matches both the popup's
    /// rows and the way macOS hides and shows icons (per app).
    static func key(of info: MenuBarExtraInfo) -> String? {
        if let bundle = info.bundleIdentifier, !bundle.isEmpty {
            return bundle
        }
        // Status items without a bundle identifier (rare) still get a stable
        // identity, so they can be arranged like the rest.
        return info.appName.isEmpty ? nil : "name:" + info.appName
    }

    // MARK: - Writing

    /// Saves the arrangement the popup just created: the rows in the order
    /// they were dropped, each with the section it landed in. Only the first
    /// placement of a bundle counts - one app owns one remembered position.
    static func record(_ placements: [(bundle: String, section: MenuBarSection)]) {
        var hidden: [String] = []
        var visible: [String] = []
        var seen = Set<String>()
        for placement in placements where seen.insert(placement.bundle).inserted {
            switch placement.section {
            case .hidden: hidden.append(placement.bundle)
            case .visible: visible.append(placement.bundle)
            }
        }
        AppConfig.menuBarArrangement = [
            key(of: .hidden): hidden,
            key(of: .visible): visible,
        ]
        AppLogger.info(
            "NotchOverflow: remembered arrangement saved "
                + "(\(hidden.count) hidden, \(visible.count) visible)")
    }

    /// Drops the remembered arrangement; the popup goes back to mirroring the
    /// live bar exactly.
    static func reset() {
        AppConfig.menuBarArrangement = [:]
        AppLogger.info("NotchOverflow: remembered arrangement cleared")
    }

    // MARK: - Reading

    /// The popup rows with the remembered arrangement applied: arranged
    /// bundles come first, in their remembered order and section; rows never
    /// arranged follow in their live order. A bundle's remembered section wins
    /// over its live one, so an arrangement macOS did not carry out on the
    /// real bar still shows the way the user set it up.
    static func arranged(
        hidden: [MenuBarExtraInfo],
        visible: [MenuBarExtraInfo]
    ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
        let stored = AppConfig.menuBarArrangement
        if stored.isEmpty {
            return (hidden, visible)
        }
        let hiddenIndex = index(ofBundles: stored[key(of: .hidden)] ?? [])
        let visibleIndex = index(ofBundles: stored[key(of: .visible)] ?? [])

        var placedHidden: [(Int, MenuBarExtraInfo)] = []
        var placedVisible: [(Int, MenuBarExtraInfo)] = []
        var freshHidden: [MenuBarExtraInfo] = []
        var freshVisible: [MenuBarExtraInfo] = []

        func place(_ items: [MenuBarExtraInfo], physicallyHidden: Bool) {
            for item in items {
                if let bundle = key(of: item) {
                    if let index = hiddenIndex[bundle] {
                        placedHidden.append((index, item))
                        continue
                    }
                    if let index = visibleIndex[bundle] {
                        placedVisible.append((index, item))
                        continue
                    }
                }
                if physicallyHidden {
                    freshHidden.append(item)
                } else {
                    freshVisible.append(item)
                }
            }
        }
        place(hidden, physicallyHidden: true)
        place(visible, physicallyHidden: false)

        // Ties are several items of one app sharing its remembered slot: they
        // keep their live right-to-left order.
        func ordered(_ placed: [(Int, MenuBarExtraInfo)]) -> [MenuBarExtraInfo] {
            return placed.sorted {
                $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.position.x > $1.1.position.x
            }.map { $0.1 }
        }
        return (
            ordered(placedHidden) + freshHidden,
            ordered(placedVisible) + freshVisible
        )
    }

    /// The hidden flag a dropped row adopts: the flag of the row it was
    /// dropped above, or of the row above it when dropped at the very end of
    /// the list. `nil` when there is nothing to adopt from.
    static func adoptedHiddenFlag(afterDropAt insertion: Int, in flags: [Bool]) -> Bool? {
        if flags.indices.contains(insertion + 1) {
            return flags[insertion + 1]
        }
        if flags.indices.contains(insertion - 1) {
            return flags[insertion - 1]
        }
        return nil
    }

    // MARK: - Helpers

    private static func key(of section: MenuBarSection) -> String {
        return section == .hidden ? "hidden" : "visible"
    }

    /// First occurrence wins, matching `record`'s dedupe.
    private static func index(ofBundles bundles: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, bundle) in bundles.enumerated() where result[bundle] == nil {
            result[bundle] = index
        }
        return result
    }
}
