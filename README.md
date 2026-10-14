# 开发工具箱

Swift / AppKit / SwiftUI 原生 macOS 菜单栏应用，无第三方依赖。点击右上角服务器图标展开卡片面板，跟随系统浅色、深色外观及强调色。

面板直接显示三张功能卡片。右键点击菜单栏图标，可刷新所有数据或退出工具箱。

## 构建与运行

需要 macOS Command Line Tools。当前版本已在本机 macOS 26.7.1 验证。

```bash
bash scripts/build.sh
open "dist/Dev Toolbox.app"
```

退出工具箱时数据库服务继续运行。

## 登录自动启动

本机已将工具箱安装到 `~/Applications/Dev Toolbox.app`，并注册当前用户的登录自动启动。工具箱启动后显示菜单栏图标，MySQL、Redis 仍需手动启动。

```bash
# 安装/更新应用并开启登录自动启动
bash scripts/configure-autostart.sh enable

# 关闭登录自动启动（保留应用）
bash scripts/configure-autostart.sh disable
```

配置文件为 `~/Library/LaunchAgents/local.pc2mac.devtoolbox.plist`，关闭时保存为 `.plist.disabled`。修改源码并重新构建后，再运行 `enable` 更新已安装版本。

## 面板功能

- 本地服务：Docker Desktop 的运行状态和单独启停；停止前确认，因为运行中的容器也会停止。Nacos 3.2.4 显示当前用户 LaunchAgent 的运行状态，支持单独启动和停止。MySQL 8.4、Redis 支持单独、批量启动/停止。数据库启动调用 `brew services run`，不会注册登录或开机自启；停止调用 `brew services stop`。沿用已有密码配置。Docker 的登录自动启动由 Docker Desktop 设置控制。
- Codex 额度：当前本机 Codex 账户的真实剩余额度、额度窗口、重置日期和倒计时。面板打开时每 5 分钟刷新，也支持手动刷新；失败时明确标记上次数据。时间随系统时区显示。
- 本机状态：内存使用和压力、磁盘使用、CPU 负载、下载/上传速度及近期趋势图。面板打开时每秒采样，关闭后暂停；磁盘容量每 30 秒刷新。首次 CPU、网速采样需建立基线，暂不可用时不会显示虚构数值。

Codex 使用现有 CLI 的只读 [`account/rateLimits/read` 接口](https://learn.chatgpt.com/docs/app-server)，由 CLI 管理已有登录。工具箱不打开凭据文件，不保存或展示 Token，不发送推理或重置请求。不需要另设 API key。如果未安装或未登录，会显示对应提示。

内存计入不可回收的应用内存、系统有线内存、实际压缩内存，排除可回收文件缓存。与 macOS 常见内存显示一致，GB 标签采用二进制容量（24 GB 物理内存显示为 24）；磁盘采用十进制 GB，并按用户 Data 卷的可用容量计算，可用空间含可回收部分。网速统计启用的 Wi-Fi/以太网物理接口，包含局域网流量和协议开销，排除回环、VPN 虚拟接口等重复流量。

MySQL、Redis 的服务状态来自当前用户的 Homebrew 服务管理，不包含独立命令或其他用户启动的数据库进程。Docker 状态通过 Docker Desktop CLI 检查；菜单栏工具箱不会在登录时自动启动 Docker。Nacos 状态通过 `launchctl` 查询 `local.pc2mac.nacos`，不读取或保存登录密码。

## 开发与验证

- `Sources/main.swift`：菜单栏图标、弹出面板生命周期。
- `Sources/DashboardView.swift`：卡片、进度条、趋势图和布局。
- `Sources/DashboardModel.swift`：刷新策略和本地服务操作。
- `Sources/DockerDesktop.swift`：Docker Desktop 状态、引擎启停。
- `Sources/NacosService.swift`：Nacos LaunchAgent 状态和启停。
- `Sources/SystemMetrics.swift`：原生系统指标。
- `Sources/CodexUsage.swift`：Codex 额度数据源，兼容多个额度桶及旧接口格式。

扩展其他本地服务可修改 `services` 列表；添加其他模块时，将数据提供器与卡片视图分别实现。

```bash
# 系统指标：校验实时原生数值、首次采样标记
swiftc -swift-version 5 Sources/SystemMetrics.swift Tests/SystemMetricsSmoke.swift -o /tmp/system-metrics-smoke
/tmp/system-metrics-smoke

# 额度：解析、超时清理；--live 额外验证本机账户读取
swiftc -swift-version 5 Sources/CodexUsage.swift Tests/CodexUsageSmoke.swift -o /tmp/codex-quota-smoke
/tmp/codex-quota-smoke --live

# 集成：实际启动/停止两项服务，校验未注册开机自启。服务已运行时跳过。
swiftc -swift-version 5 Sources/DashboardModel.swift Sources/DockerDesktop.swift Sources/NacosService.swift Sources/SystemMetrics.swift Sources/CodexUsage.swift Sources/LocalCommand.swift Tests/DashboardSmoke.swift -framework Cocoa -framework SwiftUI -o /tmp/dashboard-smoke
/tmp/dashboard-smoke

# 原生组件渲染：使用真实本机数据，输出浅色、深色预览
"dist/Dev Toolbox.app/Contents/MacOS/DevToolbox" --render-previews "$PWD/previews"
"dist/Dev Toolbox.app/Contents/MacOS/DevToolbox" --self-test-ui
```

小屏幕面板限制高度，卡片区域可滚动。`--preview` 可使用独立窗口检查界面；正常运行仅显示菜单栏图标。

服务命令有 45 秒超时和有界输出处理，异常进程不会永久锁住按钮。命令执行器单独验证：

```bash
swiftc -swift-version 5 Sources/LocalCommand.swift Tests/LocalCommandSmoke.swift -o /tmp/local-command-smoke
/tmp/local-command-smoke
```
