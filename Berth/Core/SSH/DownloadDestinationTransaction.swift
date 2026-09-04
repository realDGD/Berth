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
        case destinationDirectoryAlreadyExists(URL)
        case workingItemMissing(URL)
        case invalidParentDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case .destinationDirectoryAlreadyExists(let url):
                return String(localized: "目标目录已存在: \(url.lastPathComponent)")
            case .workingItemMissing(let url):
                return String(localized: "下载临时工作项不存在: \(url.lastPathComponent)")
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
            // fail-closed: 临时工作项不存在时绝对不得假装提交成功
            throw TransactionError.workingItemMissing(workingURL)
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
        } else if isDir.boolValue {
            // final 是已存在目录 (无论空或非空): 一律拒绝替换, 绝不通过 remove + move 等非事务窗口操作
            throw TransactionError.destinationDirectoryAlreadyExists(finalURL)
        } else {
            // 文件与目录类型冲突 (例如 final 是已存在文件但下载的是目录)
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func discard() {
        try? fileManager.removeItem(at: workingURL)
    }
}
