import Cocoa
import SwiftUI

struct Service: Identifiable {
    let name: String
    let formula: String
    let symbol: String
    let detail: String
    var id: String { formula }
}

let services = [
    Service(name: "MySQL 8.4", formula: "mysql@8.4", symbol: "cylinder.split.1x2", detail: "本机数据库 · 3306"),
    Service(name: "Redis", formula: "redis", symbol: "square.stack.3d.up", detail: "本机缓存 · 6379")
]

final class DashboardModel: ObservableObject {
    @Published var states: [String: String] = [:]
    @Published var serviceRefreshing = false
    @Published var operationRunning = false
    @Published var operationMessage: String?
    @Published var operationError: String?
    @Published var metrics: SystemSnapshot?
    @Published var cpuHistory: [Double] = []
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
    @Published var quota: CodexQuotaSnapshot?
    @Published var quotaRefreshing = false
    @Published var quotaError: String?
    @Published var now = Date()
    private let metricsProvider = SystemMetricsProvider()
    private let quotaProvider = CodexUsageProvider()
    private let metricsQueue = DispatchQueue(label: "local.devtoolbox.metrics", qos: .utility)
    private var metricsSampling = false
    private var visible = false
    private var timer: Timer?
    private var lastServiceRefresh = Date.distantPast
    private var lastQuotaAttempt = Date.distantPast
    private let brew = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
        ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"

    func start() {
        refreshServices()
        refreshQuota()
        sampleMetrics()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.visible else { return }
            self.now = Date()
            self.sampleMetrics()
            if Date().timeIntervalSince(self.lastServiceRefresh) >= 15 { self.refreshServices() }
            if Date().timeIntervalSince(self.lastQuotaAttempt) >= 300 { self.refreshQuota() }
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value {
            now = Date()
            if let previous = metrics, now.timeIntervalSince(previous.sampledAt) > 10 {
                cpuHistory.removeAll()
                downloadHistory.removeAll()
                uploadHistory.removeAll()
            }
            sampleMetrics()
            refreshServices()
            if Date().timeIntervalSince(lastQuotaAttempt) >= 300 { refreshQuota() }
        }
    }

    func refreshAll() { refreshServices(); refreshQuota(); sampleMetrics() }

    func sampleMetrics() {
        guard !metricsSampling else { return }
        metricsSampling = true
        metricsQueue.async {
            let snapshot = self.metricsProvider.sample()
            DispatchQueue.main.async {
                self.metricsSampling = false
                self.metrics = snapshot
                if snapshot.cpuAvailable { self.append(snapshot.cpuPercent, to: &self.cpuHistory) }
                if snapshot.networkAvailable {
                    self.append(snapshot.downloadBytesPerSecond, to: &self.downloadHistory)
                    self.append(snapshot.uploadBytesPerSecond, to: &self.uploadHistory)
                }
            }
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 45 { history.removeFirst(history.count - 45) }
    }

    private func command(_ arguments: [String]) -> (Int32, String) {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return LocalCommand.run(executable: brew, arguments: arguments, environment: environment)
    }

    func refreshServices() {
        guard !serviceRefreshing, !operationRunning else { return }
        serviceRefreshing = true
        lastServiceRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            let (code, output) = self.command(["services", "list", "--json"])
            var updated: [String: String] = [:]
            if code == 0, let data = output.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for row in rows {
                    guard let name = row["name"] as? String else { continue }
                    updated[name] = row["status"] as? String ?? "unknown"
                }
            }
            DispatchQueue.main.async {
                self.states = updated
                self.serviceRefreshing = false
            }
        }
    }

    func refreshQuota() {
        guard !quotaRefreshing else { return }
        quotaRefreshing = true
        lastQuotaAttempt = Date()
        DispatchQueue.global(qos: .utility).async {
            do {
                let snapshot = try self.quotaProvider.fetch()
                DispatchQueue.main.async {
                    self.quota = snapshot
                    self.quotaError = nil
                    self.quotaRefreshing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.quotaError = error.localizedDescription
                    self.quotaRefreshing = false
                }
            }
        }
    }

    func operate(_ verb: String, targets: [Service]) {
        guard !operationRunning, !serviceRefreshing else { return }
        operationRunning = true
        operationError = nil
        operationMessage = verb == "run" ? "正在启动服务…" : "正在停止服务…"
        DispatchQueue.global(qos: .utility).async {
            var failures: [String] = []
            for service in targets {
                let (code, output) = self.command(["services", verb, service.formula])
                if code != 0 { failures.append("\(service.name)：\n\(output)") }
            }
            DispatchQueue.main.async {
                self.operationRunning = false
                self.operationError = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
                self.operationMessage = failures.isEmpty ? (verb == "run" ? "服务已启动" : "服务已停止") : "操作失败"
                self.refreshServices()
            }
        }
    }

    func isRunning(_ service: Service) -> Bool { states[service.formula] == "started" }
    func status(_ service: Service) -> String {
        switch states[service.formula] {
        case "started": return "运行中"
        case "none", "stopped": return "已停止"
        case nil: return serviceRefreshing ? "检查中" : "状态未知"
        default: return "服务异常"
        }
    }
}
