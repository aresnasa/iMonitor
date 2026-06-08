import Foundation
import IOKit
import IOKit.graphics

final class SystemMonitor {
    var onUpdate: ((SystemMetrics, [ProcessResourceInfo]) -> Void)?

    private let interval: Int
    private let queue = DispatchQueue(label: "system-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?

    // CPU delta tracking: flat array [user0,sys0,idle0,nice0, user1,sys1,idle1,nice1, ...]
    private var prevCpuTicks: [UInt64] = []
    private var numCPUCores: Int = 0

    // Per-process CPU delta tracking: pid -> (total_ns, timestamp)
    private var prevProcessCpu: [Int: (totalNs: UInt64, time: TimeInterval)] = [:]

    init(interval: Int) {
        self.interval = interval
    }

    func start() {
        // Take initial samples for baseline
        _ = sampleCPU()
        _ = sampleProcessCpu()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let cpu = sampleCPU()
        let (memUsed, memTotal) = sampleMemory()
        let gpu = sampleGPU()
        let processes = sampleProcessCpu()

        let metrics = SystemMetrics(
            cpuUsage: cpu,
            memoryUsed: memUsed,
            memoryTotal: memTotal,
            gpuUsage: gpu
        )

        DispatchQueue.main.async {
            self.onUpdate?(metrics, processes)
        }
    }

    // MARK: - CPU (delta between two samples)

    private func sampleCPU() -> Double {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(UInt(numCPUInfo) * UInt(MemoryLayout<Int32>.size))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let cores = Int(numCPU)
        numCPUCores = cores

        // Collect current ticks
        var currentTicks: [UInt64] = []
        currentTicks.reserveCapacity(cores * 4)
        for i in 0..<cores {
            let base = i * Int(CPU_STATE_MAX)
            currentTicks.append(UInt64(info[base + Int(CPU_STATE_USER)]))
            currentTicks.append(UInt64(info[base + Int(CPU_STATE_SYSTEM)]))
            currentTicks.append(UInt64(info[base + Int(CPU_STATE_IDLE)]))
            currentTicks.append(UInt64(info[base + Int(CPU_STATE_NICE)]))
        }

        // Compute delta from previous
        var usage: Double = 0
        if prevCpuTicks.count == currentTicks.count {
            var dUser: UInt64 = 0
            var dSystem: UInt64 = 0
            var dIdle: UInt64 = 0
            var dNice: UInt64 = 0

            for i in 0..<cores {
                let base = i * 4
                dUser   += currentTicks[base]     - prevCpuTicks[base]
                dSystem += currentTicks[base + 1] - prevCpuTicks[base + 1]
                dIdle   += currentTicks[base + 2] - prevCpuTicks[base + 2]
                dNice   += currentTicks[base + 3] - prevCpuTicks[base + 3]
            }

            let dActive = dUser + dSystem + dNice
            let dTotal = dActive + dIdle
            if dTotal > 0 {
                usage = Double(dActive) / Double(dTotal)
            }
        }

        prevCpuTicks = currentTicks
        return usage
    }

    // MARK: - Memory

    private func sampleMemory() -> (used: UInt64, total: UInt64) {
        var totalPhys: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalPhys, &size, nil, 0)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, totalPhys) }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(vmStats.active_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        let used = active + wired + compressed

        return (used, totalPhys)
    }

    // MARK: - GPU

    private func sampleGPU() -> Double {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOGPUDevice")
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }

        var maxUtilization: Double = 0
        var instance = IOIteratorNext(iter)
        while instance != 0 {
            defer { IOObjectRelease(instance) }

            if let stats = IORegistryEntryCreateCFProperty(instance, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let utilization = stats["Device Utilization %"] as? Int {
                let u = Double(utilization) / 100.0
                if u > maxUtilization { maxUtilization = u }
            }
            instance = IOIteratorNext(iter)
        }

        return maxUtilization
    }

    // MARK: - Per-Process CPU & Memory (delta-based CPU%)

    private func sampleProcessCpu() -> [ProcessResourceInfo] {
        let bufSize = 4096
        var pids = [pid_t](repeating: 0, count: bufSize)
        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bufSize * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }

        let count = Int(result) / MemoryLayout<pid_t>.size
        let now = ProcessInfo.processInfo.systemUptime
        var results: [ProcessResourceInfo] = []
        var currentCpu: [Int: (totalNs: UInt64, time: TimeInterval)] = [:]

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_taskinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard infoSize > 0 else { continue }

            let totalNs = UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
            currentCpu[Int(pid)] = (totalNs, now)

            // Compute delta CPU% from previous sample
            var cpuPercent: Double = 0
            if let prev = prevProcessCpu[Int(pid)] {
                if totalNs >= prev.totalNs {
                    let deltaNs = Double(totalNs - prev.totalNs)
                    let deltaTime = now - prev.time
                    if deltaTime > 0 {
                        cpuPercent = (deltaNs / 1e9) / deltaTime
                    }
                }
            }

            results.append(ProcessResourceInfo(
                pid: Int(pid),
                name: getProcessName(pid: pid),
                cpuUsage: cpuPercent,
                memoryUsed: UInt64(taskInfo.pti_resident_size)
            ))
        }

        prevProcessCpu = currentCpu
        return results
    }

    private func getProcessName(pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if len > 0 {
            let path = String(cString: pathBuffer)
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "pid.\(pid)"
    }
}

struct SystemMetrics {
    let cpuUsage: Double       // 0.0 - 1.0
    let memoryUsed: UInt64     // bytes
    let memoryTotal: UInt64    // bytes
    let gpuUsage: Double       // 0.0 - 1.0
}

struct ProcessResourceInfo {
    let pid: Int
    let name: String           // executable basename
    let cpuUsage: Double       // 0.0 - N.0 (can exceed 1.0 for multi-thread)
    let memoryUsed: UInt64     // resident size in bytes
}
