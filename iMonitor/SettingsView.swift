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

            ProcessColumnSettingsView()

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

/// Resource-column order for the process list rows. Up/down buttons rather
/// than drag-reorder: five rows in a form-shaped settings pane, where hitting
/// a small target beats dragging.
struct ProcessColumnSettingsView: View {
    @ObservedObject var columns = SharedStore.processColumnsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resource Columns")
                .font(.system(size: 11, weight: .semibold))

            ForEach(Array(columns.order.enumerated()), id: \.element) { index, column in
                HStack(spacing: 6) {
                    Text(column.displayName)
                        .font(.system(size: 11))
                        .frame(width: 44, alignment: .leading)

                    Spacer()

                    Button(action: { columns.move(column, by: -1) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .help("Move \(column.displayName) left")

                    Button(action: { columns.move(column, by: 1) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == columns.order.count - 1)
                    .help("Move \(column.displayName) right")
                }
                .foregroundColor(
                    index == 0 || index == columns.order.count - 1 ? .secondary : .primary)
            }

            Text("Order of the resource columns in the process list.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
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
    @StateObject private var itemsModel = MenuBarItemsModel()

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

                    // Only an empty stretch of the bar reveals (a click on the
                    // arrow itself expands), after this rest.
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

            // Always visible in Settings: even with hiding off this is the
            // complete inventory of menu-bar icons, with the system items
            // called out separately.
            MenuBarItemsSettingsView(model: itemsModel)

            Toggle(
                "Menu-bar items dropdown (double-click the iMonitor icon or the arrow)",
                isOn: $notchEnabled
            )
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
                        MenuBarSectionOverrides.clear()
                        AppConfig.notifyPreferencesChanged()
                        itemsModel.refresh()
                    }
                    .controlSize(.small)
                    .help(
                        "Forget the remembered order and the manual Hidden/Visible choices")
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
                    "No notched display attached: the chevron follows the Hidden Bar arrow's "
                        + "Hidden/Visible split when icon hiding is on, and lists every icon "
                        + "otherwise."
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

/// One row of the Settings menu-bar items list. Holds the AX item so a toggle
/// can name its owning bundle; the display name/icon are resolved once per
/// refresh and never left nil (the list must not drop an icon).
struct MenuBarSettingsItem: Identifiable {
    let id: String
    let info: MenuBarExtraInfo
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
    var isHidden: Bool
    let isSystem: Bool
    let canToggle: Bool
    let isOnMenuBar: Bool
}

final class MenuBarItemsModel: ObservableObject {
    @Published private(set) var hidden: [MenuBarSettingsItem] = []
    @Published private(set) var visible: [MenuBarSettingsItem] = []
    @Published private(set) var system: [MenuBarSettingsItem] = []
    @Published private(set) var offBar: [MenuBarSettingsItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthorized = AccessibilityPermission.isGranted
    @Published private(set) var canConfigure = false

    // A refresh walks every running app; a slow earlier walk must not overwrite
    // the result of a newer one.
    private var generation = 0

    func refresh() {
        guard !isLoading else { return }
        guard AccessibilityPermission.isGranted else {
            isAuthorized = false
            hidden = []
            visible = []
            system = []
            offBar = []
            isLoading = false
            return
        }
        isAuthorized = true
        isLoading = true
        generation += 1
        let generation = self.generation

        let app = AppDelegate.shared
        let hiddenBoundary = app.menuBarHiddenBoundaryX
        let hidesPerBundle = app.menuBarHidesItemsPerBundle
        let notchBoundary = NotchOverflowController.currentNotchBoundaryX
        let hasNotch = NotchOverflowController.hasNotch

        NotchOverflowController.scanExtras { [weak self] extras in
            guard let self, generation == self.generation else { return }
            let snapshot = MenuBarItemsResolver.resolve(
                extras: extras,
                hiddenBoundary: hiddenBoundary,
                notchBoundary: notchBoundary,
                hasNotch: hasNotch,
                hidesPerBundle: hidesPerBundle,
                isLTR: MenuBarOrder.isUsingLTRLanguage,
                overrides: MenuBarSectionOverrides.current)
            self.canConfigure = hidesPerBundle
            self.hidden = Self.rows(snapshot.hidden, hidden: true, canConfigure: hidesPerBundle)
            self.visible = Self.rows(
                snapshot.visible.filter { !$0.isSystemItem }, hidden: false,
                canConfigure: hidesPerBundle)
            self.system = Self.rows(
                snapshot.system, hidden: false, canConfigure: false)
            self.offBar = Self.rows(
                snapshot.offBar, hidden: false, canConfigure: false)
            self.isLoading = false
        }
    }

    private static func rows(
        _ items: [MenuBarExtraInfo], hidden: Bool, canConfigure: Bool
    ) -> [MenuBarSettingsItem] {
        var seen = Set<String>()
        return items.map { info in
            var id = [
                info.bundleIdentifier ?? "", info.identifier ?? "", info.title ?? "",
                String(info.pid), String(Int(info.position.x)), String(Int(info.position.y)),
            ].joined(separator: "|")
            while seen.contains(id) { id += "'" }
            seen.insert(id)
            return MenuBarSettingsItem(
                id: id,
                info: info,
                name: info.displayName,
                icon: info.displayIcon,
                bundleIdentifier: info.bundleIdentifier,
                isHidden: hidden,
                isSystem: info.isSystemItem,
                canToggle: canConfigure && !info.isSystemItem
                    && info.bundleIdentifier?.isEmpty == false,
                isOnMenuBar: info.isOnMenuBar)
        }
    }

    /// A toggle writes a manual pin, not a physical move: macOS 27 hides per
    /// bundle, so the pin is enforceable while the bar is collapsed. Every row
    /// of the bundle follows (one app hides as a whole).
    func toggle(_ row: MenuBarSettingsItem) {
        guard row.canToggle, let bundle = row.bundleIdentifier else { return }
        let makeHidden = !row.isHidden
        MenuBarSectionOverrides.set(bundle, hidden: makeHidden)
        AppConfig.notifyPreferencesChanged()

        var moved = (hidden + visible).filter { $0.bundleIdentifier == bundle }
        hidden.removeAll { $0.bundleIdentifier == bundle }
        visible.removeAll { $0.bundleIdentifier == bundle }
        for index in moved.indices { moved[index].isHidden = makeHidden }
        if makeHidden {
            hidden.append(contentsOf: moved)
            hidden.sort { $0.info.position.x > $1.info.position.x }
        } else {
            visible.append(contentsOf: moved)
            visible.sort { $0.info.position.x > $1.info.position.x }
        }
    }

    func resetPins() {
        MenuBarSectionOverrides.clear()
        AppConfig.notifyPreferencesChanged()
        refresh()
    }

    func openOwnerApp(_ row: MenuBarSettingsItem) {
        NSRunningApplication(processIdentifier: row.info.pid)?.activate()
    }
}

/// The complete menu-bar inventory, grouped the same way as the dropdown.
/// System items are listed separately because their visibility belongs to
/// macOS; every other row can be pinned Hidden or Visible here.
struct MenuBarItemsSettingsView: View {
    @ObservedObject var model: MenuBarItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Menu-bar Items")
                    .font(.system(size: 11, weight: .semibold))
                if model.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("Refresh") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
                    .help("Re-read every app's menu-bar icons")
                Button("Reset Pins") { model.resetPins() }
                    .controlSize(.small)
                    .disabled(!model.canConfigure)
                    .help("Forget manual Hidden/Visible choices")
            }

            if !model.isAuthorized {
                MenuBarItemsHint(
                    "Accessibility permission is required to list menu-bar icons.")
            } else if !model.isLoading && model.hidden.isEmpty && model.visible.isEmpty
                && model.system.isEmpty && model.offBar.isEmpty
            {
                MenuBarItemsHint("No menu-bar items found.")
            } else {
                if !model.canConfigure {
                    MenuBarItemsHint(
                        "Manual Hide/Show needs per-app hiding (macOS 27) and Hide menu-bar "
                            + "icons enabled. Position the arrow or ⌘-drag rows in the dropdown "
                            + "instead.")
                } else {
                    MenuBarItemsHint(
                        "Hidden/Visible here pins an app and overrides the arrow position. "
                            + "The eye button moves every icon the app owns.")
                }
                group("Hidden", model.hidden, hidden: true)
                group("Visible", model.visible, hidden: false)
                group("Always visible", model.system, hidden: false)
                if !model.offBar.isEmpty {
                    group("Not on the menu bar", model.offBar, hidden: false)
                    Button("Open Menu Bar Settings…") {
                        openMenuBarSettings()
                    }
                    .controlSize(.small)
                    .help("Enable the app's item in System Settings › Control Center › Menu Bar")
                }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AccessibilityPermission.mayHaveChangedNotification)
        ) { _ in model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in model.refresh() }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [MenuBarSettingsItem], hidden: Bool)
        -> some View
    {
        if !rows.isEmpty {
            Text("\(title) (\(rows.count))")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    MenuBarItemIcon(image: row.icon, dimmed: hidden)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !row.isOnMenuBar {
                            Text("not currently drawn on the bar — relaunch the app")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if row.isSystem {
                        Text("System")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    } else if !row.isOnMenuBar {
                        Button("Open") { model.openOwnerApp(row) }
                            .controlSize(.small)
                            .help("Open the app and choose a menu-bar icon")
                    } else if row.canToggle {
                        Button {
                            model.toggle(row)
                        } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help(hidden ? "Show in the menu bar" : "Hide when the bar is collapsed")
                    }
                }
                .opacity(hidden ? 0.7 : 1)
            }
        }
    }

    /// The macOS menu-bar management UI is the supported way to bring back an
    /// item the system removed from the bar.
    private func openMenuBarSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MenuBarItemsHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuBarItemIcon: View {
    let image: NSImage?
    let dimmed: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "menubar.rectangle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 16, height: 16)
        .foregroundColor(.primary)
        .opacity(dimmed ? 0.6 : 1)
        .help("Menu-bar icon")
    }
}
