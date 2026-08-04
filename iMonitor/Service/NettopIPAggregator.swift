//
//  NettopIPAggregator.swift
//  iMonitor
//
//  Aggregates nettop's connection-level output into per-remote-IP traffic
//  deltas. Runs nettop WITHOUT -P so each connection row
//  (e.g. `tcp4 10.0.0.1:port<->17.57.145.151:5223`) is emitted; we group
//  bytes_in / bytes_out by the remote peer IP and rank IPs by traffic.
//
//  Reuses NettopRunner (which handles the /usr/bin/script PTY wrapper, the
//  keep-stdin-open mitigation, frame debouncing, and first-cumulative-frame
//  dropping). Only the nettop argument list and the frame parser differ from
//  the per-process path.
//

import Foundation

final class NettopIPAggregator {
    /// One delta frame: remote IPs with their traffic for this interval.
    var onFrame: (([IpEntity]) -> Void)?

    private let interval: Int

    private lazy var runner: NettopRunner = {
        // No -P: emit connection rows (which carry the remote address) rather
        // than per-process aggregates. -x = parsable, no curses TUI.
        let args = [
            "-d",  // delta mode (per-interval, not cumulative)
            "-L", "0",  // unlimited refreshes
            "-J", "bytes_in,bytes_out",  // only the columns we need
            "-t", "external",  // external interfaces only (skip loopback)
            "-s", "\(interval)",  // sample interval (seconds)
            "-x",  // machine-readable output
        ]
        let r = NettopRunner(interval: interval, arguments: args)
        r.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        return r
    }()

    init(interval: Int) {
        self.interval = interval
    }

    func start() { runner.start() }
    func stop() { runner.stop() }

    // MARK: - Parsing

    private func handleFrame(_ lines: [String]) {
        // ip -> (inBytes, outBytes, connectionCount)
        var agg: [String: (inBytes: Int, outBytes: Int, conns: Int)] = [:]

        for line in lines {
            // Header rows only appear in the dropped first (cumulative) frame,
            // but guard defensively in case a header slips through.
            if line.contains("bytes_in") { continue }

            // Keep empty fields so column indices are stable
            // (rows look like `identifier,bytes_in,bytes_out,`).
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let identifier = String(parts[0])
            // Connection rows contain "<->"; process aggregate rows do not.
            guard let arrowRange = identifier.range(of: "<->") else { continue }

            let inBytes = Int(parts[1]) ?? 0
            let outBytes = Int(parts[2]) ?? 0

            // Remote peer endpoint is everything after "<->".
            let remote = String(identifier[arrowRange.upperBound...])
            guard let ip = remoteIP(from: remote), !ip.isEmpty else { continue }

            var entry = agg[ip] ?? (inBytes: 0, outBytes: 0, conns: 0)
            entry.inBytes += inBytes
            entry.outBytes += outBytes
            entry.conns += 1
            agg[ip] = entry
        }

        let entities = agg.map { ip, v in
            IpEntity(ip: ip, inBytes: v.inBytes, outBytes: v.outBytes, connections: v.conns)
        }
        onFrame?(entities)
    }

    /// Extract the remote IP from a nettop endpoint string such as
    /// `17.57.145.151:5223`, `[fe80::1]:443`, `*:*`, or `*.*`.
    /// Returns nil for wildcard / empty endpoints (listeners, broadcast).
    private func remoteIP(from endpoint: String) -> String? {
        let s = endpoint.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        // Bracketed IPv6: [addr]:port
        if let close = s.firstIndex(of: "]") {
            let start = s.index(after: s.startIndex)  // skip '['
            let addr = String(s[start..<close])
            return addr.contains("*") ? nil : addr
        }

        // IPv4 / wildcard: strip the trailing :port (last colon).
        if let colon = s.lastIndex(of: ":") {
            let addr = String(s[..<colon])
            if addr.isEmpty || addr.contains("*") { return nil }
            return addr
        }

        // No colon at all (e.g. `*.*`).
        return s.contains("*") ? nil : s
    }
}
