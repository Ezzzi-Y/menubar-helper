import Foundation

enum DockerStatus {
    case unavailable
    case checking
    case stopped
    case starting
    case running
    case stopping
    case paused
    case error

    var label: String {
        switch self {
        case .unavailable: return "未安装"
        case .checking: return "检查中"
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .paused: return "已暂停"
        case .error: return "状态异常"
        }
    }
}

struct DockerDesktop {
    private let executable: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".docker/bin/docker").path,
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.appendingPathComponent("Applications/Docker.app/Contents/Resources/bin/docker").path
        ]
        executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func status() -> (DockerStatus, String?) {
        guard executable != nil else { return (.unavailable, nil) }
        let (engineCode, _) = run(["info", "--format", "{{.ServerVersion}}"], timeout: 5)
        if engineCode == 0 { return (.running, nil) }
        let (code, output) = run(["desktop", "status", "--format", "json"], timeout: 25)
        if code != 0 && (output.contains("Could not retrieve status") || output.contains("Is Docker Desktop running?")) {
            return (.stopped, nil)
        }
        guard code == 0, let data = output.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = result["Status"] as? String else {
            return (.error, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch value.lowercased() {
        case "running": return (.starting, nil)
        case "stopped": return (.stopped, nil)
        case "starting": return (.starting, nil)
        case "stopping": return (.stopping, nil)
        case "paused": return (.paused, nil)
        default: return (.error, "Docker Desktop 状态：\(value)")
        }
    }

    func operate(_ action: String) -> (Int32, String) {
        guard action == "start" || action == "stop" else { return (1, "未知操作") }
        guard executable != nil else { return (1, "未找到 Docker Desktop") }
        return run(["desktop", action, "--timeout", "90"], timeout: 100)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) -> (Int32, String) {
        guard let executable else { return (1, "未找到 Docker Desktop") }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin").path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return LocalCommand.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}
