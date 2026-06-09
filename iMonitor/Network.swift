import Foundation
import SwiftUI

class Network {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    @ObservedObject var systemDataModel = SharedStore.systemDataModel
    @ObservedObject var globalModel = SharedStore.globalModel

    private var networkInterval: Int { max(AppConfig.networkInterval, 1) }
    private var systemInterval: Int { max(AppConfig.systemInterval, 1) }

    private lazy var runner: NettopRunner = {
        let r = NettopRunner(interval: networkInterval)
        r.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        return r
    }()

    private lazy var systemMonitor: SystemMonitor = {
        let m = SystemMonitor(interval: systemInterval)
        m.onUpdate = { [weak self] metrics, processes in
            self?.handleSystemUpdate(metrics: metrics, processes: processes)
        }
        return m
    }()

    // Buffer for per-process CPU/Mem data, merged on next nettop frame.
    // Accessed from both main queue (write) and nettop-runner queue (read).
    private let resourcesLock = NSLock()
    private var _processResources: [Int: ProcessResourceInfo] = [:]
    private var processResources: [Int: ProcessResourceInfo] {
        get { resourcesLock.withLock { _processResources } }
        set { resourcesLock.withLock { _processResources = newValue } }
    }

    public func startListenNetwork() {
        AppLogger.info("Starting network and system monitors")
        runner.start()
        systemMonitor.start()
    }

    public func stopListenNetwork() {
        AppLogger.info("Stopping network and system monitors")
        runner.stop()
        systemMonitor.stop()
    }

    private func handleFrame(_ lines: [String]) {
        tryToMakeAppSleepDeep()

        var totalInBytes = 0
        var totalOutBytes = 0
        let entities: [ProcessEntity] = lines.compactMap { line -> ProcessEntity? in
            guard let entity = parser(text: line) else { return nil }
            totalInBytes += entity.inBytes
            totalOutBytes += entity.outBytes
            return entity
        }

        // Snapshot processResources under lock (read once, use consistently)
        let resources = processResources

        // Merge per-process CPU/Mem data into nettop entities
        let nettopPids = Set(entities.map { $0.pid })
        let mergedEntities = entities.map { entity -> ProcessEntity in
            var e = entity
            if let res = resources[e.pid] {
                e.cpuUsage = res.cpuUsage
                e.memoryUsed = res.memoryUsed
            }
            return e
        }

        // Add system-only processes (no network activity but with CPU/Mem usage)
        let systemOnlyEntities: [ProcessEntity] = resources.compactMap { pid, res -> ProcessEntity? in
            guard !nettopPids.contains(pid) else { return nil }
            guard res.cpuUsage >= 0.001 || res.memoryUsed >= 50_000_000 else { return nil }
            return ProcessEntity(
                pid: pid,
                name: res.name,
                inBytes: 0,
                outBytes: 0,
                cpuUsage: res.cpuUsage,
                memoryUsed: res.memoryUsed
            )
        }

        let allEntities = mergedEntities + systemOnlyEntities

        // parser stores raw delta bytes; convert to bytes/sec for the status bar.
        let interval = max(networkInterval, 1)
        let inRate  = totalInBytes  / interval
        let outRate = totalOutBytes / interval

        DispatchQueue.main.async {
            self.statusDataModel.update(totalInBytes: inRate, totalOutBytes: outRate)
            // Only update list when panel is visible to save CPU
            if self.globalModel.viewShowing {
                self.viewModel.updateData(newItems: allEntities)
            }
        }
    }

    private func handleSystemUpdate(metrics: SystemMetrics, processes: [ProcessResourceInfo]) {
        var map: [Int: ProcessResourceInfo] = [:]
        map.reserveCapacity(processes.count)
        for p in processes {
            map[p.pid] = p
        }
        processResources = map

        DispatchQueue.main.async {
            self.systemDataModel.update(metrics: metrics)
        }
    }

    private let sleepLock = NSLock()
    var sleepCounter = 0
    let MAX_COUNT = 30
    func tryToMakeAppSleepDeep() {
        sleepLock.withLock {
            if !globalModel.viewShowing && sleepCounter >= MAX_COUNT {
                globalModel.isSleepDeep = true
                return
            }
            if sleepCounter >= MAX_COUNT {
                sleepCounter = 0
            }
            if !globalModel.viewShowing {
                sleepCounter += 1
            }
            globalModel.isSleepDeep = false
        }
    }

    func parser(text: String) -> ProcessEntity? {
        let item = text.split(separator: ",")
        if item.count < 3 {
            return nil
        }
        let inBytes  = Int(item[1]) ?? 0
        let outBytes = Int(item[2]) ?? 0

        let nameAndPid = item[0].split(separator: ".")
        guard nameAndPid.count >= 2 else {
            return nil
        }
        let pid = nameAndPid[nameAndPid.count - 1]
        var name = nameAndPid
        name.removeLast()

        return ProcessEntity(
            pid: Int(pid) ?? 0,
            name: name.joined(separator: "."),
            inBytes: inBytes,
            outBytes: outBytes
        )
    }
}
