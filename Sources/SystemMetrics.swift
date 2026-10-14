import Foundation
import Darwin

struct SystemSnapshot {
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let memoryPressure: String
    let diskUsed: UInt64
    let diskTotal: UInt64
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let cpuPercent: Double
    let sampledAt: Date

    // Values with an unavailable flag are placeholders and must be displayed as “—”.
    let memoryAvailable: Bool
    let diskAvailable: Bool
    let networkAvailable: Bool
    let cpuAvailable: Bool
}

/// Sample on a single background queue. No commands, subprocesses or network requests.
final class SystemMetricsProvider {
    private struct NetworkCounter {
        let received: UInt64
        let sent: UInt64
    }

    private let hostPort = mach_host_self()
    private var previousCPUTicks: [UInt32]?
    private var previousCPUTime: UInt64?
    private var previousNetworkCounters: [UInt16: NetworkCounter]?
    private var previousNetworkTime: UInt64?
    private var cachedDisk: (used: UInt64, total: UInt64)?
    private var lastDiskTime: UInt64?

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    func sample() -> SystemSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let memory = sampleMemory()
        let disk = sampleDisk(now: now)
        let cpu = sampleCPU(now: now)
        let network = sampleNetwork(now: now)
        return SystemSnapshot(
            memoryUsed: memory?.used ?? 0,
            memoryTotal: memory?.total ?? 0,
            memoryPressure: sampleMemoryPressure(),
            diskUsed: disk?.used ?? 0,
            diskTotal: disk?.total ?? 0,
            downloadBytesPerSecond: network?.download ?? 0,
            uploadBytesPerSecond: network?.upload ?? 0,
            cpuPercent: cpu ?? 0,
            sampledAt: Date(),
            memoryAvailable: memory != nil,
            diskAvailable: disk != nil,
            networkAvailable: network != nil,
            cpuAvailable: cpu != nil
        )
    }

    private func sampleMemory() -> (used: UInt64, total: UInt64)? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        // This is HOST_VM_INFO64_REV1_COUNT; its offsetof macro is not imported by Swift.
        let requiredCount = MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapped_count)
            .map { mach_msg_type_number_t($0 / MemoryLayout<integer_t>.size) }
        guard result == KERN_SUCCESS,
              let minimumCount = requiredCount, count >= minimumCount,
              host_page_size(hostPort, &pageSize) == KERN_SUCCESS,
              pageSize > 0 else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }

        // Activity Monitor-style physical usage: anonymous app pages, wired RAM,
        // and the actual pages occupied by the compressor. File-backed cache,
        // speculative pages and volatile purgeable pages are reusable, not used.
        // Inactive anonymous pages remain app memory until reclaimed or compressed;
        // subtracting all inactive pages would undercount the working set.
        // XNU: osfmk/kern/host.c and osfmk/mach/vm_statistics.h.
        let anonymous = UInt64(statistics.internal_page_count)
        let purgeable = min(anonymous, UInt64(statistics.purgeable_count))
        let pages = anonymous - purgeable + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        return (min(total, pages * UInt64(pageSize)), total)
    }

    private func sampleMemoryPressure() -> String {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return "未知" }
        // The sysctl returns dispatch event flags, not XNU's internal pressure enum.
        // See bsd/kern/kern_memorystatus_notify.c in Apple's XNU source.
        switch level {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue): return "正常"
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue): return "偏高"
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue): return "紧张"
        default: return "未知"
        }
    }

    private func sampleDisk(now: UInt64) -> (used: UInt64, total: UInt64)? {
        // Volume-capacity APIs can do more work than VM/interface counters. Cache
        // for 30 seconds, recreating the URL to avoid stale NSURL resource values.
        if let last = lastDiskTime, now >= last, now - last < 30_000_000_000 {
            return cachedDisk
        }
        lastDiskTime = now
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = URL(fileURLWithPath: home.path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]), let rawTotal = values.volumeTotalCapacity, rawTotal > 0 else {
            cachedDisk = nil
            return nil
        }
        let available: Int64?
        if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
            available = important
        } else if let immediate = values.volumeAvailableCapacity, immediate >= 0 {
            available = Int64(immediate)
        } else {
            available = nil
        }
        guard let rawAvailable = available else {
            cachedDisk = nil
            return nil
        }
        let total = UInt64(rawTotal)
        // Home resolves to the writable Data volume on APFS. Capacity represents
        // its shared container; important-usage availability includes reclaimable
        // caches/snapshots. It is not just the sealed system volume mounted at /.
        cachedDisk = (total - min(total, UInt64(rawAvailable)), total)
        return cachedDisk
    }

    private func sampleCPU(now: UInt64) -> Double? {
        var statistics = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            previousCPUTicks = nil
            previousCPUTime = nil
            return nil
        }
        let tuple = statistics.cpu_ticks
        let ticks = [tuple.0, tuple.1, tuple.2, tuple.3]
        defer {
            previousCPUTicks = ticks
            previousCPUTime = now
        }
        // Reopening after a long pause starts a fresh interval, just like network
        // sampling. The paused interval's average is not a current CPU reading.
        guard let previous = previousCPUTicks,
              let lastTime = previousCPUTime, now > lastTime,
              now - lastTime <= 10_000_000_000 else { return nil }
        // Kernel counters are UInt32. Wrapping subtraction also handles their
        // natural rollover. Aggregate ticks normalize all cores to a 0...100% load.
        let deltas = zip(ticks, previous).map { UInt64($0 &- $1) }
        let total = deltas.reduce(UInt64(0), +)
        guard total > 0 else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)]
        return 100 * Double(total - idle) / Double(total)
    }

    private func sampleNetwork(now: UInt64) -> (download: Double, upload: Double)? {
        guard let counters = readNetworkCounters() else {
            previousNetworkCounters = nil
            previousNetworkTime = nil
            return nil
        }
        defer {
            previousNetworkCounters = counters
            previousNetworkTime = now
        }
        guard let previous = previousNetworkCounters,
              let lastTime = previousNetworkTime, now > lastTime else { return nil }
        let elapsed = Double(now - lastTime) / 1_000_000_000
        // After a suspended UI / wake, prime a fresh baseline rather than report
        // an old interval's average as the current transfer rate.
        guard elapsed <= 10 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (index, current) in counters {
            // New interfaces and reset counters need two successful samples.
            guard let old = previous[index], current.received >= old.received,
                  current.sent >= old.sent else { return nil }
            received += current.received - old.received
            sent += current.sent - old.sent
        }
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }

    private func readNetworkCounters() -> [UInt16: NetworkCounter]? {
        guard let eligible = physicalInterfaceIndices() else { return nil }
        // NET_RT_IFLIST2 provides 64-bit counters. getifaddrs' if_data uses
        // 32-bit byte counters, which roll over quickly on modern networks.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<2 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            if size == 0 { return [:] }
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                // The interface list can grow between the size and data reads.
                if errno == ENOMEM { continue }
                return nil
            }
            var counters: [UInt16: NetworkCounter] = [:]
            var offset = 0
            while offset + 4 <= size {
                var length: UInt16 = 0
                withUnsafeMutableBytes(of: &length) { destination in
                    buffer.withUnsafeBytes { source in
                        destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + 2)]))
                    }
                }
                let messageLength = Int(length)
                guard messageLength >= 4, offset + messageLength <= size else { return nil }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2),
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    var header = if_msghdr2()
                    withUnsafeMutableBytes(of: &header) { destination in
                        buffer.withUnsafeBytes { source in
                            destination.copyBytes(from: UnsafeRawBufferPointer(rebasing:
                                source[offset..<(offset + MemoryLayout<if_msghdr2>.size)]))
                        }
                    }
                    if eligible.contains(header.ifm_index),
                       (header.ifm_flags & IFF_UP) != 0,
                       (header.ifm_flags & IFF_RUNNING) != 0 {
                        counters[header.ifm_index] = NetworkCounter(
                            received: header.ifm_data.ifi_ibytes, sent: header.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
            return counters
        }
        return nil
    }

    private func physicalInterfaceIndices() -> Set<UInt16>? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var indices = Set<UInt16>()
        var cursor = addresses
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, let namePointer = entry.ifa_name,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_RUNNING)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: namePointer)
            // macOS Wi-Fi, wired Ethernet, USB and Thunderbolt adapters use enN.
            // Exclude lo, bridge, awdl, llw, utun and tap to avoid counting local
            // traffic and VPN packets twice. This measures physical transport
            // bytes, including LAN traffic and protocol/tunnel overhead.
            guard name.hasPrefix("en"), !name.dropFirst(2).isEmpty,
                  name.dropFirst(2).allSatisfy({ $0.isNumber }) else { continue }
            let index = if_nametoindex(namePointer)
            if let value = UInt16(exactly: index), value > 0 { indices.insert(value) }
        }
        return indices
    }
}
