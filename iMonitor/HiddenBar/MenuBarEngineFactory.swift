//
//  MenuBarEngineFactory.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Foundation

// The single place that picks a hiding mechanism for the running OS.
enum MenuBarEngineFactory {
    static func make(items: HiddenMenuItemProvider) -> MenuBarEngine {
        // macOS 27 ejects an inflated separator from the menu bar, so hiding
        // happens natively there. iMonitor is never sandboxed, so the native
        // engine is always eligible.
        #if HIDDENBAR_NATIVE_VISIBILITY
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                return NativeVisibilityEngine(items: items)
            }
        #endif
        return LegacyLengthEngine(items: items)
    }
}
