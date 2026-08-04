import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var systemData = SharedStore.systemDataModel
    @ObservedObject var statusData = SharedStore.statusDataModel
    @ObservedObject var themeModel = SharedStore.themeModel
    @ObservedObject var globalModel = SharedStore.globalModel
    @ObservedObject var ipViewModel = SharedStore.ipListViewModel
    @State private var showSettings = false
    let appVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
                Text("iMonitor")
                    .font(.system(size: 13, weight: .semibold))
                Text("v\(appVersion)")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11, weight: .regular))
                Spacer()
                Button(action: openLogFolder) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open log")
                // Gear menu: Settings + Check for Updates… + Quit.
                // A SwiftUI Menu renders as a dropdown when the label is tapped,
                // satisfying the "click gear in top-right to update" requirement
                // without adding a separate button.
                Menu {
                    Button(action: { showSettings.toggle() }) {
                        menuLabel(
                            showSettings ? "Hide Settings" : "Settings",
                            systemName: showSettings ? "gearshape.fill" : "gearshape")
                    }
                    Divider()
                    Button(action: { AppDelegate.shared.performUpdate() }) {
                        menuLabel("Check for Updates…", systemName: "arrow.clockwise")
                    }
                    Divider()
                    Button(action: AppDelegate.quit) {
                        menuLabel("Quit iMonitor", systemName: "power", color: .red)
                    }
                } label: {
                    Image(systemName: settingsIconName)
                        .font(.system(size: 12))
                        .foregroundColor(showSettings ? .accentColor : .secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Settings · Updates · Quit")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if showSettings {
                SettingsView()
                Divider()
            }

            // System overview
            VStack(spacing: 6) {
                UsageBarRow(
                    label: "CPU", pct: systemData.cpuUsage,
                    detail: formatPercent(systemData.cpuUsage), themeColors: themeModel.colors)
                UsageBarRow(
                    label: "MEM", pct: memUsage,
                    detail: formatMem(systemData.memoryUsed, total: systemData.memoryTotal),
                    themeColors: themeModel.colors)
                UsageBarRow(
                    label: "GPU", pct: systemData.gpuUsage,
                    detail: formatPercent(systemData.gpuUsage), themeColors: themeModel.colors)

                HStack {
                    Spacer()
                    Text("↑\(formatBytesCompact(bytes: statusData.totalOutBytes))/s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("↓\(formatBytesCompact(bytes: statusData.totalInBytes))/s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // View mode + sort bar
            HStack(spacing: 0) {
                Text("View")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button(action: { globalModel.viewMode = mode }) {
                        Text(mode.displayName)
                            .font(
                                .system(
                                    size: 10,
                                    weight: globalModel.viewMode == mode ? .semibold : .regular)
                            )
                            .foregroundColor(
                                globalModel.viewMode == mode ? .accentColor : .secondary
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        globalModel.viewMode == mode
                                            ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if globalModel.viewMode == .process {
                    Divider()
                        .frame(height: 12)
                        .padding(.horizontal, 6)
                    Text("Sort")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 2)
                    ForEach(SortField.allCases, id: \.self) { field in
                        Button(action: { viewModel.sortField = field }) {
                            Text(field.displayName)
                                .font(
                                    .system(
                                        size: 10,
                                        weight: viewModel.sortField == field ? .semibold : .regular)
                                )
                                .foregroundColor(
                                    viewModel.sortField == field ? .accentColor : .secondary
                                )
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(
                                            viewModel.sortField == field
                                                ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                if globalModel.viewMode == .ip {
                    Text("app connections · Δ per \(AppConfig.networkInterval)s")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            Divider()

            // Process list / IP list
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    if globalModel.viewMode == .process {
                        let maxTotal =
                            viewModel.items
                            .map { $0.inBytes + $0.outBytes }
                            .max() ?? 0
                        ForEach(viewModel.items) { entity in
                            ProcessRow(processEntity: entity, maxTotal: maxTotal)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 3)
                        }
                    } else {
                        if ipViewModel.items.isEmpty {
                            Text("No external connections in this interval")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            let maxTotal =
                                ipViewModel.items
                                .map { $0.totalBytes }
                                .max() ?? 0
                            ForEach(ipViewModel.items) { entity in
                                IPRow(entity: entity, maxTotal: maxTotal)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 420)
        .background(Color("ContentBGColor"))
    }

    private var settingsIconName: String {
        if #available(macOS 12.0, *) { return "gearshape" } else { return "gear" }
    }

    /// Cross-version menu label. `Label(_:systemImage:)` needs macOS 13+;
    /// on older systems we fall back to an HStack of Image + Text.
    @ViewBuilder
    private func menuLabel(_ title: String, systemName: String, color: Color? = nil) -> some View {
        if #available(macOS 13.0, *) {
            if let color = color {
                Label(title, systemImage: systemName).foregroundColor(color)
            } else {
                Label(title, systemImage: systemName)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .foregroundColor(color)
                Text(title)
                    .foregroundColor(color)
            }
        }
    }

    private func openLogFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let logFile = dir.appendingPathComponent("imonitor.log")
        // Select the log file if it exists, otherwise just open the folder
        let fileToSelect = FileManager.default.fileExists(atPath: logFile.path) ? logFile.path : nil
        NSWorkspace.shared.selectFile(fileToSelect, inFileViewerRootedAtPath: dir.path)
    }

    private var memUsage: Double {
        systemData.memoryTotal > 0
            ? Double(systemData.memoryUsed) / Double(systemData.memoryTotal) : 0
    }

    private func formatPercent(_ value: Double) -> String {
        let pct = value * 100
        if pct < 0.1 { return "0%" }
        if pct < 10 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }

    private func formatMem(_ used: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "—" }
        let usedStr = formatMemValue(used)
        let totalStr = formatMemValue(total)
        return "\(usedStr)/\(totalStr)"
    }

    private func formatMemValue(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb < 1 {
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.0fM", mb)
        }
        if gb < 10 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fG", gb)
    }
}

struct UsageBarRow: View {
    let label: String
    let pct: Double
    let detail: String
    let themeColors: ThemeColors

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(themeColors.free.color)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 1)))
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f%%", pct * 100))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(barColor)
                .frame(width: 32, alignment: .trailing)

            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var barColor: Color {
        if pct < ThemeModel.overloadedThreshold { return themeColors.used.color }
        return themeColors.overloaded.color
    }
}

struct ProcessRow: View {
    var processEntity: ProcessEntity
    var maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: processEntity.pid, name: processEntity.name)
        let inActive = processEntity.inBytes > 0
        let outActive = processEntity.outBytes > 0
        let anyActive = inActive || outActive
        let cpuActive = processEntity.cpuUsage > 0.001
        let memActive = processEntity.memoryUsed > 0

        let total = processEntity.inBytes + processEntity.outBytes
        let totalRatio = maxTotal > 0 ? CGFloat(total) / CGFloat(maxTotal) : 0

        HStack(spacing: 6) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)

            Text(appInfo?.name ?? processEntity.name)
                .font(.system(size: 11, weight: anyActive ? .semibold : .regular))
                .foregroundColor(anyActive ? .primary : Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 90, alignment: .leading)

            // CPU
            HStack(spacing: 1) {
                Text("CPU")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(cpuActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatCpuPercent(processEntity.cpuUsage))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(cpuActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Memory
            HStack(spacing: 1) {
                Text("MEM")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(memActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: Int(processEntity.memoryUsed)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(memActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Down
            HStack(spacing: 1) {
                Text("↓")
                    .font(.system(size: 9))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.inBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Up
            HStack(spacing: 1) {
                Text("↑")
                    .font(.system(size: 9))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.outBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(outActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: proxy.size.width * totalRatio)
                    Spacer(minLength: 0)
                }
            }
        )
    }
}

struct IPRow: View {
    let entity: IpEntity
    let maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: entity.pid, name: entity.processName)
        let inActive = entity.inBytes > 0
        let outActive = entity.outBytes > 0
        let anyActive = inActive || outActive
        let total = entity.totalBytes
        let totalRatio = maxTotal > 0 ? CGFloat(total) / CGFloat(maxTotal) : 0
        let displayName = appInfo?.name ?? entity.processName

        HStack(spacing: 6) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)

            // Process name (primary) + remote IP (secondary, indented below)
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName)
                    .font(.system(size: 11, weight: anyActive ? .semibold : .regular))
                    .foregroundColor(anyActive ? .primary : Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entity.ip)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 150, alignment: .leading)

            // Connections
            HStack(spacing: 1) {
                Text("CONN")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\(entity.connections)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }

            // Down
            HStack(spacing: 1) {
                Text("↓")
                    .font(.system(size: 9))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: entity.inBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 40, alignment: .trailing)
            }

            // Up
            HStack(spacing: 1) {
                Text("↑")
                    .font(.system(size: 9))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: entity.outBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(outActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: proxy.size.width * totalRatio)
                    Spacer(minLength: 0)
                }
            }
        )
    }
}

private func formatCpuPercent(_ value: Double) -> String {
    let pct = value * 100
    if pct < 0.1 { return "—" }
    if pct < 10 { return String(format: "%.1f%%", pct) }
    return String(format: "%.0f%%", pct)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
