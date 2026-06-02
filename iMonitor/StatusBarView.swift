import SwiftUI

struct StatusBarView: View {
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    @ObservedObject var systemDataModel = SharedStore.systemDataModel

    private let barWidth: CGFloat = 4
    private let barHeight: CGFloat = 20
    private let spacing: CGFloat = 5
    private let labelWidth: CGFloat = 10
    private let valueWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // CPU
            resourceColumn(label: "C", value: formatPercent(systemDataModel.cpuUsage), usage: systemDataModel.cpuUsage)

            // Memory
            resourceColumn(label: "M", value: formatMemoryPercent(), usage: memoryUsageRatio)

            // GPU
            resourceColumn(label: "G", value: formatPercent(systemDataModel.gpuUsage), usage: systemDataModel.gpuUsage)

            // Network
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    Text("↗")
                        .font(.system(size: 9))
                    Text(formatBytes(bytes: statusDataModel.totalOutBytes))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: 10, alignment: .center)

                HStack(spacing: 1) {
                    Text("↙")
                        .font(.system(size: 9))
                    Text(formatBytes(bytes: statusDataModel.totalInBytes))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: 10, alignment: .center)
                .padding(.top, -1)
            }
        }
    }

    private func resourceColumn(label: String, value: String, usage: Double) -> some View {
        VStack(spacing: 0) {
            // Label + value
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }

            // Bar chart
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    // Background (free = green)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.green.opacity(0.35))

                    // Used portion (yellow)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.yellow.opacity(0.8))
                        .frame(height: geo.size.height * CGFloat(usage))
                        .animation(.easeInOut(duration: 0.6), value: usage)
                }
            }
            .frame(width: barWidth, height: barHeight)
            .padding(.top, 2)
        }
    }

    private var memoryUsageRatio: Double {
        guard systemDataModel.memoryTotal > 0 else { return 0 }
        return Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal)
    }

    private func formatMemoryPercent() -> String {
        guard systemDataModel.memoryTotal > 0 else { return "0%" }
        let pct = Int(round(memoryUsageRatio * 100))
        return "\(pct)%"
    }
}

private func formatPercent(_ value: Double) -> String {
    let pct = Int(round(value * 100))
    return "\(pct)%"
}

private func formatMemoryShort(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb < 1.0 {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0fM", mb)
    }
    return String(format: "%.1fG", gb)
}

struct StatusBarView_Previews: PreviewProvider {
    static var previews: some View {
        StatusBarView()
            .environment(\.sizeCategory, .small)
    }
}
