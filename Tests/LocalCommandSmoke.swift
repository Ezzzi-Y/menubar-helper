import Foundation
import Darwin

// Compile separately from the app's main.swift:
// swiftc -swift-version 5 Sources/LocalCommand.swift Tests/LocalCommandSmoke.swift -o /tmp/local-command-smoke
@main
struct LocalCommandSmoke {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func shell(_ script: String, timeout: TimeInterval = 5) -> (Int32, String) {
        LocalCommand.run(executable: "/bin/sh", arguments: ["-c", script],
                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: timeout)
    }

    static func main() {
        let success = shell("printf 'standard output\\n'; printf 'standard error\\n' >&2")
        require(success.0 == 0 && success.1.contains("standard output") && success.1.contains("standard error"),
                "Capture both stdout and stderr and preserve success status")
        let failure = shell("printf 'expected failure\\n' >&2; exit 7")
        require(failure.0 == 7 && failure.1.contains("expected failure"), "Preserve nonzero status and error output")

        let started = Date()
        let resistant = shell("trap '' TERM; printf 'PID=%s\\n' \"$$\"; exec /bin/sleep 30", timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        require(resistant.0 == 124 && resistant.1.contains("超时"), "Return a localized timeout result")
        require(elapsed < 2, "SIGTERM-resistant process cleanup must remain bounded")
        let pidLine = resistant.1.split(separator: "\n").first { $0.hasPrefix("PID=") }
        guard let pidLine = pidLine, let pid = Int32(pidLine.dropFirst(4)) else {
            require(false, "Timeout fixture did not report its PID"); return
        }
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        require(!alive, "SIGTERM-resistant direct child must not survive")

        let pipeStarted = Date()
        let heldPipe = shell("/bin/sleep 2 & printf 'CHILD=%s\\n' \"$!\"; printf 'child inherits stdout\\n'; exit 0")
        require(heldPipe.0 == 0 && heldPipe.1.contains("child inherits stdout"), "Preserve parent's result with an inherited pipe")
        require(Date().timeIntervalSince(pipeStarted) < 1,
                "Do not wait for EOF from a descendant after the direct child exits")
        let descendantLine = heldPipe.1.split(separator: "\n").first { $0.hasPrefix("CHILD=") }
        guard let descendantLine = descendantLine, let descendantPID = Int32(descendantLine.dropFirst(6)) else {
            require(false, "Inherited-pipe fixture did not report its child PID"); return
        }
        require(kill(descendantPID, 0) == 0, "The runner must not terminate descendants")

        let longOutput = shell("/usr/bin/yes x | /usr/bin/head -c 1200000")
        require(longOutput.0 == 0 && longOutput.1.utf8.count <= 1_048_576 && longOutput.1.contains("已截断"),
                "Drain large output while retaining at most 1 MiB, including diagnostics")
        print(String(format: "PASS: local command success, failure, merged output, inherited pipe, 1 MiB limit; resistant child stopped in %.2f s", elapsed))
        // The inherited-pipe fixture's own sleep is allowed to finish naturally; the runner never
        // signals descendants. This avoids leaving even a short test fixture running after return.
        let remaining = 2.1 - Date().timeIntervalSince(pipeStarted)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }
}
