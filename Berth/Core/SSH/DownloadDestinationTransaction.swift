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
        case recoveryFailed(
            originalError: NSError,
            recoveryError: NSError,
            recoveryURL: URL,
            finalURL: URL
        )

        public var errorDescription: String? {
            switch self {
            case .destinationDirectoryAlreadyExists(let url):
                return String(localized: "目标目录已存在: \(url.lastPathComponent)")
            case .workingItemMissing(let url):
                return String(localized: "下载临时工作项不存在: \(url.lastPathComponent)")
            case .invalidParentDirectory(let url):
                return String(localized: "目标父目录无效: \(url.path)")
            case .recoveryFailed(let originalError, let recoveryError, let recoveryURL, let finalURL):
                return String(localized: "替换目标文件失败，且恢复原文件失败 (原位置: \(finalURL.path), 暂存位置: \(recoveryURL.path), 替换错误: \(originalError.localizedDescription), 恢复错误: \(recoveryError.localizedDescription))")
            }
        }
    }

    internal static let originalItemLocationKey = "NSFileOriginalItemLocationKey"
    internal static let originalItemLocationKeyAlias = "NSURLOriginalItemLocationKey"

    internal typealias ItemReplacer = @Sendable (URL, URL) throws -> URL?

    public let finalURL: URL
    public let workingURL: URL
    public let isDirectory: Bool
    private let fileManager: FileManager
    private let itemReplacer: ItemReplacer?

    public init(
        finalURL: URL,
        workingURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) {
        self.init(
            finalURL: finalURL,
            workingURL: workingURL,
            isDirectory: isDirectory,
            fileManager: fileManager,
            itemReplacer: nil
        )
    }

    internal init(
        finalURL: URL,
        workingURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default,
        itemReplacer: ItemReplacer? = nil
    ) {
        self.finalURL = finalURL
        self.workingURL = workingURL
        self.isDirectory = isDirectory
        self.fileManager = fileManager
        self.itemReplacer = itemReplacer
    }

    public static func begin(
        finalURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) throws -> DownloadDestinationTransaction {
        try begin(
            finalURL: finalURL,
            isDirectory: isDirectory,
            fileManager: fileManager,
            itemReplacer: nil
        )
    }

    internal static func begin(
        finalURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default,
        itemReplacer: ItemReplacer? = nil
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
            fileManager: fileManager,
            itemReplacer: itemReplacer
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
            do {
                if let replacer = itemReplacer {
                    _ = try replacer(finalURL, workingURL)
                } else {
                    _ = try fileManager.replaceItemAt(
                        finalURL,
                        withItemAt: workingURL,
                        backupItemName: nil,
                        options: []
                    )
                }
            } catch {
                // 检查 finalURL 是否仍作为原文件存在于原位
                var finalIsDir: ObjCBool = false
                let finalStillExists = fileManager.fileExists(atPath: finalURL.path, isDirectory: &finalIsDir)
                if finalStillExists && !finalIsDir.boolValue {
                    // 原文件依然在原位（在修改 original 前失败），直接抛出原替换错误
                    throw error
                }

                // finalURL 已不存在：Foundation 可能在替换过程中将原文件移至暂存位置
                let recoveryURL: URL?
                let nsError = error as NSError
                let rawLocation = nsError.userInfo[Self.originalItemLocationKey]
                    ?? nsError.userInfo[Self.originalItemLocationKeyAlias]
                if let url = rawLocation as? URL {
                    recoveryURL = url
                } else if let path = rawLocation as? String {
                    recoveryURL = URL(fileURLWithPath: path)
                } else {
                    recoveryURL = nil
                }

                if let recoveryURL {
                    var restored = false
                    do {
                        try fileManager.moveItem(at: recoveryURL, to: finalURL)
                        restored = true
                    } catch let recoveryError {
                        throw TransactionError.recoveryFailed(
                            originalError: nsError,
                            recoveryError: recoveryError as NSError,
                            recoveryURL: recoveryURL,
                            finalURL: finalURL
                        )
                    }
                    if restored {
                        // 原始文件已成功复位，但新内容替换未完成，向上重新抛出原替换错误
                        throw error
                    }
                } else {
                    // finalURL 消失且未提供 NSFileOriginalItemLocationKey
                    let missingLocationError = NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.fileNoSuchFile.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Original item missing at finalURL and no recovery location was provided by Foundation"]
                    )
                    throw TransactionError.recoveryFailed(
                        originalError: nsError,
                        recoveryError: missingLocationError,
                        recoveryURL: finalURL,
                        finalURL: finalURL
                    )
                }
            }
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
