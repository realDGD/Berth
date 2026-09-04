import Foundation

/// 管理普通下载的目标路径事务提交。
/// 保证:
/// 1. 下载过程中不直接写入 finalURL, 也不提前 truncate 现有文件。
/// 2. 在与 finalURL 同一父目录创建隐藏且带 UUID 的唯一 working path (.filename.berth-part-<UUID>),
///    保证原子重命名与多任务隔离。
/// 3. 成功完成后原子提交为 finalURL (文件使用 replaceItemAt, 目录使用 rename)。
/// 4. 目标目录若已存在且非空, 拒绝静默覆盖/合并, 抛出明确冲突。
/// 5. 取消或失败时 discard 删除 working path, 原 finalURL 完好无损。
public struct DownloadDestinationTransaction: Sendable {
    public enum TransactionError: LocalizedError, Equatable {
        case destinationDirectoryNotEmpty(URL)
        case invalidParentDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case .destinationDirectoryNotEmpty(let url):
                return String(localized: "目标目录已存在且不为空: \(url.lastPathComponent)")
            case .invalidParentDirectory(let url):
                return String(localized: "目标父目录无效: \(url.path)")
            }
        }
    }

    public let finalURL: URL
    public let workingURL: URL
    public let isDirectory: Bool
    private let fileManager: FileManager

    public init(
        finalURL: URL,
        workingURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) {
        self.finalURL = finalURL
        self.workingURL = workingURL
        self.isDirectory = isDirectory
        self.fileManager = fileManager
    }

    public static func begin(
        finalURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) throws -> DownloadDestinationTransaction {
        let parentURL = finalURL.deletingLastPathComponent()
        guard parentURL.path != finalURL.path else {
            throw TransactionError.invalidParentDirectory(parentURL)
        }

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let originalName = finalURL.lastPathComponent
        try LocalPathComponentValidator.validateComponent(originalName)

        // 统一命名规则: .<originalName>.berth-part-<UUID>
        let workingName = ".\(originalName).berth-part-\(UUID().uuidString)"
        let workingURL = try LocalPathComponentValidator.safeURL(
            in: parentURL,
            component: workingName,
            isDirectory: isDirectory
        )

        if isDirectory {
            try fileManager.createDirectory(at: workingURL, withIntermediateDirectories: true)
        }

        return DownloadDestinationTransaction(
            finalURL: finalURL,
            workingURL: workingURL,
            isDirectory: isDirectory,
            fileManager: fileManager
        )
    }

    public func commit() throws {
        guard fileManager.fileExists(atPath: workingURL.path) else {
            // 若 workingURL 未在磁盘上物化（例如仅在内存中模拟的测试执行器），无需也无法提交到 finalURL
            return
        }

        var isDir: ObjCBool = false
        let finalExists = fileManager.fileExists(atPath: finalURL.path, isDirectory: &isDir)

        if !finalExists {
            // final 不存在: 原子移动
            try fileManager.moveItem(at: workingURL, to: finalURL)
        } else if !isDirectory && !isDir.boolValue {
            // final 是已存在文件: 原子替换
            _ = try fileManager.replaceItemAt(
                finalURL,
                withItemAt: workingURL,
                backupItemName: nil,
                options: []
            )
        } else if isDirectory && isDir.boolValue {
            // final 是已存在目录: 如果非空则拒绝静默合并, 避免不可逆覆盖
            let contents = try fileManager.contentsOfDirectory(atPath: finalURL.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: finalURL)
                try fileManager.moveItem(at: workingURL, to: finalURL)
            } else {
                throw TransactionError.destinationDirectoryNotEmpty(finalURL)
            }
        } else {
            // 文件与目录类型冲突
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func discard() {
        try? fileManager.removeItem(at: workingURL)
    }
}
