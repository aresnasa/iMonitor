import Foundation

/// One reorderable resource column in the process list row. The order is
/// stored in `AppConfig.processColumnOrder`, so the layout survives relaunch.
enum ProcessColumn: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case networkDown
    case networkUp
    case gpu

    var id: String { rawValue }

    /// Row label; the network columns draw ↓ / ↑ arrows instead.
    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .gpu: return "GPU"
        case .networkDown: return "Down"
        case .networkUp: return "Up"
        }
    }
}

class ProcessColumnsModel: ObservableObject {
    /// Bound directly to Settings' row-6 binding: always written to UserDefaults
    /// and published, so the panel list re-lays out the moment a column moves.
    @Published var order: [ProcessColumn] {
        didSet { AppConfig.processColumnOrder = order.map(\.rawValue) }
    }

    init() {
        order = Self.stored()
    }

    /// The columns to draw, in order: unknown names in the stored value are
    /// dropped and any column missing from it (an older stored order, or a
    /// hand-edited value) is appended, so every resource stays reachable
    /// whatever is in there.
    private static func stored() -> [ProcessColumn] {
        var seen = Set<String>()
        var columns: [ProcessColumn] = []
        for raw in AppConfig.processColumnOrder {
            guard let column = ProcessColumn(rawValue: raw), !seen.contains(raw) else {
                continue
            }
            seen.insert(raw)
            columns.append(column)
        }
        for column in ProcessColumn.allCases where !seen.contains(column.rawValue) {
            columns.append(column)
        }
        return columns
    }

    func move(_ column: ProcessColumn, by offset: Int) {
        guard let index = order.firstIndex(of: column) else { return }
        let destination = index + offset
        guard order.indices.contains(destination) else { return }
        var next = order
        next.swapAt(index, destination)
        order = next
    }
}
