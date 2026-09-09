import Foundation

/// AI 对话历史落盘:每个对话一个 JSON 文件,存 Application Support/Berth/AIChats/。
/// UI 消息与 API 原始 content 块(thinking/tool_use 原样)都存,加载后模型上下文无缝接续。
/// 按主机键控(hostID;本地 Shell 统一 "local"),BERTH_TRANSIENT_STORE=1(自动化验收)不读不写。
enum AIChatHistory {
    struct Summary: Identifiable, Equatable {
        let id: UUID
        let title: String
        let updatedAt: Date
        let messageCount: Int
    }

    /// 每台主机最多保留的对话数,超出删最旧
    private static let maxPerHost = 50

    private static var disabled: Bool {
        ProcessInfo.processInfo.environment["BERTH_TRANSIENT_STORE"] == "1"
    }

    private static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = appSupport.appendingPathComponent("Berth/AIChats", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = hardenOnce
        // 里面是远端命令的完整输出:不进 Time Machine / iCloud 备份
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// 老版本写出的历史文件是 umask 默认的 0644,首次访问时收紧一次
    private static let hardenOnce: Void = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Berth/AIChats", isDirectory: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }()

    static func hostKey(for spec: HostSpec) -> String {
        spec.isLocal ? "local" : spec.hostID.uuidString
    }

    static func save(_ record: [String: Any]) {
        guard !disabled,
              let id = record["id"] as? String,
              JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = directory.appendingPathComponent("\(id).json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let hostKey = record["hostKey"] as? String { prune(hostKey: hostKey) }
    }

    static func load(id: UUID) -> [String: Any]? {
        guard !disabled,
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func delete(id: UUID) {
        guard !disabled else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// 删除主机时连同它的全部对话历史(里面有那台机器上命令的完整输出)
    static func deleteAll(hostKey: String) {
        for record in allRecords(hostKey: hostKey) {
            if let idString = record["id"] as? String, let id = UUID(uuidString: idString) {
                delete(id: id)
            }
        }
    }

    /// 某台主机的全部历史对话,按更新时间倒序
    static func summaries(hostKey: String) -> [Summary] {
        allRecords(hostKey: hostKey)
            .compactMap { record -> Summary? in
                guard let idString = record["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
                return Summary(
                    id: id,
                    title: record["title"] as? String ?? "",
                    updatedAt: Date(timeIntervalSince1970: record["updatedAt"] as? Double ?? 0),
                    messageCount: (record["messages"] as? [Any])?.count ?? 0
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func allRecords(hostKey: String) -> [[String: Any]] {
        guard !disabled,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> [String: Any]? in
                guard let data = try? Data(contentsOf: url),
                      let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      record["hostKey"] as? String == hostKey else { return nil }
                return record
            }
    }

    private static func prune(hostKey: String) {
        let records = allRecords(hostKey: hostKey)
            .sorted { ($0["updatedAt"] as? Double ?? 0) > ($1["updatedAt"] as? Double ?? 0) }
        guard records.count > maxPerHost else { return }
        for record in records.dropFirst(maxPerHost) {
            if let idString = record["id"] as? String, let id = UUID(uuidString: idString) {
                delete(id: id)
            }
        }
    }
}
