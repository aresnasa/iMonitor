import Foundation
import IOKit

/// Per-process GPU time, read from the accelerator's user clients.
///
/// Every GPU client a process opens (Metal device, display, video decode…)
/// shows up as a child of an `IOAccelerator` node — on Apple Silicon an
/// `AGXDeviceUserClient` — carrying two registry properties:
///
/// * `IOUserClientCreator` — `"pid 426, WindowServer"`, the owning process.
/// * `AppUsage` — an array of per-API dictionaries with
///   `accumulatedGPUTime` (nanoseconds of GPU time, sticky for the client's
///   lifetime; the array may be empty for a client that never submitted
///   work).
///
/// A process' GPU load is the growth of its clients' pooled
/// `accumulatedGPUTime` over the elapsed interval — exactly how Activity
/// Monitor computes its per-process `% GPU` column. Deltas are keyed by the
/// client's registry entry ID (not the pid) so a client created between two
/// samples counts only from its own zero, and one that dies mid-interval
/// cannot drag a pid's total negative and fake a spike on pid reuse.
///
/// Known limits:
/// * Processes are attribute from `IOUserClientCreator`'s pid, which is the
///   client's *creating* process (a helper submitting GPU work on behalf of
///   its host is attributed to the helper, as Activity Monitor does).
/// * GPU time can legitimately exceed wall time (parallel command buffers);
///   the caller displays the raw fraction.
final class ProcessGPUSampler {

    private var lastTotalNs: [UInt64: UInt64] = [:]
    private var lastTime: TimeInterval = 0
    /// Clients whose GPU time vanished since the previous sample (destroyed
    /// between samples) are pruned once they exceed this many samples of age.
    private var vanishedSamples: [UInt64: Int] = [:]

    /// Invalidates the delta baseline: the next sample reports fractions of
    /// zero. Call once when sampling starts, so a baseline - not a burst of
    /// "everything at 100%" - is recorded.
    func resetBaseline() {
        lastTotalNs.removeAll()
        vanishedSamples.removeAll()
        lastTime = 0
    }

    /// Samples per-process GPU utilization as a 0.0-N fraction of wall time.
    func sample() -> [Int: Double] {
        let now = ProcessInfo.processInfo.systemUptime
        let clients = Self.gpuClients()

        var current: [UInt64: UInt64] = [:]
        current.reserveCapacity(clients.count)
        for client in clients {
            current[client.id] = client.gpuNs
        }

        guard lastTime > 0, now > lastTime else {
            lastTotalNs = current
            lastTime = now
            return [:]
        }

        let elapsed = now - lastTime
        var perPid: [Int: Double] = [:]
        for client in clients {
            if let previous = lastTotalNs[client.id], client.gpuNs >= previous {
                let delta = Double(client.gpuNs - previous) / 1e9
                perPid[client.pid, default: 0] += delta / elapsed
            }
        }

        // Track when a client was last seen, so entries for long-gone clients
        // (their entry ID is never reissued) are eventually dropped instead of
        // leaking for the life of the app.
        for id in lastTotalNs.keys where current[id] == nil {
            vanishedSamples[id, default: 0] += 1
        }
        for id in current.keys {
            vanishedSamples.removeValue(forKey: id)
        }
        for (id, count) in vanishedSamples where count > 10 {
            lastTotalNs.removeValue(forKey: id)
            vanishedSamples.removeValue(forKey: id)
        }

        lastTotalNs = current
        lastTime = now
        return perPid
    }

    // MARK: - IORegistry

    private struct GPUClient {
        let id: UInt64
        let pid: Int
        let gpuNs: UInt64
    }

    /// All GPU user clients across every accelerator.
    private static func gpuClients() -> [GPUClient] {
        var result: [GPUClient] = []
        let matching = IOServiceMatching("IOAccelerator")
        var acceleratorIterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &acceleratorIterator)
                == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(acceleratorIterator) }

        var accelerator = IOIteratorNext(acceleratorIterator)
        while accelerator != 0 {
            defer { IOObjectRelease(accelerator) }

            var childIterator: io_registry_entry_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &childIterator)
                == KERN_SUCCESS
            {
                var child = IOIteratorNext(childIterator)
                while child != 0 {
                    if let id = registryEntryID(of: child), let pid = creatorPid(of: child) {
                        let gpuNs = accumulatedGPUTime(of: child)
                        if gpuNs > 0 {
                            result.append(GPUClient(id: id, pid: pid, gpuNs: gpuNs))
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(childIterator)
                }
                IOObjectRelease(childIterator)
            }

            accelerator = IOIteratorNext(acceleratorIterator)
        }
        return result
    }

    /// `"pid 426, WindowServer"` -> `426`.
    private static func creatorPid(of entry: io_registry_entry_t) -> Int? {
        guard let creator = property(entry, "IOUserClientCreator") as? String,
            creator.hasPrefix("pid ")
        else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int(digits)
    }

    private static func registryEntryID(of entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    /// Pooled `accumulatedGPUTime` (nanoseconds) across the client's APIs.
    private static func accumulatedGPUTime(of entry: io_registry_entry_t) -> UInt64 {
        guard let usages = property(entry, "AppUsage") as? [Any] else { return 0 }
        var total: UInt64 = 0
        for case let usage as [String: Any] in usages {
            if let ns = usage["accumulatedGPUTime"] as? NSNumber {
                total &+= ns.uint64Value
            }
        }
        return total
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
