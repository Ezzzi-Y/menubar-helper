import Foundation

@main
struct DashboardSmoke {
    static func wait(_ description: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(50)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        precondition(condition(), "Timed out: \(description)")
    }

    static func main() {
        let model = DashboardModel()
        model.refreshServices()
        wait("initial statuses") { !model.serviceRefreshing }
        guard services.allSatisfy({ model.status($0) == "已停止" }) else {
            print("Skip service smoke: a service is already running or status is unavailable")
            return
        }
        defer {
            model.operate("stop", targets: services)
            wait("cleanup") { !model.operationRunning && !model.serviceRefreshing }
        }
        model.refreshQuota()
        model.sampleMetrics()
        wait("metrics and quota") { model.metrics != nil && !model.quotaRefreshing }
        precondition(model.metrics?.memoryAvailable == true)
        precondition(model.metrics?.diskAvailable == true)
        precondition(model.quota != nil, "Quota: \(model.quotaError ?? "unavailable")")
        model.operate("run", targets: services)
        wait("start all") { !model.operationRunning && !model.serviceRefreshing }
        precondition(model.operationError == nil, model.operationError ?? "")
        precondition(services.allSatisfy { model.isRunning($0) })
        for root in [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] {
            for service in services {
                for label in ["homebrew.mxcl", "sh.brew"] {
                    precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(label).\(service.formula).plist").path), "Autostart plist unexpectedly registered")
                }
            }
        }
        model.operate("stop", targets: services)
        wait("stop all") { !model.operationRunning && !model.serviceRefreshing }
        precondition(model.operationError == nil)
        precondition(services.allSatisfy { model.status($0) == "已停止" })
        print("PASS: real metrics, live Codex quota, start/stop all, no autostart registration")
    }
}
