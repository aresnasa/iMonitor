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

            Divider()

            HStack {
                Button(action: openLogFolder) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 10))
                        Text("Open Log")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button(action: AppDelegate.quit) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10))
                        Text("Quit")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func openLogFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logFile = dir.appendingPathComponent("imonitor.log")
        let fileToSelect = FileManager.default.fileExists(atPath: logFile.path) ? logFile.path : nil
        NSWorkspace.shared.selectFile(fileToSelect, inFileViewerRootedAtPath: dir.path)
    }
}
