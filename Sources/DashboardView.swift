import Cocoa
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    serviceCard
                    quotaCard
                    systemCard
                }.padding(16)
            }
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("服务操作失败", isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button("好", role: .cancel) { model.operationError = nil }
        } message: { Text(model.operationError ?? "") }
        .confirmationDialog("停止 Docker Desktop？", isPresented: Binding(
            get: { model.showingDockerStopConfirmation },
            set: { model.showingDockerStopConfirmation = $0 }
        )) {
            Button("停止 Docker 和所有容器", role: .destructive) { model.operateDocker("stop") }
        } message: {
            Text("当前运行的容器也会停止。")
        }
    }

    private var serviceCard: some View {
        Card {
            sectionTitle("本地服务", symbol: "server.rack")
            HStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 20)).frame(width: 27)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docker Desktop").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(model.dockerStatus == .running ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                        Text(model.dockerStatus.label)
                        Text("· 容器引擎")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if model.dockerStatus == .running {
                    Button("停止") { model.showingDockerStopConfirmation = true }
                        .controlSize(.small).frame(minWidth: 44)
                } else if model.dockerStatus == .stopped {
                    Button("启动") { model.operateDocker("start") }
                        .controlSize(.small).frame(minWidth: 44)
                } else if model.dockerStatus == .error {
                    Button("刷新") { model.refreshDocker() }
                        .controlSize(.small).frame(minWidth: 44)
                }
            }
            .disabled(model.dockerOperationRunning || model.dockerRefreshing)
            if let error = model.dockerError, !error.isEmpty {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ForEach(services) { service in
                HStack(spacing: 10) {
                    Image(systemName: service.symbol).font(.system(size: 20)).frame(width: 27)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name).font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 4) {
                            Circle().fill(model.isRunning(service) ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                            Text(model.status(service))
                            Text("· \(service.detail)")
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(model.isRunning(service) ? "停止" : "启动") {
                        model.operate(model.isRunning(service) ? "stop" : "run", targets: [service])
                    }.controlSize(.small).frame(minWidth: 44)
                        .disabled(model.operationRunning || model.serviceRefreshing)
                }
            }
            Divider()
            HStack {
                Button("一键启动全部") { model.operate("run", targets: services) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("停止全部") { model.operate("stop", targets: services) }.controlSize(.small)
                Spacer()
            }.disabled(model.operationRunning || model.serviceRefreshing)
        }
    }

    private var quotaCard: some View {
        Card {
            sectionTitle("Codex 额度", symbol: "terminal", trailing: model.quota?.plan?.capitalized ?? "当前账户")
            if let snapshot = model.quota, !snapshot.windows.isEmpty {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { index, window in
                    if index > 0 { Divider().padding(.vertical, 1) }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(window.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(Int(max(0, min(100, 100 - window.usedPercent)).rounded()))% 剩余")
                                .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        Meter(value: (100 - window.usedPercent) / 100)
                        if let reset = window.resetsAt {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise")
                                Text(countdown(reset, now: model.now))
                                Spacer(minLength: 0)
                                Text(reset, format: .dateTime.month().day().hour().minute())
                            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        } else { Text("重置时间暂不可用").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
                HStack(spacing: 4) {
                    if model.quotaRefreshing { ProgressView().controlSize(.mini) }
                    Text(model.quotaError != nil ? "刷新失败 · 显示上次数据" : "更新于 \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                    Spacer()
                    Button("刷新") { model.refreshQuota() }.buttonStyle(.borderless).disabled(model.quotaRefreshing)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 1)
                if let error = model.quotaError { Text(error).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else {
                HStack(spacing: 9) {
                    if model.quotaRefreshing { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.quotaRefreshing ? "正在读取账户额度…" : "额度暂不可用").font(.system(size: 12, weight: .medium))
                        Text(model.quotaError ?? "使用本机已登录的 Codex 账户")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !model.quotaRefreshing { Button("重试") { model.refreshQuota() }.controlSize(.small) }
                }.padding(.vertical, 5)
            }
        }
    }

    private var systemCard: some View {
        Card {
            sectionTitle("本机状态", symbol: "desktopcomputer", trailing: "实时")
            HStack(alignment: .top, spacing: 16) {
                capacityCell("内存使用", symbol: "memorychip", used: model.metrics?.memoryUsed,
                    total: model.metrics?.memoryTotal, available: model.metrics?.memoryAvailable == true,
                    footnote: "内存压力 · \(model.metrics?.memoryPressure ?? "检查中")", divisor: 1_073_741_824)
                Divider()
                capacityCell("磁盘使用", symbol: "internaldrive", used: model.metrics?.diskUsed,
                    total: model.metrics?.diskTotal, available: model.metrics?.diskAvailable == true,
                    footnote: "数据卷 · 含可回收空间")
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Label("CPU 负载", systemImage: "cpu").font(.system(size: 11)).foregroundStyle(.secondary)
                Sparkline(values: model.cpuHistory, ceiling: 100)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(height: 23).background(chartGrid).padding(.horizontal, 12)
                    .accessibilityLabel("最近 45 次采样的 CPU 负载")
                Text(model.metrics?.cpuAvailable == true ? String(format: "%.0f%%", model.metrics!.cpuPercent) : "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Divider()
            HStack {
                Label("实时网速", systemImage: "network").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Wi-Fi / 以太网").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                networkCell("下载", symbol: "arrow.down", rate: model.metrics?.downloadBytesPerSecond)
                networkCell("上传", symbol: "arrow.up", rate: model.metrics?.uploadBytesPerSecond)
            }
            ZStack {
                chartGrid
                Sparkline(values: model.downloadHistory, ceiling: max(1024, (model.downloadHistory + model.uploadHistory).max() ?? 1024))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                Sparkline(values: model.uploadHistory, ceiling: max(1024, (model.downloadHistory + model.uploadHistory).max() ?? 1024))
                    .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }.frame(height: 30).accessibilityLabel("最近 45 次采样的下载和上传速率")
        }
    }

    private var chartGrid: some View {
        VStack { Divider(); Spacer(); Divider(); Spacer(); Divider() }.opacity(0.45)
    }

    private func sectionTitle(_ title: String, symbol: String, trailing: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing = trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(.bottom, 1)
    }

    private func capacityCell(_ title: String, symbol: String, used: UInt64?, total: UInt64?, available: Bool, footnote: String, divisor: Double = 1_000_000_000) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(available ? String(format: "%.1f", Double(used ?? 0) / divisor) : "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                if available { Text("GB").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Meter(value: available && (total ?? 0) > 0 ? Double(used ?? 0) / Double(total!) : 0)
            Text(available ? "共 \(String(format: "%.0f", Double(total ?? 0) / divisor)) GB" : "正在读取…")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(footnote).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkCell(_ title: String, symbol: String, rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 10))
                .foregroundStyle(title == "下载" ? Color.accentColor : Color.secondary)
            Text(model.metrics?.networkAvailable == true ? rateText(rate ?? 0) : "采样中…")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }
}

struct Meter: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * max(0, min(1, value)))
                }
        }.frame(height: 5).accessibilityValue("\(Int(max(0, min(1, value)) * 100))%")
    }
}

struct Sparkline: Shape {
    let values: [Double]
    let ceiling: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(values.count - 1),
                                y: rect.maxY - 2 - (rect.height - 4) * min(1, max(0, value / max(1, ceiling))))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

func rateText(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB/s", bytes / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
    if bytes >= 1000 { return String(format: "%.1f KB/s", bytes / 1000) }
    return String(format: "%.0f B/s", bytes)
}

func countdown(_ reset: Date, now: Date) -> String {
    let interval = reset.timeIntervalSince(now)
    guard interval.isFinite, interval < Double(Int.max), interval > Double(Int.min) else { return "重置时间暂不可用" }
    let seconds = max(0, Int(interval))
    if seconds == 0 { return "重置时间已到 · 等待刷新" }
    let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
    if days > 0 { return "\(days) 天 \(hours) 小时后重置" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分后重置" }
    return "\(minutes) 分 \(seconds % 60) 秒后重置"
}
