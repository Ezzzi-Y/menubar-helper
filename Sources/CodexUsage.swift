import Foundation
import CoreFoundation
import Darwin

struct CodexQuotaWindow {
    /// Includes both the metered bucket and its quota window so separate buckets stay distinct.
    let name: String
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
}

struct CodexQuotaSnapshot {
    let plan: String?
    let windows: [CodexQuotaWindow]
    let fetchedAt: Date
}

enum CodexUsageError: LocalizedError {
    case executableMissing
    case launchFailed
    case timedOut
    case connectionClosed
    case invalidResponse
    case signInRequired
    case upgradeRequired
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "未找到 Codex。请先安装 Codex 或 ChatGPT 桌面应用。"
        case .launchFailed: return "无法启动 Codex 额度读取服务。"
        case .timedOut: return "Codex 额度读取超时，请稍后刷新。"
        case .connectionClosed: return "Codex 额度读取服务已断开，请稍后刷新。"
        case .invalidResponse: return "Codex 返回了无法识别的额度数据。"
        case .signInRequired: return "请先在 Codex 中登录 ChatGPT 账号，再刷新额度。"
        case .upgradeRequired: return "当前 Codex 版本不支持额度读取，请更新后重试。"
        case .quotaUnavailable: return "暂时无法获取 Codex 额度，请检查网络后刷新。"
        }
    }
}

/// Uses only the documented, read-only account/rateLimits/read RPC. The child handles its own
/// existing local credentials; this app never opens credential files or receives auth tokens.
/// Call fetch() on a background queue. No thread, turn, login, or reset RPC is sent.
final class CodexUsageProvider {
    private let timeout: TimeInterval
    private let executableOverride: URL?

    init(timeout: TimeInterval = 15, executableURL: URL? = nil) {
        self.timeout = min(60, max(1, timeout))
        executableOverride = executableURL
    }

    func fetch() throws -> CodexQuotaSnapshot {
        guard let executable = executableOverride ?? Self.findExecutable() else { throw CodexUsageError.executableMissing }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        // Avoid unbounded stderr pipes and never display server logs that could contain auth data.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], fallbackPath].compactMap { $0 }.joined(separator: ":")
        environment["RUST_LOG"] = "error"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        do { try process.run() } catch { throw CodexUsageError.launchFailed }
        // Only retain the parent ends, so EOF / a child exit can always be observed correctly.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            // EOF requests a graceful shutdown. Escalate only this child if it does not exit.
            try? input.fileHandleForWriting.close()
            if exited.wait(timeout: .now() + 0.75) == .timedOut {
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + 0.5) == .timedOut {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 0.5)
                }
            }
            try? output.fileHandleForReading.close()
        }

        let connection = CodexQuotaConnection(input: input.fileHandleForWriting,
                                              output: output.fileHandleForReading,
                                              deadline: ProcessInfo.processInfo.systemUptime + timeout)
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "dev_toolbox", "title": "Dev Toolbox", "version": "0.2.0"]
        ])
        try connection.send(["method": "initialized", "params": [:] as [String: Any]])
        let result = try connection.request(id: 2, method: "account/rateLimits/read", params: nil)
        return try Self.parse(result: result, fetchedAt: Date())
    }

    /// Pure parsing also makes legacy and multi-bucket payloads verifiable without network access.
    static func parse(result: [String: Any], fetchedAt: Date) throws -> CodexQuotaSnapshot {
        let buckets: [(String, [String: Any])]
        if let multiple = result["rateLimitsByLimitId"] as? [String: Any], !multiple.isEmpty {
            buckets = multiple.keys.sorted { left, right in
                if left == "codex" { return right != "codex" }
                if right == "codex" { return false }
                return left.localizedStandardCompare(right) == .orderedAscending
            }.compactMap { key in (multiple[key] as? [String: Any]).map { (key, $0) } }
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            buckets = [(string(legacy["limitId"]) ?? "codex", legacy)]
        } else {
            throw CodexUsageError.invalidResponse
        }

        var windows: [CodexQuotaWindow] = []
        var plan: String?
        let bucketNames = buckets.map { key, bucket in
            string(bucket["limitName"]) ?? (key == "codex" ? "Codex" : key)
        }
        for (index, entry) in buckets.enumerated() {
            let (key, bucket) = entry
            if plan == nil { plan = string(bucket["planType"]) }
            var bucketName = bucketNames[index]
            if bucketNames.filter({ $0 == bucketName }).count > 1 { bucketName += " (\(key))" }
            for field in ["primary", "secondary"] {
                guard let window = bucket[field] as? [String: Any],
                      let used = number(window["usedPercent"]), used.isFinite, used >= 0 else { continue }
                let duration = number(window["windowDurationMins"]).flatMap { value -> Int? in
                    guard value.isFinite, value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
                    return Int(value)
                }
                let reset = number(window["resetsAt"]).flatMap { value -> Date? in
                    guard value.isFinite, value > 0 else { return nil }
                    return Date(timeIntervalSince1970: value)
                }
                let windowName = duration.map(windowLabel) ?? (field == "primary" ? "主窗口" : "次窗口")
                windows.append(CodexQuotaWindow(name: "\(bucketName) · \(windowName)",
                                               usedPercent: used, durationMinutes: duration, resetsAt: reset))
            }
        }
        // Missing windows are unavailable, never interpreted as zero usage or unlimited quota.
        guard !windows.isEmpty else { throw CodexUsageError.quotaUnavailable }
        return CodexQuotaSnapshot(plan: plan, windows: windows, fetchedAt: fetchedAt)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func windowLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天窗口" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时窗口" }
        return "\(minutes) 分钟窗口"
    }

    private static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundleRoots = ["/Applications", "\(home)/Applications"]
        var candidates: [String] = []
        for root in bundleRoots {
            candidates += [
                "\(root)/Codex.app/Contents/Resources/codex",
                "\(root)/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "\(root)/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex").path
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}

private final class CodexQuotaConnection {
    private let input: FileHandle
    private let output: FileHandle
    private let deadline: TimeInterval
    private var buffer = Data()

    init(input: FileHandle, output: FileHandle, deadline: TimeInterval) {
        self.input = input
        self.output = output
        self.deadline = deadline
    }

    func send(_ message: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw CodexUsageError.invalidResponse
        }
        do {
            try input.write(contentsOf: data + Data([0x0A]))
        } catch { throw CodexUsageError.connectionClosed }
    }

    func request(id: Int, method: String, params: [String: Any]?) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params = params { message["params"] = params }
        try send(message)
        while true {
            let line = try nextLine()
            guard let response = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            // Notifications are unrelated to this request. This client provides no auth tokens.
            guard (response["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = response["error"] as? [String: Any] {
                throw Self.safeError(error)
            }
            guard let result = response["result"] as? [String: Any] else {
                throw CodexUsageError.invalidResponse
            }
            return result
        }
    }

    private func nextLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < 1_048_576 else { throw CodexUsageError.invalidResponse }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexUsageError.timedOut }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready == 0 { throw CodexUsageError.timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CodexUsageError.connectionClosed
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CodexUsageError.connectionClosed
            }
            guard count > 0 else { throw CodexUsageError.connectionClosed }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private static func safeError(_ error: [String: Any]) -> CodexUsageError {
        // Classify the remote message, but avoid displaying raw transport / authentication logs.
        let message = (error["message"] as? String ?? "").lowercased()
        if ["unauthorized", "not logged", "not authenticated", "login", "sign in", "authentication", "chatgpt", "401"].contains(where: message.contains) {
            return .signInRequired
        }
        if (error["code"] as? NSNumber)?.intValue == -32601 || message.contains("unknown method") {
            return .upgradeRequired
        }
        return .quotaUnavailable
    }
}
