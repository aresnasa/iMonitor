//
//  IpEntity.swift
//  iMonitor
//
//  Per-remote-IP traffic aggregate, populated from nettop's
//  connection-level output by NettopIPAggregator. Each entry links
//  a remote IP to the process that owns the connection, so the UI
//  can show "App → remote IP" instead of a flat IP list.
//

import Foundation

struct IpEntity: Identifiable, Equatable {
    /// Stable identity across frames: "pid|ip" — the same remote IP
    /// reached by different processes shows as separate rows.
    let id: String
    let processName: String
    let pid: Int
    let ip: String
    var inBytes: Int
    var outBytes: Int
    var connections: Int

    var totalBytes: Int { inBytes + outBytes }

    init(processName: String, pid: Int, ip: String, inBytes: Int, outBytes: Int, connections: Int) {
        self.id = "\(pid)|\(ip)"
        self.processName = processName
        self.pid = pid
        self.ip = ip
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.connections = connections
    }
}

class IPListViewModel: ObservableObject {
    @Published var items: [IpEntity] = []

    /// Each frame is a fresh per-interval delta snapshot, so replace the
    /// whole list and re-rank by total bytes (largest first), then by
    /// process name and IP for stable ordering of ties.
    func updateData(newItems: [IpEntity]) {
        items = newItems.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            if lhs.processName != rhs.processName { return lhs.processName < rhs.processName }
            return lhs.ip < rhs.ip
        }
    }

    func clear() {
        items.removeAll()
    }
}
