#if DEBUG
import AppKit
import Foundation
import SwiftData

/// 仪表盘自动化验收:BERTH_DASHBOARD_AUTOTEST=1。
///
/// 流程(照着真实用法走一遍):
///   1. 建两台主机 —— 一台真 sshd,一台端口打不通(验离线卡片)
///   2. 在终端连一次真主机并信任指纹(仪表盘是非交互拨号,未确认的主机密钥会被拒)
///   3. 走菜单 ⌘0 把主窗口切成仪表盘(顺带验菜单接线),等到采到第二份样本
///      (CPU 占用要两次采样才有);此时终端会话开着 → 采集必须借它的连接
///   4. 校验:真主机在线且 CPU/内存/磁盘都有数;假主机离线
///   5. 关掉终端会话 → 仪表盘必须自己拨一条监控连接接着采
///   6. 切回终端再撕成独立窗口 → 观察者计数正确,采集不断
///
/// 环境:BERTH_TEST_HOST/PORT/USER/PASSWORD + BERTH_TEST_DUMP
///      BERTH_DASHBOARD_SNAPSHOT=<png> 可顺手把仪表盘窗口截下来
@MainActor
enum DashboardAcceptanceTest {

    static func runIfRequested(container: ModelContainer) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_DASHBOARD_AUTOTEST"] == "1",
              let host = env["BERTH_TEST_HOST"],
              let user = env["BERTH_TEST_USER"],
              let password = env["BERTH_TEST_PASSWORD"],
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }
        let port = Int(env["BERTH_TEST_PORT"] ?? "22") ?? 22

        var log: [String] = []
        func mark(_ step: String) {
            log.append(step)
            try? log.joined(separator: "\n").write(toFile: dumpBase + ".dashboard.log", atomically: true, encoding: .utf8)
        }
        mark("STARTED")

        // 自动化下不弹生物识别;间隔压到 2s,验收不用等一分钟
        UserDefaults.standard.set(false, forKey: SettingsKeys.requireTouchIDForKeys)
        UserDefaults.standard.set(2.0, forKey: SettingsKeys.dashboardInterval)

        let context = container.mainContext
        let good = Host(label: "dash-live", hostname: host, port: port, username: user)
        // 端口没人监听 → 连接被拒,走离线卡片
        let dead = Host(label: "dash-dead", hostname: "127.0.0.1", port: 65533, username: user)
        context.insert(good)
        context.insert(dead)
        try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: good.id))
        try? KeychainStore.save(password, account: KeychainStore.passwordAccount(for: dead.id))
        try? context.save()
        defer {
            KeychainStore.deleteSecrets(for: good.id)
            KeychainStore.deleteSecrets(for: dead.id)
        }

        // 1. 先用终端会话把主机密钥信任下来(等价于用户第一次手动连接)
        let session = SessionManager.shared.open(spec: HostSpec(host: good))
        var trusted = false
        let trustDeadline = Date().addingTimeInterval(25)
        while Date() < trustDeadline {
            if session.hostKeyPrompt != nil { session.resolveHostKeyPrompt(accepted: true) }
            if case .connected = session.state { trusted = true; break }
            if case .disconnected(let reason) = session.state {
                mark("TERMINAL_CONNECT_FAIL \(reason)")
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        mark(trusted ? "HOSTKEY_TRUSTED_OK" : "HOSTKEY_TRUSTED_FAIL")

        // 2. 走菜单(⌘0 同款)把主窗口终端区切成仪表盘。会话保持开着
        mark(clickMenuItem { $0.hasPrefix("仪表盘") || $0.hasPrefix("Dashboard") } ? "MENU_TOGGLE_OK" : "MENU_TOGGLE_FAIL")
        try? await Task.sleep(for: .milliseconds(500))
        mark(SessionManager.shared.isDashboardVisible ? "EMBEDDED_VISIBLE_OK" : "EMBEDDED_VISIBLE_FAIL")

        // 3. 等第二份样本(CPU 占用要跨两次采样求差)
        let monitor = ServerMonitor.shared
        var liveReading: ServerMetricsReading?
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let state = monitor.states[good.id], state.status == .online,
               let reading = state.reading, reading.cpuFraction != nil {
                liveReading = reading
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }

        if let reading = liveReading {
            mark("LIVE_ONLINE_OK cpu=\(MetricFormat.percent(reading.cpuFraction))"
                + " mem=\(MetricFormat.percent(reading.memFraction))"
                + " disk=\(MetricFormat.percent(reading.primaryDisk?.fraction))"
                + " load=\(MetricFormat.load(reading.load))"
                + " uptime=\(MetricFormat.uptime(reading.uptimeSeconds))"
                + " rx=\(MetricFormat.rate(reading.netRxRate))"
                + " os=\(reading.os)")
            mark(reading.memFraction != nil ? "MEMORY_OK" : "MEMORY_FAIL")
            mark(reading.primaryDisk != nil ? "DISK_OK" : "DISK_FAIL")
            mark(monitor.states[good.id]?.history.isEmpty == false ? "HISTORY_OK" : "HISTORY_FAIL")
        } else {
            mark("LIVE_ONLINE_FAIL state=\(String(describing: monitor.states[good.id]?.status))")
        }

        // 4. 终端会话开着时,采集必须走那条现成连接(零额外 TCP)
        mark(monitor.states[good.id]?.borrowsSession == true ? "BORROW_SESSION_OK" : "BORROW_SESSION_FAIL")

        // 5. 关掉终端会话 → 仪表盘得自己拨一条接着采
        SessionManager.shared.closePane(session)
        var ownDial = false
        let ownDeadline = Date().addingTimeInterval(30)
        while Date() < ownDeadline {
            if let state = monitor.states[good.id], state.status == .online, state.borrowsSession == false {
                ownDial = true
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        mark(ownDial ? "OWN_DIAL_OK" : "OWN_DIAL_FAIL state=\(String(describing: monitor.states[good.id]?.status))")

        // 6. 打不通的主机应当落到离线,且带人话原因
        var deadReason: String?
        let deadDeadline = Date().addingTimeInterval(20)
        while Date() < deadDeadline {
            if case .offline(let reason) = monitor.states[dead.id]?.status {
                deadReason = reason
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        mark(deadReason.map { "DEAD_OFFLINE_OK \($0.prefix(80))" } ?? "DEAD_OFFLINE_FAIL")

        // 内嵌形态截图(主窗口)
        if let path = env["BERTH_DASHBOARD_SNAPSHOT"] {
            try? await Task.sleep(for: .seconds(1))
            mark(snapshot(window: mainWindow(), to: path) ? "SNAPSHOT_OK" : "SNAPSHOT_FAIL")
        }

        // 7. 撕成独立窗口:内嵌关掉后采集不能停(观察者计数),数据也不该清空
        mark(clickMenuItem { $0.contains("新窗口") || $0.contains("New Window") } ? "MENU_WINDOW_OK" : "MENU_WINDOW_FAIL")
        try? await Task.sleep(for: .seconds(6))
        let stillLive = monitor.isRunning && monitor.states[good.id]?.status == .online
        mark(stillLive ? "WINDOW_MODE_OK" : "WINDOW_MODE_FAIL running=\(monitor.isRunning) state=\(String(describing: monitor.states[good.id]?.status))")
        mark(SessionManager.shared.isDashboardVisible ? "EMBEDDED_STILL_ON_FAIL" : "EMBEDDED_DISMISSED_OK")

        if let path = env["BERTH_DASHBOARD_SNAPSHOT"] {
            let windowPath = path.replacingOccurrences(of: ".png", with: "-window.png")
            mark(snapshot(window: dashboardWindow(), to: windowPath) ? "WINDOW_SNAPSHOT_OK" : "WINDOW_SNAPSHOT_FAIL")
        }

        mark("ALL_DONE")
    }

    /// 点菜单项 —— 顺便验证菜单确实接上了动作
    private static func clickMenuItem(matching predicate: (String) -> Bool) -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            guard let index = submenu.items.firstIndex(where: { predicate($0.title) }) else { continue }
            submenu.performActionForItem(at: index)
            return true
        }
        return false
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier == MainWindowRaiser.identifier }
    }

    private static func dashboardWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("dashboard") == true)
        } ?? NSApp.windows.first {
            $0.isVisible && ($0.title.contains("仪表盘") || $0.title.contains("Dashboard"))
        }
    }

    /// 窗口自截图(走视图自绘,不需要屏幕录制权限)
    private static func snapshot(window: NSWindow?, to path: String) -> Bool {
        guard let window, let frameView = window.contentView?.superview ?? window.contentView else { return false }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: path))
        return true
    }
}
#endif
