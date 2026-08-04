//
//  NettopIPAggregator.swift
//  iMonitor
//
//  Aggregates nettop's connection-level output into per-remote-IP traffic
//  deltas, preserving the owning process so the UI can show
//  "App → remote IP". Runs nettop WITHOUT -P so each connection row
//  (e.g. `tcp4 10.0.0.1:port<->17.57.145.151:5223`) is emitted; nettop
//  groups connection rows under their parent process aggregate row
//  (`processname.pid`), so we track the current process as we scan.
//
//  IPv4 and IPv6 are both handled. nettop uses different port separators
//  depending on address family:
//    - IPv4 (tcp4/udp4): `addr:port`  (e.g. `17.57.145.151:5223`)
//    - IPv6 (tcp6/udp6): `addr.port`  (e.g. `2406:d440:..:c456.443`)
//  The protocol family prefix on each connection row tells us which to use.
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
        // key: "pid|ip" -> aggregated traffic for that process+IP pair
        var agg:
            [String: (
                processName: String, pid: Int, ip: String, inBytes: Int, outBytes: Int, conns: Int
            )] = [:]
        var currentProcess = ""
        var currentPid = 0

        for line in lines {
            // Header rows only appear in the dropped first (cumulative) frame,
            // but guard defensively in case a header slips through.
            if line.contains("bytes_in") { continue }

            // Keep empty fields so column indices are stable
            // (rows look like `identifier,bytes_in,bytes_out,`).
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let identifier = String(parts[0])
            let inBytes = Int(parts[1]) ?? 0
            let outBytes = Int(parts[2]) ?? 0

            if let arrowRange = identifier.range(of: "<->") {
                // --- Connection row ---
                // Belongs to the most recently seen process aggregate row.
                // If we haven't seen one yet (or it was unparseable), skip.
                guard currentPid > 0 else { continue }

                // Detect address family from the protocol prefix so we use
                // the correct port separator (':' for IPv4, '.' for IPv6).
                let isIPv6 = identifier.hasPrefix("tcp6") || identifier.hasPrefix("udp6")

                // Remote peer endpoint is everything after "<->".
                let remote = String(identifier[arrowRange.upperBound...])
                guard let ip = remoteIP(from: remote, isIPv6: isIPv6), !ip.isEmpty else { continue }

                let key = "\(currentPid)|\(ip)"
                var entry = agg[key] ?? (currentProcess, currentPid, ip, 0, 0, 0)
                entry.inBytes += inBytes
                entry.outBytes += outBytes
                entry.conns += 1
                agg[key] = entry
            } else {
                // --- Process aggregate row ---
                // Format: "processname.pid" (pid is always the part after
                // the last dot). Process names may contain spaces and dots;
                // only the trailing numeric segment is the pid.
                if let lastDot = identifier.lastIndex(of: ".") {
                    let name = String(identifier[..<lastDot])
                    let pidStr = String(identifier[identifier.index(after: lastDot)...])
                    if let pid = Int(pidStr), pid > 0, !name.isEmpty {
                        currentProcess = name
                        currentPid = pid
                    }
                }
            }
        }

        let entities = agg.map { _, v in
            IpEntity(
                processName: v.processName,
                pid: v.pid,
                ip: v.ip,
                inBytes: v.inBytes,
                outBytes: v.outBytes,
                connections: v.conns
            )
        }
        onFrame?(entities)
    }

    /// Extract the remote IP from a nettop endpoint string.
    ///
    /// nettop uses different port separators by address family:
    ///   - IPv4: `addr:port`  (e.g. `17.57.145.151:5223`, `*:*`)
    ///   - IPv6: `addr.port`  (e.g. `2406:d440:..:c456.443`, `*.5353`, `*.*`)
    ///
    /// `isIPv6` must reflect the connection row's protocol prefix
    /// (`tcp6`/`udp6` vs `tcp4`/`udp4`). Returns nil for wildcard /
    /// empty endpoints (listeners, broadcast).
    private func remoteIP(from endpoint: String, isIPv6: Bool) -> String? {
        let s = endpoint.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        if isIPv6 {
            // IPv6: strip the trailing .port (last dot).
            // e.g. "2406:d440:10d:902:3bd4:c22c:ace8:c456.443" -> addr
            //      "*.5353" -> "*" (filtered below), "*.*" -> "*" (filtered)
            if let dot = s.lastIndex(of: ".") {
                let addr = String(s[..<dot])
                if addr.isEmpty || addr.contains("*") { return nil }
                return addr
            }
            // No dot at all (unusual for IPv6).
            return s.contains("*") ? nil : s
        }

        // IPv4 / wildcard: strip the trailing :port (last colon).
        // e.g. "17.57.145.151:5223" -> addr, "*:*" -> "*" (filtered)
        if let colon = s.lastIndex(of: ":") {
            let addr = String(s[..<colon])
            if addr.isEmpty || addr.contains("*") { return nil }
            return addr
        }

        // No colon at all (e.g. `*.*` without a protocol prefix).
        return s.contains("*") ? nil : s
    }
}
