import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel = SharedStore.listViewModel
    let appVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image("Itraffic-logo-text")
                    .resizable()
                    .frame(width: 89.39, height: 20)
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
            .padding(.vertical, 10)

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
                            .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 440)
        .background(Color("ContentBGColor"))
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

        HStack(spacing: 8) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(appInfo?.name ?? processEntity.name)
                .font(.system(size: 12, weight: anyActive ? .semibold : .regular))
                .foregroundColor(anyActive ? .primary : Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // CPU
            HStack(spacing: 2) {
                Text("C")
                    .font(.system(size: 10))
                    .foregroundColor(cpuActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatCpuPercent(processEntity.cpuUsage))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(cpuActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Memory
            HStack(spacing: 2) {
                Text("M")
                    .font(.system(size: 10))
                    .foregroundColor(memActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: Int(processEntity.memoryUsed)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(memActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Down
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 10))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.inBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)
            }

            // Up
            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 10))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.outBytes))
                    .font(.system(size: 11, design: .monospaced))
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
