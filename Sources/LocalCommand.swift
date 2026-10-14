import Foundation
import Darwin

/// Run a local command on a background thread. Never waits indefinitely for process exit or EOF,
/// and signals only the direct child that it launched, never a process group or its descendants.
final class LocalCommand {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 45) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return (1, "无法执行命令：\(error.localizedDescription)")
        }
        // The parent retains only its read end. EOF must not depend on its own write handle.
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }

        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        let nonblocking = flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        let duration = timeout.isFinite ? max(0.1, min(timeout, 3600)) : 45
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        let outputLimit = 1_048_576
        var captured = Data()
        var truncated = false
        var timedOut = false
        var readFailed = !nonblocking
        var eof = !nonblocking
        var terminateDeadline: TimeInterval?
        var killDeadline: TimeInterval?
        var bytes = [UInt8](repeating: 0, count: 16_384)

        func capture(_ count: Int) {
            let remaining = max(0, outputLimit - captured.count)
            if count > remaining { truncated = true }
            if remaining > 0 { captured.append(contentsOf: bytes.prefix(min(count, remaining))) }
        }

        // A descendant can keep the pipe open after the command exits. Drain only bytes already
        // available, with a bound even if that descendant keeps writing, then close our own pipe.
        func drainAvailable() {
            guard nonblocking else { return }
            let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.1
            for _ in 0..<64 {
                guard ProcessInfo.processInfo.systemUptime < drainDeadline else { break }
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { capture(count) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }

        while true {
            if !process.isRunning { drainAvailable(); break }
            let now = ProcessInfo.processInfo.systemUptime
            if terminateDeadline == nil && (now >= deadline || readFailed) {
                timedOut = !readFailed
                if process.isRunning { process.terminate() }
                terminateDeadline = now + 0.5
            }
            if let end = terminateDeadline, now >= end, killDeadline == nil {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                killDeadline = now + 0.5
            }
            if let end = killDeadline, now >= end { drainAvailable(); break }
            let nextBoundary = killDeadline ?? terminateDeadline ?? deadline
            let wait = min(0.1, max(0, nextBoundary - now))
            if eof {
                _ = exited.wait(timeout: .now() + wait)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32((wait * 1000).rounded(.up)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                readFailed = true
                eof = true
                continue
            }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { capture(count) }
            else if count == 0 { eof = true }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                readFailed = true
                eof = true
            }
        }

        var notes: [String] = []
        if truncated { notes.append("命令输出过长，已截断。") }
        if readFailed { notes.append("读取命令输出失败，请稍后重试。") }
        if timedOut {
            let seconds = duration.rounded() == duration ? String(Int(duration)) : String(format: "%.1f", duration)
            notes.append("命令执行超时（\(seconds) 秒），请刷新状态后重试。")
        }
        let suffix = notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")
        var text = String(decoding: captured, as: UTF8.self)
        let textLimit = max(0, outputLimit - suffix.utf8.count)
        if text.utf8.count > textLimit {
            text = String(decoding: Array(text.utf8.prefix(textLimit)), as: UTF8.self)
            // Removing an incomplete trailing scalar can add a replacement character on decode.
            while text.utf8.count > textLimit { text.removeLast() }
        }
        let status: Int32 = timedOut ? 124 : (readFailed || process.isRunning ? 1 : process.terminationStatus)
        return (status, text + suffix)
    }
}
