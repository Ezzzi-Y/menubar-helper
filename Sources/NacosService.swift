import Foundation
import Darwin

enum NacosStatus {
    case unavailable
    case checking
    case stopped
    case starting
    case running
    case stopping
    case error

    var label: String {
        switch self {
        case .unavailable: return "未安装"
        case .checking: return "检查中"
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .error: return "状态异常"
        }
    }
}

struct NacosService {
    private let label = "local.pc2mac.nacos"
    private var agent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(label)" }

    private func launchctl(_ arguments: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        LocalCommand.run(executable: "/bin/launchctl", arguments: arguments,
                         environment: ProcessInfo.processInfo.environment, timeout: timeout)
    }

    private func processID(from output: String) -> Int32? {
        output.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }
            .flatMap { Int32($0.dropFirst(6)) }
    }

    private func waitForExit(_ pid: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private func waitForConsole() -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let (code, _) = LocalCommand.run(
                executable: "/usr/bin/curl",
                arguments: ["--noproxy", "*", "-fsS", "-o", "/dev/null", "--max-time", "2",
                            "http://127.0.0.1:8080/next/"],
                environment: ProcessInfo.processInfo.environment, timeout: 3)
            if code == 0 && status() == .running { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func status() -> NacosStatus {
        guard FileManager.default.fileExists(atPath: agent.path) else { return .unavailable }

        let (code, output) = launchctl(["print", target], timeout: 5)
        guard code == 0 else { return code == 124 ? .error : .stopped }
        let states = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if states.contains("state = running") { return .running }
        if states.contains("state = xpcproxy") { return .starting }
        return states.contains(where: { $0.hasPrefix("state = ") }) ? .stopped : .error
    }

    func operate(_ action: String) -> (Int32, String) {
        guard FileManager.default.fileExists(atPath: agent.path) else { return (1, "未找到 Nacos 服务配置") }
        switch action {
        case "start":
            let (printCode, _) = launchctl(["print", target], timeout: 5)
            if printCode != 0 {
                let result = launchctl(["bootstrap", domain, agent.path])
                guard result.0 == 0 else { return result }
            }
            let result = launchctl(["kickstart", target])
            guard result.0 == 0 else { return result }
            return waitForConsole() ? (0, "") : (1, "Nacos 启动超时，请检查服务日志")
        case "stop":
            let (printCode, output) = launchctl(["print", target], timeout: 5)
            guard printCode == 0 else { return (0, "") }
            let result = launchctl(["bootout", target])
            guard result.0 == 0 else { return result }
            guard let pid = processID(from: output) else { return (0, "") }
            return waitForExit(pid) ? (0, "") : (1, "Nacos 停止超时，请稍后刷新状态")
        default:
            return (1, "未知操作")
        }
    }
}
