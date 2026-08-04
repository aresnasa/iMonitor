//
//  IpEntity.swift
//  iMonitor
//
//  Per-remote-IP traffic aggregate, populated from nettop's
//  connection-level output by NettopIPAggregator.
//

import Foundation

struct IpEntity: Identifiable, Equatable {
    /// The remote IP itself — stable identity across frames for smooth list updates.
    let id: String
    let ip: String
    var inBytes: Int
    var outBytes: Int
    var connections: Int

    var totalBytes: Int { inBytes + outBytes }

    init(ip: String, inBytes: Int, outBytes: Int, connections: Int) {
        self.id = ip
        self.ip = ip
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.connections = connections
    }
}

class IPListViewModel: ObservableObject {
    @Published var items: [IpEntity] = []

    /// Each frame is a fresh per-interval delta snapshot, so replace the
    /// whole list and re-rank by total bytes (largest first).
    func updateData(newItems: [IpEntity]) {
        items = newItems.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.ip < rhs.ip
        }
    }

    func clear() {
        items.removeAll()
    }
}
