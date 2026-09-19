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
    /// Sort direction: `false` = descending (largest first, the default),
    /// `true` = ascending. Applies to whichever `SortField` is selected.
    @Published var sortAscending: Bool = false {
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

    /// Tapping a sort field selects it, keeping the current direction;
    /// tapping the already-selected field reverses the order.
    func sortTapped(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
        }
    }

    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        items.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortField {
            case .cpu:
                order = Self.compare(lhs.cpuUsage, rhs.cpuUsage)
            case .memory:
                order = Self.compare(lhs.memoryUsed, rhs.memoryUsed)
            case .network:
                order = Self.compare(lhs.inBytes + lhs.outBytes, rhs.inBytes + rhs.outBytes)
            }
            // Ties always fall back to name A→Z, whatever the metric direction.
            if order == .orderedSame { return lhs.name < rhs.name }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
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
