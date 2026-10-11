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
                                            .fill(
                                                usage < ThemeModel.overloadedThreshold
                                                    ? preset.colors.used.color
                                                    : preset.colors.overloaded.color
                                            )
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
                                .font(
                                    .system(
                                        size: 10,
                                        weight: themeModel.selectedPreset == preset
                                            ? .semibold : .regular)
                                )
                                .foregroundColor(
                                    themeModel.selectedPreset == preset ? .accentColor : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    themeModel.selectedPreset == preset
                                        ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    themeModel.selectedPreset == preset
                                        ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            MenuBarSettingsView()

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

/// Menu-bar icon hiding (ported from Hidden Bar) and the menu-bar items
/// dropdown. `@AppStorage` persists straight to `UserDefaults`; the
/// notification lets the live controller re-read the auto-collapse settings
/// and the dropdown controller appear/disappear live, while toggles that
/// structure the menu bar ask for a restart.
struct MenuBarSettingsView: View {
    @AppStorage("hideMenuBarEnabled") private var hideEnabled = true
    @AppStorage("hideAutoCollapseEnabled") private var autoCollapseEnabled = true
    @AppStorage("hideAutoCollapseSeconds") private var autoCollapseSeconds = 10.0
    @AppStorage("hideHoverToExpandEnabled") private var hoverToExpand = false
    @AppStorage("hideHoverExpandSeconds") private var hoverExpandSeconds = 0.5
    @AppStorage("notchOverflowEnabled") private var notchEnabled = true

    // Only meaningful while Accessibility is missing; refreshed whenever the app
    // returns to the foreground (System Settings visits included).
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar")
                .font(.system(size: 11, weight: .semibold))

            Toggle("Hide menu-bar icons (Hidden Bar)", isOn: $hideEnabled)
                .font(.system(size: 11))

            if hideEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Toggle("Auto collapse", isOn: $autoCollapseEnabled)
                            .font(.system(size: 11))
                        Spacer()
                        Stepper(
                            value: $autoCollapseSeconds, in: 3...60, step: 1,
                            label: {
                                Text("\(Int(autoCollapseSeconds))s")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            })
                    }
                    Toggle("Expand on hover", isOn: $hoverToExpand)
                        .font(.system(size: 11))
                        .help(
                            "Rest the pointer on an empty part of the menu bar to peek at the "
                                + "hidden icons. Moving over app menus or other icons, or "
                                + "clicking them, never reveals them.")

                    // Only an empty stretch of the bar reveals (the arrow
                    // itself opens the dropdown on click), after this rest.
                    if hoverToExpand {
                        HStack(spacing: 6) {
                            Text("Hover delay")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Stepper(
                                value: $hoverExpandSeconds,
                                in: AppConfig.minimumHoverExpandSeconds...5, step: 0.5,
                                label: {
                                    Text(
                                        String(
                                            format: "%.1fs",
                                            max(
                                                hoverExpandSeconds,
                                                AppConfig.minimumHoverExpandSeconds))
                                    )
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                }
                            )
                            .help(
                                "How long the pointer must rest on an empty part of the menu "
                                    + "bar before the hidden icons appear")
                        }
                    }

                    // Both features below silently do nothing without this
                    // permission, so surface it right where they are configured.
                    HStack(spacing: 6) {
                        Image(
                            systemName: accessibilityGranted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                        Text(
                            accessibilityGranted
                                ? "Accessibility permission granted."
                                : AppConfig.accessibilityGrantedOnce
                                    ? "Enabled for another iMonitor build - remove the old entries, then grant this copy."
                                    : "Accessibility permission required to list menu-bar icons."
                        )
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        Spacer()
                        if !accessibilityGranted {
                            Button("Grant\u{2026}") {
                                AccessibilityPermission.request()
                                AccessibilityPermission.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 4)

                Text(
                    "The arrow's slot is the hiding boundary: position it just to the left "
                        + "of the icons you want hidden."
                )
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Menu-bar items dropdown (double-click the iMonitor icon)", isOn: $notchEnabled)
                .font(.system(size: 11))

            if notchEnabled {
                HStack(spacing: 6) {
                    Text(
                        "The order you set by \u{2318}-dragging the dropdown list is remembered, "
                            + "so it opens the way you arranged it."
                    )
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset") {
                        MenuBarArrangementStore.reset()
                    }
                    .controlSize(.small)
                    .help("Forget the remembered order and follow the live menu bar again")
                }
            }

            if #available(macOS 26.0, *), hideEnabled {
                Text(
                    "If the arrow does not appear, enable the iMonitor items in System Settings › Control Center › Menu Bar."
                )
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if notchEnabled && !NotchOverflowController.hasNotch {
                Text(
                    "No notched display attached: the chevron lists every menu-bar icon "
                        + "instead of just the ones hidden behind the notch."
                )
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: hideEnabled) { _ in needsRestart() }
        // The dropdown owns no status item, so it appears/disappears live.
        .onChange(of: notchEnabled) { _ in AppConfig.notifyPreferencesChanged() }
        .onChange(of: autoCollapseEnabled) { _ in AppConfig.notifyPreferencesChanged() }
        .onChange(of: autoCollapseSeconds) { _ in AppConfig.notifyPreferencesChanged() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AccessibilityPermission.mayHaveChangedNotification)
        ) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
        }
    }

    // Toggles that change which items exist in the menu bar only apply at launch.
    private func needsRestart() {
        AppConfig.notifyPreferencesChanged()
        AppDelegate.presentRestartPrompt()
    }
}
