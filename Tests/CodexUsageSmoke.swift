import Foundation
import Darwin

// Compile separately from the app's main.swift:
// swiftc -swift-version 5 Sources/CodexUsage.swift Tests/CodexUsageSmoke.swift -o /tmp/codex-quota-smoke
// /tmp/codex-quota-smoke [--live]
// Default checks use only fixtures; --live also reads the signed-in account's current limits.
@main
struct CodexUsageSmoke {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        try checkParsing()
        try checkTimeoutAndCleanup()
        if CommandLine.arguments.contains("--live") {
            let started = Date()
            let snapshot = try CodexUsageProvider().fetch()
            require(!snapshot.windows.isEmpty, "Live response must contain actual quota windows")
            require(snapshot.fetchedAt >= started, "Live fetch timestamp must be current")
            print("PASS: read-only live quota; plan \(snapshot.plan ?? "unknown"), \(snapshot.windows.count) windows")
            for window in snapshot.windows {
                // Only non-sensitive quota fields are printed. Credentials and RPC logs stay private.
                print("\(window.name): \(window.usedPercent)% used; reset \(window.resetsAt == nil ? "unknown" : "available")")
            }
        }
    }

    static func checkParsing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let multi: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": [
                "codex": ["planType": "plus", "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1_791_194_607],
                          "secondary": ["usedPercent": 6, "windowDurationMins": 10_080]],
                "code_review": ["limitName": "Code review", "primary": ["usedPercent": 25, "windowDurationMins": 10_080]]
            ]
        ]
        let snapshot = try CodexUsageProvider.parse(result: multi, fetchedAt: fetchedAt)
        require(snapshot.plan == "plus", "Plan must come from the actual bucket")
        require(snapshot.fetchedAt == fetchedAt, "Preserve the fetch timestamp")
        require(snapshot.windows.count == 3, "Preserve all windows from multiple metered buckets")
        require(snapshot.windows[0].usedPercent == 12, "Multi-bucket data must supersede legacy data")
        require(snapshot.windows[0].durationMinutes == 300, "Keep the server-provided duration")
        require(snapshot.windows[0].resetsAt?.timeIntervalSince1970 == 1_791_194_607,
                "Reset timestamps are Unix seconds")
        require(snapshot.windows[1].resetsAt == nil, "Unknown reset must stay unknown")
        require(snapshot.windows[2].name.contains("Code review"), "Separate bucket must retain its label")

        for unavailableMulti: Any in [NSNull(), [:] as [String: Any]] {
            let legacy = try CodexUsageProvider.parse(result: [
                "rateLimitsByLimitId": unavailableMulti,
                "rateLimits": ["primary": ["usedPercent": 40]]
            ], fetchedAt: fetchedAt)
            require(legacy.windows.count == 1 && legacy.windows[0].usedPercent == 40, "Legacy fallback must work")
            require(legacy.plan == nil && legacy.windows[0].durationMinutes == nil && legacy.windows[0].resetsAt == nil,
                    "Missing metadata must remain unavailable")
        }

        let duplicateLabels = try CodexUsageProvider.parse(result: ["rateLimitsByLimitId": [
            "bucket_one": ["limitName": "Same label", "primary": ["usedPercent": 10, "windowDurationMins": 300]],
            "bucket_two": ["limitName": "Same label", "primary": ["usedPercent": 20, "windowDurationMins": 300]]
        ]], fetchedAt: fetchedAt)
        require(Set(duplicateLabels.windows.map(\.name)).count == 2,
                "Different quota buckets must remain distinguishable when labels collide")

        for missingUsage: Any in [NSNull(), true, "20"] {
            do {
                _ = try CodexUsageProvider.parse(result: ["rateLimits": ["primary": ["usedPercent": missingUsage]]],
                                                fetchedAt: fetchedAt)
                require(false, "Missing or invalid usage must never become zero")
            } catch CodexUsageError.quotaUnavailable {}
        }
        print("PASS: quota parser; multi-bucket preference, legacy fallback, unknown metadata, bucket identity")
    }

    static func checkTimeoutAndCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devtoolbox-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hanging-codex")
        let pidFile = directory.appendingPathComponent("child.pid")
        // An executable shell fixture needs no Python. exec preserves the PID and ignored SIGTERM.
        let script = """
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > \(shellQuote(pidFile.path))
        IFS= read -r ignored
        printf '%s\\n' '{"id":1,"result":{}}'
        exec /bin/sleep 30
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        do {
            _ = try CodexUsageProvider(timeout: 1, executableURL: executable).fetch()
            require(false, "A non-responsive quota server must time out")
        } catch CodexUsageError.timedOut {}
        let elapsed = Date().timeIntervalSince(started)
        require(elapsed < 5, "Timeout and process cleanup must be bounded")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        guard let pid = Int32(pidText) else { require(false, "Invalid child PID"); return }
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) } // Keep failed test fixtures from leaving a process behind.
        require(!alive, "The timed-out child must not survive fetch()")
        print(String(format: "PASS: bounded timeout and cleanup; SIGTERM-resistant child removed in %.2f s", elapsed))
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
