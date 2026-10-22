//
//  MenuBarLayout.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Carbon
import Cocoa

// Which section a menu-bar item belongs to, read from where the user ⌘-dragged
// it relative to the arrow:
//
//     LTR:  [ hidden ] | > [ visible ]
//                       ^
//                   arrow (boundary)
enum MenuBarSection: Int, Comparable {
    case visible
    case hidden

    static func < (lhs: MenuBarSection, rhs: MenuBarSection) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// One status item another app owns. On macOS 27 Accessibility exposes no title or
// identifier for these, so the owning bundle and the frame are all there is.
struct MenuBarInventoryItem: Equatable {
    let bundleIdentifier: String?
    let frame: CGRect
}

protocol MenuBarInventoryProviding: AnyObject {
    var isAuthorized: Bool { get }
    func requestAuthorization()
    // Every other app's status items, delivered on the main queue. Only
    // meaningful while nothing is hidden: once a native visibility assertion is
    // active, hidden items report stale frames.
    func snapshot(completion: @escaping ([MenuBarInventoryItem]) -> Void)
}

struct MenuBarLayout: Equatable {
    // One section per owning bundle, because native hiding is per bundle.
    var sections: [String: MenuBarSection]

    func bundles(in wanted: Set<MenuBarSection>) -> [String] {
        return sections.filter { wanted.contains($0.value) }.map(\.key).sorted()
    }
}

/// The menu-bar items that belong to the input source menu (the language
/// switch). They must stay visible whatever the user arranges: hiding them
/// removes the only way to switch input methods from the bar. The system menu
/// is owned by TextInputMenuAgent; some third-party IMEs put their own item on
/// the bar, so the enabled input sources' bundles are included too. Read once:
/// adding or removing an input source takes a relaunch to show up, like the
/// rest of the app's launch-time menu-bar setup.
enum InputSourceVisibility {
    static let menuAgentBundle = "com.apple.TextInputMenuAgent"

    static let bundles: Set<String> = {
        var bundles: Set<String> = [menuAgentBundle]
        guard
            let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
                as? [TISInputSource]
        else { return bundles }
        for source in sources {
            guard let value = TISGetInputSourceProperty(source, kTISPropertyBundleID)
            else { continue }
            bundles.insert(Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String)
        }
        return bundles
    }()
}

/// Manual Hidden/Visible pins, keyed by owning bundle. The arrow position is
/// still the default section; a pin merely overrides it for that app, so the
/// Settings list can configure hiding without physically moving icons and a
/// dropped dropdown row survives a failed synthetic drag. macOS 27 hides per
/// bundle, which is what makes the pin enforceable.
enum MenuBarSectionOverrides {
    static var current: [String: Bool] {
        return AppConfig.menuBarItemSectionOverrides
    }

    static func hidden(for bundle: String?) -> Bool? {
        guard let bundle, !bundle.isEmpty else { return nil }
        return current[bundle]
    }

    static func set(_ bundle: String, hidden: Bool) {
        var overrides = current
        overrides[bundle] = hidden
        AppConfig.menuBarItemSectionOverrides = overrides
    }

    static func clear() {
        AppConfig.menuBarItemSectionOverrides = [:]
    }

    /// Applies the pins to resolved sections. System owners and iMonitor
    /// itself are never pinned; their visibility is macOS's business.
    static func applied(
        to sections: [String: MenuBarSection], excluding excluded: Set<String>
    ) -> [String: MenuBarSection] {
        var result = sections
        for (bundle, hidden) in current where !excluded.contains(bundle) {
            result[bundle] = hidden ? .hidden : .visible
        }
        return result
    }
}

enum MenuBarLayoutResolver {
    // Bundles whose items are macOS's own controls (clock, Wi-Fi, Control
    // Center...). Their visibility is governed by the native system-item
    // allow-list, so they are left out of the layout and kept visible
    // separately. The input source menu (the language switch) is always kept
    // visible too; see InputSourceVisibility. SystemUIServer is NOT one of
    // them: its legacy extras (Time Machine...) are ordinary menu items that
    // follow the user's arrangement, so they must be sectioned by position
    // like any app's icons.
    static let systemItemOwners: Set<String> = Set([
        "com.apple.MenuBarAgent", "com.apple.controlcenter",
    ]).union(InputSourceVisibility.bundles)

    static func resolve(
        inventory: [MenuBarInventoryItem],
        separatorFrame: CGRect,
        isLTR: Bool,
        excludingBundle ownBundle: String?
    ) -> MenuBarLayout {
        var sections: [String: MenuBarSection] = [:]
        for item in inventory {
            guard let bundle = item.bundleIdentifier,
                bundle != ownBundle,
                !systemItemOwners.contains(bundle)
            else { continue }
            let section = self.section(
                of: item.frame,
                separatorFrame: separatorFrame,
                isLTR: isLTR)
            // One app can own several items, but hiding applies to the whole
            // bundle. The most visible item wins so an icon the user kept visible
            // is never hidden because a sibling sits in the hidden section.
            sections[bundle] = min(sections[bundle] ?? section, section)
        }
        var excluded = systemItemOwners
        if let ownBundle {
            excluded.insert(ownBundle)
        }
        return MenuBarLayout(
            sections: MenuBarSectionOverrides.applied(to: sections, excluding: excluded))
    }

    static func section(
        of frame: CGRect,
        separatorFrame: CGRect,
        isLTR: Bool
    ) -> MenuBarSection {
        // Distance toward the arrow side: positive means on the visible side.
        let towardArrow =
            isLTR
            ? frame.midX - separatorFrame.midX
            : separatorFrame.midX - frame.midX
        return towardArrow > 0 ? .visible : .hidden
    }
}
