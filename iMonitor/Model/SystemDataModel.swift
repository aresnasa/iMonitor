import Foundation

class SystemDataModel: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsed: UInt64 = 0
    @Published var memoryTotal: UInt64 = 0
    @Published var gpuUsage: Double = 0.0

    public func update(metrics: SystemMetrics) {
        cpuUsage = metrics.cpuUsage
        memoryUsed = metrics.memoryUsed
        memoryTotal = metrics.memoryTotal
        gpuUsage = metrics.gpuUsage
    }
}
