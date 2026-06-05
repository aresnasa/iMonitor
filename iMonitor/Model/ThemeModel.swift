import SwiftUI

struct ThemeColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var nsColor: NSColor {
        NSColor(red: CGFloat(red), green: CGFloat(green),
                blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct ThemeColors: Equatable {
    var used: ThemeColor
    var overloaded: ThemeColor
    var free: ThemeColor
}

enum ColorThemePreset: String, CaseIterable, Codable {
    case `default` = "default"
    case ocean = "ocean"
    case forest = "forest"
    case monokai = "monokai"

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .monokai: return "Monokai"
        }
    }

    var colors: ThemeColors {
        switch self {
        case .default:
            return ThemeColors(
                used: ThemeColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.9),
                overloaded: ThemeColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 0.9),
                free: ThemeColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 0.35)
            )
        case .ocean:
            return ThemeColors(
                used: ThemeColor(red: 0.0, green: 0.6, blue: 0.85, alpha: 0.9),
                overloaded: ThemeColor(red: 0.85, green: 0.2, blue: 0.35, alpha: 0.9),
                free: ThemeColor(red: 0.15, green: 0.35, blue: 0.55, alpha: 0.4)
            )
        case .forest:
            return ThemeColors(
                used: ThemeColor(red: 0.3, green: 0.75, blue: 0.2, alpha: 0.9),
                overloaded: ThemeColor(red: 0.9, green: 0.35, blue: 0.1, alpha: 0.9),
                free: ThemeColor(red: 0.15, green: 0.4, blue: 0.12, alpha: 0.35)
            )
        case .monokai:
            return ThemeColors(
                used: ThemeColor(red: 0.98, green: 0.97, blue: 0.04, alpha: 0.9),
                overloaded: ThemeColor(red: 0.95, green: 0.15, blue: 0.5, alpha: 0.9),
                free: ThemeColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.4)
            )
        }
    }
}

class ThemeModel: ObservableObject {
    static let overloadedThreshold = 0.85

    @Published var selectedPreset: ColorThemePreset {
        didSet { AppConfig.colorTheme = selectedPreset.rawValue }
    }

    var colors: ThemeColors { selectedPreset.colors }

    init() {
        let raw = AppConfig.colorTheme
        self.selectedPreset = ColorThemePreset(rawValue: raw) ?? .default
    }
}
