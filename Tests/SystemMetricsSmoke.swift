import Foundation
import Darwin

// Native macOS integration smoke test. Compile with SystemMetrics.swift only.
@main
struct SystemMetricsSmoke {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let provider = SystemMetricsProvider()
        let first = provider.sample()
        require(first.memoryAvailable, "Mach VM statistics unavailable")
        require(first.diskAvailable, "Home volume capacity unavailable")
        require(!first.cpuAvailable, "First CPU sample must require a baseline")
        require(!first.networkAvailable, "First network sample must require a baseline")

        var physicalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        require(sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0) == 0,
                "Unable to independently read physical RAM")
        require(first.memoryTotal == physicalMemory, "Physical RAM differs from hw.memsize")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey])
        require(first.diskTotal == UInt64(values?.volumeTotalCapacity ?? 0),
                "Disk capacity differs from the home volume")

        var last = first
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = provider.sample()
            require(current.memoryAvailable && current.diskAvailable,
                    "A capacity source became unavailable")
            require(current.memoryUsed > 0 && current.memoryUsed <= current.memoryTotal,
                    "Invalid physical memory usage")
            require(current.diskUsed <= current.diskTotal && current.diskTotal > 0,
                    "Invalid volume capacity usage")
            require(current.cpuAvailable && current.cpuPercent.isFinite &&
                    (0...100).contains(current.cpuPercent), "Invalid interval CPU load")
            require(current.networkAvailable && current.downloadBytesPerSecond.isFinite &&
                    current.uploadBytesPerSecond.isFinite && current.downloadBytesPerSecond >= 0 &&
                    current.uploadBytesPerSecond >= 0, "Invalid physical network transfer rate")
            require(["正常", "偏高", "紧张", "未知"].contains(current.memoryPressure),
                    "Invalid memory pressure label")
            require(current.sampledAt > last.sampledAt, "Sample timestamps failed to advance")
            last = current
        }
        print("PASS: native metrics; first-sample baselines and 3 live intervals")
        print(String(format: "RAM %.2f / %.2f GiB (%@); disk %.2f / %.2f GB; CPU %.1f%%; network ↓%.0f ↑%.0f B/s",
                     Double(last.memoryUsed) / 1_073_741_824,
                     Double(last.memoryTotal) / 1_073_741_824, last.memoryPressure,
                     Double(last.diskUsed) / 1_000_000_000, Double(last.diskTotal) / 1_000_000_000,
                     last.cpuPercent, last.downloadBytesPerSecond, last.uploadBytesPerSecond))
    }
}
