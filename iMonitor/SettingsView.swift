import SwiftUI

struct SettingsView: View {
    @ObservedObject var themeModel = SharedStore.themeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color Theme")
                .font(.system(size: 10, weight: .semibold))

            HStack(spacing: 6) {
                ForEach(ColorThemePreset.allCases, id: \.self) { preset in
                    Button(action: { themeModel.selectedPreset = preset }) {
                        VStack(spacing: 3) {
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(preset.colors.used.color)
                                    .frame(width: 14, height: 8)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(preset.colors.overloaded.color)
                                    .frame(width: 14, height: 8)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(preset.colors.free.color)
                                    .frame(width: 14, height: 8)
                            }
                            Text(preset.displayName)
                                .font(.system(size: 9))
                                .foregroundColor(themeModel.selectedPreset == preset ? .accentColor : .secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(themeModel.selectedPreset == preset ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
