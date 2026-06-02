import Foundation
import SwiftUI

class Network {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    @ObservedObject var systemDataModel = SharedStore.systemDataModel
    @ObservedObject var globalModel = SharedStore.globalModel

    private let interval = 2

    private lazy var runner: NettopRunner = {
        let r = NettopRunner(interval: interval)
        r.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        return r
    }()

    private lazy var systemMonitor: SystemMonitor = {
        let m = SystemMonitor(interval: interval)
        m.onUpdate = { [weak self] metrics, processes in
            self?.handleSystemUpdate(metrics: metrics, processes: processes)
        }
        return m
    }()

    // Buffer for per-process CPU/Mem data, merged on next nettop frame
    private var processResources: [Int: ProcessResourceInfo] = [:]

    public func startListenNetwork() {
        runner.start()
        systemMonitor.start()
    }

    public func stopListenNetwork() {
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

        // Merge per-process CPU/Mem data
        let mergedEntities = entities.map { entity -> ProcessEntity in
            var e = entity
            if let res = processResources[e.pid] {
                e.cpuUsage = res.cpuUsage
                e.memoryUsed = res.memoryUsed
            }
            return e
        }

        // parser stores raw delta bytes; convert to bytes/sec for the status bar.
        let inRate  = totalInBytes  / interval
        let outRate = totalOutBytes / interval

        DispatchQueue.main.async {
            self.statusDataModel.update(totalInBytes: inRate, totalOutBytes: outRate)
            self.viewModel.updateData(newItems: mergedEntities)
        }
    }

    private func handleSystemUpdate(metrics: SystemMetrics, processes: [ProcessResourceInfo]) {
        var map: [Int: ProcessResourceInfo] = [:]
        for p in processes {
            map[p.pid] = p
        }
        processResources = map

        DispatchQueue.main.async {
            self.systemDataModel.update(metrics: metrics)
        }
    }

    var sleepCounter = 0
    let MAX_COUNT = 30
    func tryToMakeAppSleepDeep() {
        if !globalModel.viewShowing && sleepCounter >= MAX_COUNT {
            globalModel.isSleepDeep = true
            if globalModel.controllerHaveBeenReleased == false {
                print("into sleep deep, release controller")
                DispatchQueue.main.async {
                    AppDelegate.popover.contentViewController = nil
                }
                globalModel.controllerHaveBeenReleased = true
            }
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

    func parser(text: String) -> ProcessEntity? {
        let item = text.split(separator: ",")
        if item.count < 3 {
            return nil
        }
        // Store raw delta bytes; rate is computed once at the aggregation point.
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
