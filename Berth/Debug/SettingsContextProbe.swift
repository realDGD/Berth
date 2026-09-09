#if DEBUG
import AppKit
import Foundation
import SwiftData

/// issue #15 诊断:设置窗口(Settings scene)没挂 .modelContainer,
/// 它的 @Environment(\.modelContext) 到底落在哪个容器上?
/// BERTH_SETTINGS_PROBE=<json 路径> 时:启动后自动打开设置窗口,
/// SettingsView 出现时把「自己的 context」与「主容器」各自的 store 路径 + 主机数写盘对比。
@MainActor
enum SettingsContextProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BERTH_SETTINGS_PROBE"] != nil
    }

    /// 启动钩子:等主窗口就绪后打开设置窗口(SwiftUI Settings scene 的标准 action)
    static func runIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["BERTH_SETTINGS_PROBE"] else { return }
        try? await Task.sleep(for: .seconds(2))
        NSApp.activate(ignoringOtherApps: true)
        // showSettingsWindow: 在新系统上返回 true 但不开窗(僵尸 selector),
        // 走 app 菜单的「设置…」项(⌘,)才是可靠路径
        var note = "probe start"
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: appMenu.index(of: item))
            note += "; menu item '\(item.title)' triggered"
        } else {
            note += "; no ⌘, menu item found"
        }
        append(note, to: path)
        try? await Task.sleep(for: .seconds(2))
        let windows = NSApp.windows.map {
            "  window '\($0.title)' id=\($0.identifier?.rawValue ?? "-") visible=\($0.isVisible) class=\(type(of: $0)) size=\($0.frame.size)"
        }
        append(windows.joined(separator: "\n"), to: path)
        // 设置窗内容自截图:看里面到底渲染了什么
        if let settings = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true }),
           let view = settings.contentView?.superview ?? settings.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + ".settings.png"))
                append("settings window snapshot written", to: path)
            }
        }
    }

    /// SettingsView 侧:报告它拿到的 modelContext 望向何方
    static func report(settingsContext: ModelContext) {
        guard let path = ProcessInfo.processInfo.environment["BERTH_SETTINGS_PROBE"] else { return }
        append("report called", to: path)
        var lines: [String] = []

        func describe(_ label: String, container: ModelContainer) {
            let urls = container.configurations.map(\.url.path)
            let context = ModelContext(container)
            let hosts = (try? context.fetchCount(FetchDescriptor<Host>())) ?? -1
            let groups = (try? context.fetchCount(FetchDescriptor<HostGroup>())) ?? -1
            lines.append("\(label): id=\(ObjectIdentifier(container)) hosts=\(hosts) groups=\(groups)")
            lines.append("  stores=\(urls)")
        }

        describe("settings", container: settingsContext.container)
        if let main = SessionManager.shared.modelContainer {
            describe("main", container: main)
            lines.append("sameContainer=\(settingsContext.container === main)")
        } else {
            lines.append("main: <nil>")
        }
        // 关键交叉验证:用设置窗自己的 context 直接数主机(BackupService.export 的同路径)
        let direct = (try? settingsContext.fetchCount(FetchDescriptor<Host>())) ?? -1
        lines.append("settingsContext.fetchCount(Host)=\(direct)")
        // 端到端:用设置窗自己的 context 走真导出,数导出 JSON 里的主机数(issue #15 回归)
        if let data = try? BackupService.export(context: settingsContext),
           let backup = try? { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601;
               return try d.decode(BackupService.Backup.self, from: data) }() {
            lines.append("export: hosts=\(backup.hosts.count) groups=\(backup.groups.count)")
        } else {
            lines.append("export: FAILED")
        }
        append(lines.joined(separator: "\n"), to: path)
    }

    private static func append(_ text: String, to path: String) {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
