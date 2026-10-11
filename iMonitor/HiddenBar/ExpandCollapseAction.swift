//
//  ExpandCollapseAction.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).
//  https://github.com/dwarvesf/hidden
//

import Cocoa

// What a press on the expand/collapse button should do. Kept as a pure mapping
// so the decision stays testable without a live status item or a real NSEvent.
enum ExpandCollapseAction {
    case toggle
    case showItemsList
    case ignore
    case contextMenu
    case toggleSeparators
}

enum ExpandCollapseActionResolver {
    // A nil event type means there is no real NSEvent behind the press, which is
    // what assistive synthesis (VoiceOver AXPress) produces: treat it as a plain
    // left click so VoiceOver users can toggle the bar at all.
    //
    // A click toggles the bar right away; the second click of a double-click
    // asks for the icons list instead (its first click has toggled already,
    // which the controller undoes). Further clicks of the same burst do
    // nothing, so a triple-click cannot flip the bar again under the list.
    static func action(
        eventType: NSEvent.EventType?, optionPressed: Bool, clickCount: Int = 1
    ) -> ExpandCollapseAction {
        guard let eventType = eventType else { return .toggle }
        if optionPressed { return .toggleSeparators }
        switch eventType {
        case .leftMouseUp:
            switch clickCount {
            case ...1: return .toggle
            case 2: return .showItemsList
            default: return .ignore
            }
        case .rightMouseUp: return .contextMenu
        default: return .toggleSeparators
        }
    }
}
