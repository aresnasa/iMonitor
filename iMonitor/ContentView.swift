import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var systemData = SharedStore.systemDataModel
    @ObservedObject var statusData = SharedStore.statusDataModel
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
                MenuItem(id: "menu.github", text: "Github", action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/aresnasa/iMonitor")!)
                })
                MenuItem(id: "menu.quit", text: "Quit", action: AppDelegate.quit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // System overview
            VStack(spacing: 6) {
                UsageBarRow(label: "CPU", pct: systemData.cpuUsage, detail: formatPercent(systemData.cpuUsage))
                UsageBarRow(label: "MEM", pct: memUsage, detail: formatMem(systemData.memoryUsed, total: systemData.memoryTotal))
                UsageBarRow(label: "GPU", pct: systemData.gpuUsage, detail: formatPercent(systemData.gpuUsage))

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

            // Sort bar
            HStack(spacing: 0) {
                Text("Sort")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
                ForEach(SortField.allCases, id: \.self) { field in
                    Button(action: { viewModel.sortField = field }) {
                        Text(field.displayName)
                            .font(.system(size: 10, weight: viewModel.sortField == field ? .semibold : .regular))
                            .foregroundColor(viewModel.sortField == field ? .accentColor : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(viewModel.sortField == field ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            Divider()

            // Process list
            ScrollView {
                VStack(spacing: 0) {
                    let maxTotal = viewModel.items
                        .map { $0.inBytes + $0.outBytes }
                        .max() ?? 0
                    ForEach(viewModel.items) { entity in
                        ProcessRow(processEntity: entity, maxTotal: maxTotal)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
        .frame(width: 420)
        .background(Color("ContentBGColor"))
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

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.15))
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
        if pct < 0.85 { return .orange }
        return .red
    }
}

struct ProcessRow: View {
    var processEntity: ProcessEntity
    var maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: processEntity.pid, name: processEntity.name)
        let inActive  = processEntity.inBytes  > 0
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
                .frame(maxWidth: .infinity, alignment: .leading)

            // CPU
            HStack(spacing: 2) {
                Text("C")
                    .font(.system(size: 9))
                    .foregroundColor(cpuActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatCpuPercent(processEntity.cpuUsage))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(cpuActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 32, alignment: .trailing)
            }

            // Memory
            HStack(spacing: 2) {
                Text("M")
                    .font(.system(size: 9))
                    .foregroundColor(memActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: Int(processEntity.memoryUsed)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(memActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 32, alignment: .trailing)
            }

            // Down
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 9))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.inBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 32, alignment: .trailing)
            }

            // Up
            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 9))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.outBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(outActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 32, alignment: .trailing)
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
