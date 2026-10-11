import Foundation

enum AppConfig {
    @UserDefaultsWrapper(key: "networkInterval", default: 2)
    static var networkInterval: Int

    @UserDefaultsWrapper(key: "systemInterval", default: 5)
    static var systemInterval: Int

    @UserDefaultsWrapper(key: "statusBarRefreshInterval", default: 2.0)
    static var statusBarRefreshInterval: Double

    @UserDefaultsWrapper(key: "colorTheme", default: "default")
    static var colorTheme: String

    // MARK: - Menu bar hiding (Hidden Bar feature)
    // Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation).

    /// Arrow + separator in the menu bar: move the `|` separator left of the
    /// icons you want hidden, then click the arrow to hide or show them.
    @UserDefaultsWrapper(key: "hideMenuBarEnabled", default: true)
    static var hideMenuBarEnabled: Bool

    /// Re-hide automatically after `hideAutoCollapseSeconds`.
    @UserDefaultsWrapper(key: "hideAutoCollapseEnabled", default: true)
    static var hideAutoCollapseEnabled: Bool

    @UserDefaultsWrapper(key: "hideAutoCollapseSeconds", default: 10.0)
    static var hideAutoCollapseSeconds: Double

    /// Expand the hidden zone when the pointer dwells in the menu bar.
    @UserDefaultsWrapper(key: "hideHoverToExpandEnabled", default: false)
    static var hideHoverToExpandEnabled: Bool

    // MARK: - Notch overflow

    /// The little dropdown that lists the menu-bar icons squeezed behind the
    /// camera notch (so they can still be opened).
    @UserDefaultsWrapper(key: "notchOverflowEnabled", default: true)
    static var notchOverflowEnabled: Bool

    /// The icon arrangement the user set by ⌘-dragging the notch-overflow
    /// popup's rows, so re-reading the live bar does not discard it:
    /// `{"hidden": [bundle id...], "visible": [...]}`, in display order within
    /// each array. Empty until the user arranges something.
    @UserDefaultsWrapper(key: "menuBarArrangement", default: [String: [String]]())
    static var menuBarArrangement: [String: [String]]

    /// Posted after the settings pane changes any of the menu-bar options above.
    /// A notification rather than a setter, matching the mostly-static AppConfig.
    static let preferencesChangedNotification = Notification.Name("iMonitorPreferencesChanged")

    /// Call after changing the menu-bar options so live components re-read them.
    static func notifyPreferencesChanged(_ object: Any? = nil) {
        NotificationCenter.default.post(
            name: preferencesChangedNotification, object: object)
    }
}

@propertyWrapper
struct UserDefaultsWrapper<T> {
    let key: String
    let defaultValue: T

    init(key: String, default: T) {
        self.key = key
        self.defaultValue = `default`
    }

    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
