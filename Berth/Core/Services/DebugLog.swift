import Foundation

/// 落盘诊断日志:用户或 iOS 应用容器的 Library/Logs/Berth.log。
/// os_log 在开发机上受完全磁盘访问限制经常读不出来,连接类疑难杂症(本地网络门禁、
/// 代理拦截)没有它排查全靠猜。只记连接生命周期事件,不记任何机密。
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Berth.log")
    }()

    private static let queue = DispatchQueue(label: "berth.debuglog", qos: .utility)
    private static let maxSize = 1 << 20 // 1 MB,超了从头来

    static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxSize {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
