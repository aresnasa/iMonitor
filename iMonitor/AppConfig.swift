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
