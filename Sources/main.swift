import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = DashboardModel()
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let height = min(720, max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model).frame(height: height))
        popover.contentSize = NSSize(width: 440, height: height)
        popover.behavior = .transient
        popover.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "开发工具箱")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { self.togglePanel() }
        }
        if CommandLine.arguments.contains("--self-test-ui") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.togglePanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.popover.isShown else {
                        fputs("FAIL: native popover did not remain open\n", stderr)
                        exit(1)
                    }
                    self.popover.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard !self.popover.isShown else {
                            fputs("FAIL: native popover did not close after animation\n", stderr)
                            exit(1)
                        }
                        print("PASS: native status-item action opens and closes popover")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "开发工具箱 · 预览"
            window.contentViewController = NSHostingController(rootView: DashboardView(model: model).frame(height: height))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
            model.setVisible(true)
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            let refresh = NSMenuItem(title: "刷新所有数据", action: #selector(refreshAll), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出工具箱", action: #selector(quitApplication), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.setVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func popoverDidClose(_ notification: Notification) { model.setVisible(false) }
    @objc private func refreshAll() { model.refreshAll() }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}

// Render our own native SwiftUI views for layout QA, independent of UI automation.
func renderPreviews(to directory: String) {
    let model = DashboardModel()
    let provider = SystemMetricsProvider()
    _ = provider.sample()
    for _ in 0..<8 {
        Thread.sleep(forTimeInterval: 0.5)
        let sample = provider.sample()
        model.metrics = sample
        if sample.cpuAvailable { model.cpuHistory.append(sample.cpuPercent) }
        if sample.networkAvailable {
            model.downloadHistory.append(sample.downloadBytesPerSecond)
            model.uploadHistory.append(sample.uploadBytesPerSecond)
        }
    }
    model.now = Date()
    model.refreshServices()
    model.refreshDocker()
    let dockerDeadline = Date().addingTimeInterval(10)
    while model.dockerRefreshing && Date() < dockerDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    do { model.quota = try CodexUsageProvider().fetch() }
    catch { model.quotaError = error.localizedDescription }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let view = NSHostingView(rootView: DashboardView(model: model).frame(height: 720))
        window.contentView = view
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dashboard-\(label).png"))
                print("Rendered \(label) dashboard")
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let flag = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > flag + 1 {
    renderPreviews(to: CommandLine.arguments[flag + 1])
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
