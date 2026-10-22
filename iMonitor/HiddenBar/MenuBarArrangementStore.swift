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
    /// rows and the way macOS hides and shows icons (per app). System items are
    /// always visible, so they have no remembered section - and keying them by
    /// bundle would merge MenuBarAgent's four items into one entry.
    static func key(of info: MenuBarExtraInfo) -> String? {
        if info.isSystemItem { return nil }
        if let bundle = info.bundleIdentifier, !bundle.isEmpty {
            return bundle
        }
        // Status items without a bundle identifier (rare) still get a stable
        // identity, so they can be arranged like the rest.
        return info.appName.isEmpty ? nil : "name:" + info.appName
    }

    // MARK: - Writing

    /// Saves the arrangement the popup just created: the rows in the order
    /// they were dropped. `section` groups the remembered order; the popup's
    /// Hidden/Visible split itself always follows the live bar.
    static func record(_ placements: [(key: String, section: MenuBarSection)]) {
        var hidden: [String] = []
        var visible: [String] = []
        var seen = Set<String>()
        for placement in placements where seen.insert(placement.key).inserted {
            switch placement.section {
            case .hidden: hidden.append(placement.key)
            case .visible: visible.append(placement.key)
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

    /// The popup rows with the remembered arrangement applied as order only:
    /// the Hidden/Visible section always follows the live bar, so an icon whose
    /// move macOS refused is reported the way the bar shows it. Rows never
    /// arranged follow in their live order.
    static func arranged(
        hidden: [MenuBarExtraInfo],
        visible: [MenuBarExtraInfo]
    ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
        let stored = AppConfig.menuBarArrangement
        guard !stored.isEmpty else { return (hidden, visible) }
        let hiddenIndex = index(ofBundles: stored[key(of: .hidden)] ?? [])
        let visibleIndex = index(ofBundles: stored[key(of: .visible)] ?? [])

        func ordered(_ items: [MenuBarExtraInfo], _ order: [String: Int])
            -> [MenuBarExtraInfo]
        {
            var placed: [(Int, MenuBarExtraInfo)] = []
            var fresh: [MenuBarExtraInfo] = []
            for item in items {
                if let key = key(of: item), let index = order[key] {
                    placed.append((index, item))
                } else {
                    fresh.append(item)
                }
            }
            // Ties are several items of one app sharing its remembered slot:
            // they keep their live right-to-left order.
            placed.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.position.x > $1.1.position.x }
            return placed.map { $0.1 } + fresh
        }
        return (ordered(hidden, hiddenIndex), ordered(visible, visibleIndex))
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
