import SwiftUI

struct SettingsView: View {
    @ObservedObject var themeModel = SharedStore.themeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color Theme")
                .font(.system(size: 11, weight: .semibold))

            HStack(spacing: 10) {
                ForEach(ColorThemePreset.allCases, id: \.self) { preset in
                    Button(action: { themeModel.selectedPreset = preset }) {
                        VStack(spacing: 4) {
                            // Preview: 3 bars with free bg + used fill
                            HStack(spacing: 3) {
                                ForEach([0.6, 0.4, 0.85], id: \.self) { usage in
                                    VStack(spacing: 0) {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(usage < ThemeModel.overloadedThreshold ? preset.colors.used.color : preset.colors.overloaded.color)
                                            .frame(width: 8, height: CGFloat(usage) * 24)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: 8, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(preset.colors.free.color)
                                    )
                                }
                            }
                            Text(preset.displayName)
                                .font(.system(size: 10, weight: themeModel.selectedPreset == preset ? .semibold : .regular))
                                .foregroundColor(themeModel.selectedPreset == preset ? .accentColor : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themeModel.selectedPreset == preset ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(themeModel.selectedPreset == preset ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
