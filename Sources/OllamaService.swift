import Foundation
import Darwin

struct OllamaService {
    func isServing() -> Bool {
        let (code, _) = LocalCommand.run(executable: "/usr/bin/curl",
            arguments: ["--noproxy", "*", "-fsS", "-o", "/dev/null", "--max-time", "2",
                        "http://127.0.0.1:11434/api/tags"],
            environment: ProcessInfo.processInfo.environment, timeout: 3)
        return code == 0
    }

    func stopManualServer() -> (Int32, String) {
        let (code, output) = LocalCommand.run(executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:11434", "-sTCP:LISTEN"],
            environment: ProcessInfo.processInfo.environment, timeout: 5)
        guard code == 0, let pid = output.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }).first else {
            return (1, "无法定位 Ollama 服务进程")
        }
        let (psCode, description) = LocalCommand.run(executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "uid=", "-o", "command="],
            environment: ProcessInfo.processInfo.environment, timeout: 5)
        let parts = description.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard psCode == 0, parts.count == 2, Int(parts[0]) == Int(getuid()) else {
            return (1, "Ollama 服务进程不属于当前用户")
        }
        let command = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == "ollama serve" || command.hasSuffix("/ollama serve") else {
            return (1, "11434 端口的进程不是 Ollama 服务")
        }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { return (1, "无法停止 Ollama 服务进程") }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !isServing() { return (0, "") }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (1, "Ollama 未在 10 秒内停止")
    }
}
