import Foundation

enum SortField: String, CaseIterable {
    case network = "NET"
    case cpu = "CPU"
    case memory = "MEM"

    var displayName: String { rawValue }
}

class ListViewModel: ObservableObject {

    @Published var items: [ProcessEntity] = []
    @Published var sortField: SortField = .network {
        didSet { resort() }
    }

    var globalModel = SharedStore.globalModel
    var gcCounter = 0

    public func updateData(newItems: [ProcessEntity]) {
        if shouldClearItemsForReduceSomeMemory() {
            items.removeAll()
        }

        var pid2IndexForItems = [Int: Int]()
        var pidInNewItems = Set<Int>()
        for i in 0..<items.count {
            pid2IndexForItems[items[i].pid] = i
        }

        for newItem in newItems {
            if let i = pid2IndexForItems[newItem.pid] {
                items[i].inBytes = newItem.inBytes
                items[i].outBytes = newItem.outBytes
                items[i].cpuUsage = newItem.cpuUsage
                items[i].memoryUsed = newItem.memoryUsed
            } else {
                items.append(newItem)
            }
            pidInNewItems.insert(newItem.pid)
        }

        items.removeAll { !pidInNewItems.contains($0.pid) }

        resort()
    }

    private func resort() {
        items = sort(items: items)
    }

    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        switch sortField {
        case .cpu:
            return items.sorted { lhs, rhs in
                if lhs.cpuUsage != rhs.cpuUsage { return lhs.cpuUsage > rhs.cpuUsage }
                return lhs.name < rhs.name
            }
        case .memory:
            return items.sorted { lhs, rhs in
                if lhs.memoryUsed != rhs.memoryUsed { return lhs.memoryUsed > rhs.memoryUsed }
                return lhs.name < rhs.name
            }
        case .network:
            return items.sorted { lhs, rhs in
                let lTotal = lhs.inBytes + lhs.outBytes
                let rTotal = rhs.inBytes + rhs.outBytes
                if lTotal != rTotal { return lTotal > rTotal }
                return lhs.name < rhs.name
            }
        }
    }

    public func shouldClearItemsForReduceSomeMemory() -> Bool {
        gcCounter += 1
        if !self.globalModel.viewShowing && gcCounter >= 50 {
            gcCounter = 0
            return true
        }
        return false
    }
}
