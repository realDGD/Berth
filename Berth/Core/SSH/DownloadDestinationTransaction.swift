import Darwin
import Foundation

struct DownloadTransactionSweepResult: Sendable, Equatable {
    let examinedCount: Int
    let reclaimedCount: Int
}

private struct DownloadTransactionManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let finalPath: String
    let workingPath: String
    let isDirectory: Bool
}

/// 持有一个跨进程 advisory lock。进程崩溃时内核会自动释放锁，但 manifest 会保留，
/// 下次启动即可精确回收对应的 working item。
final class DownloadTransactionLease: @unchecked Sendable {
    let id: UUID
    private let markerURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var lockFileDescriptor: Int32

    init(
        id: UUID,
        markerURL: URL,
        lockURL: URL,
        lockFileDescriptor: Int32,
        fileManager: FileManager
    ) {
        self.id = id
        self.markerURL = markerURL
        self.lockURL = lockURL
        self.lockFileDescriptor = lockFileDescriptor
        self.fileManager = fileManager
    }

    deinit {
        abandon()
    }

    /// 正常完成：删除 manifest/lock 文件并释放内核锁。
    func complete() {
        release(removeRegistration: true)
    }

    /// 无法立即清理 working item：仅释放锁，保留 manifest 供后续 sweep 重试。
    func abandon() {
        release(removeRegistration: false)
    }

    private func release(removeRegistration: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lockFileDescriptor >= 0 else { return }

        if removeRegistration {
            do {
                if fileManager.fileExists(atPath: markerURL.path) {
                    try fileManager.removeItem(at: markerURL)
                }
            } catch {
                DebugLog.append("download transaction marker cleanup failed id=\(id) error=\(error)")
            }
            do {
                if fileManager.fileExists(atPath: lockURL.path) {
                    try fileManager.removeItem(at: lockURL)
                }
            } catch {
                DebugLog.append("download transaction lock cleanup failed id=\(id) error=\(error)")
            }
        }

        _ = flock(lockFileDescriptor, LOCK_UN)
        _ = Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}

/// 普通“下载…”事务的持久化登记表。
/// manifest 只记录精确的 final/working 路径；活跃事务用 flock 跨进程保护，崩溃后锁自动释放。
final class DownloadTransactionRegistry: @unchecked Sendable {
    static let shared = DownloadTransactionRegistry(baseDirectory: defaultBaseDirectory)

    private static let defaultBaseDirectory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Berth", isDirectory: true)
            .appendingPathComponent("DownloadTransactions", isDirectory: true)
    }()

    let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func register(
        id: UUID,
        finalURL: URL,
        workingURL: URL,
        isDirectory: Bool,
        createdAt: Date = Date()
    ) throws -> DownloadTransactionLease {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let markerURL = self.markerURL(for: id)
        let lockURL = self.lockURL(for: id)
        let descriptor = openLockFile(at: lockURL)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            _ = Darwin.close(descriptor)
            throw POSIXError(code)
        }

        do {
            let manifest = DownloadTransactionManifest(
                schemaVersion: 1,
                id: id,
                createdAt: createdAt,
                finalPath: finalURL.path,
                workingPath: workingURL.path,
                isDirectory: isDirectory
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: markerURL, options: .atomic)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            try? fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: lockURL)
            throw error
        }

        return DownloadTransactionLease(
            id: id,
            markerURL: markerURL,
            lockURL: lockURL,
            lockFileDescriptor: descriptor,
            fileManager: fileManager
        )
    }

    @discardableResult
    func sweepOrphans() throws -> DownloadTransactionSweepResult {
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return DownloadTransactionSweepResult(examinedCount: 0, reclaimedCount: 0)
        }

        let entries = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var examined = 0
        var reclaimed = 0

        for markerURL in entries where markerURL.pathExtension == "json" {
            examined += 1
            let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true else { continue }
            let rawID = markerURL.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: rawID) else { continue }
            let lockURL = self.lockURL(for: id)
            let descriptor = openLockFile(at: lockURL)
            guard descriptor >= 0 else { continue }

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(descriptor)
                continue
            }

            let didReclaim = reclaimOrphan(
                id: id,
                markerURL: markerURL,
                lockURL: lockURL
            )
            if didReclaim { reclaimed += 1 }
            if !fileManager.fileExists(atPath: markerURL.path) {
                // 正常完成可能恰好发生在枚举之后；此时 openLockFile 会重建一个空 lock。
                // marker 已不存在，安全删除这个无主的小文件，避免竞态累积。
                try? fileManager.removeItem(at: lockURL)
            }
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }

        if reclaimed > 0 {
            DebugLog.append("download transaction sweep examined=\(examined) reclaimed=\(reclaimed)")
        }
        return DownloadTransactionSweepResult(examinedCount: examined, reclaimedCount: reclaimed)
    }

    private func reclaimOrphan(id: UUID, markerURL: URL, lockURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: markerURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(DownloadTransactionManifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.id == id,
              let workingURL = validatedWorkingURL(from: manifest)
        else {
            return false
        }

        let parentURL = workingURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue
        else {
            // 外置磁盘或网络卷可能暂时离线；保留登记，待后续启动重试。
            return false
        }

        do {
            if fileManager.fileExists(atPath: workingURL.path) {
                let values = try workingURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true,
                      (manifest.isDirectory ? values.isDirectory == true : values.isRegularFile == true)
                else {
                    return false
                }
                try fileManager.removeItem(at: workingURL)
            }
            try? fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: lockURL)
            DebugLog.append("orphaned download transaction reclaimed id=\(id) name=\(LogSanitizer.safeFilename(workingURL.lastPathComponent))")
            return true
        } catch {
            DebugLog.append("orphaned download transaction cleanup failed id=\(id) name=\(LogSanitizer.safeFilename(workingURL.lastPathComponent)) error=\(error)")
            return false
        }
    }

    private func validatedWorkingURL(from manifest: DownloadTransactionManifest) -> URL? {
        let finalURL = URL(fileURLWithPath: manifest.finalPath).standardizedFileURL
        let workingURL = URL(fileURLWithPath: manifest.workingPath).standardizedFileURL
        guard finalURL.isFileURL, workingURL.isFileURL,
              finalURL.deletingLastPathComponent().path == workingURL.deletingLastPathComponent().path,
              !finalURL.lastPathComponent.isEmpty
        else {
            return nil
        }

        let expectedName = ".\(finalURL.lastPathComponent).berth-part-\(manifest.id.uuidString)"
        guard workingURL.lastPathComponent == expectedName else { return nil }
        return workingURL
    }

    private func markerURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func lockURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).lock", isDirectory: false)
    }

    private func openLockFile(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
    }
}

/// 将目标路径检查、原子提交和递归清理隔离在后台 actor，避免大型目录取消或失败时
/// 由 `SFTPBrowser` 的 MainActor 同步执行 FileManager 操作而冻结界面。
actor DownloadDestinationTransactionWorker {
    static let shared = DownloadDestinationTransactionWorker()

    func begin(finalURL: URL, isDirectory: Bool) throws -> DownloadDestinationTransaction {
        try Task.checkCancellation()
        return try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: isDirectory)
    }

    func commit(_ transaction: DownloadDestinationTransaction) throws {
        try Task.checkCancellation()
        try transaction.commit()
    }

    func discard(_ transaction: DownloadDestinationTransaction) {
        transaction.discard()
    }
}

/// 管理普通下载的目标路径事务提交。
/// 保证:
/// 1. 下载过程中不直接写入 finalURL, 也不提前 truncate 现有文件。
/// 2. 在与 finalURL 同一父目录创建隐藏且带 UUID 的唯一 working path (.filename.berth-part-<UUID>),
///    保证原子重命名与多任务隔离。
/// 3. final 不存在时原子 rename；已有文件时使用 renameatx_np(RENAME_SWAP) 原子交换。
/// 4. 取消或失败时删除 working path；崩溃残留由持久化 registry 在下次启动安全回收。
public struct DownloadDestinationTransaction: @unchecked Sendable {
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

    internal typealias ItemExchanger = @Sendable (URL, URL) throws -> Void

    public let finalURL: URL
    public let workingURL: URL
    public let isDirectory: Bool
    private let fileManager: FileManager
    private let itemExchanger: ItemExchanger?
    private let lease: DownloadTransactionLease

    private init(
        finalURL: URL,
        workingURL: URL,
        isDirectory: Bool,
        fileManager: FileManager,
        itemExchanger: ItemExchanger?,
        lease: DownloadTransactionLease
    ) {
        self.finalURL = finalURL
        self.workingURL = workingURL
        self.isDirectory = isDirectory
        self.fileManager = fileManager
        self.itemExchanger = itemExchanger
        self.lease = lease
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
            itemExchanger: nil,
            registry: .shared
        )
    }

    internal static func begin(
        finalURL: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default,
        itemExchanger: ItemExchanger? = nil,
        registry: DownloadTransactionRegistry
    ) throws -> DownloadDestinationTransaction {
        let parentURL = finalURL.deletingLastPathComponent()
        guard parentURL.path != finalURL.path else {
            throw TransactionError.invalidParentDirectory(parentURL)
        }

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try LocalPathComponentValidator.validateComponent(finalURL.lastPathComponent)

        // 目录下载不支持覆盖或合并；文件下载也不能替换现有目录。必须在创建
        // working path/manifest 之前拒绝，避免大型远端目录完整传输后才失败。
        var finalIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: finalURL.path, isDirectory: &finalIsDirectory) {
            if finalIsDirectory.boolValue {
                throw TransactionError.destinationDirectoryAlreadyExists(finalURL)
            }
            if isDirectory {
                throw CocoaError(.fileWriteFileExists)
            }
        }

        let id = UUID()
        let workingName = ".\(finalURL.lastPathComponent).berth-part-\(id.uuidString)"
        let workingURL = try LocalPathComponentValidator.safeURL(
            in: parentURL,
            component: workingName,
            isDirectory: isDirectory
        )
        let lease = try registry.register(
            id: id,
            finalURL: finalURL,
            workingURL: workingURL,
            isDirectory: isDirectory
        )

        do {
            if isDirectory {
                try fileManager.createDirectory(at: workingURL, withIntermediateDirectories: true)
            }
        } catch {
            lease.complete()
            throw error
        }

        return DownloadDestinationTransaction(
            finalURL: finalURL,
            workingURL: workingURL,
            isDirectory: isDirectory,
            fileManager: fileManager,
            itemExchanger: itemExchanger,
            lease: lease
        )
    }

    @discardableResult
    static func sweepOrphans() throws -> DownloadTransactionSweepResult {
        try DownloadTransactionRegistry.shared.sweepOrphans()
    }

    public func commit() throws {
        guard fileManager.fileExists(atPath: workingURL.path) else {
            lease.complete()
            throw TransactionError.workingItemMissing(workingURL)
        }

        var finalIsDirectory: ObjCBool = false
        let finalExists = fileManager.fileExists(atPath: finalURL.path, isDirectory: &finalIsDirectory)

        if !finalExists {
            try fileManager.moveItem(at: workingURL, to: finalURL)
            lease.complete()
        } else if !isDirectory && !finalIsDirectory.boolValue {
            if let itemExchanger {
                try itemExchanger(workingURL, finalURL)
            } else {
                try Self.exchangeItemsAtomically(workingURL, finalURL)
            }

            // 原子交换已经是 commit point。workingURL 现在保存旧 final；清理失败时保留
            // registry，让下次启动重试，不能把已成功提交的新 final 回报成失败。
            do {
                try fileManager.removeItem(at: workingURL)
                lease.complete()
            } catch {
                lease.abandon()
                DebugLog.append("download transaction old item cleanup deferred name=\(LogSanitizer.safeFilename(workingURL.lastPathComponent)) error=\(error)")
            }
        } else if finalIsDirectory.boolValue {
            throw TransactionError.destinationDirectoryAlreadyExists(finalURL)
        } else {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func discard() {
        do {
            if fileManager.fileExists(atPath: workingURL.path) {
                try fileManager.removeItem(at: workingURL)
            }
            lease.complete()
        } catch {
            lease.abandon()
            DebugLog.append("download transaction discard deferred name=\(LogSanitizer.safeFilename(workingURL.lastPathComponent)) error=\(error)")
        }
    }

    /// 测试中模拟进程在未执行 discard 的情况下退出；生产崩溃由内核自动释放 flock。
    internal func abandonWithoutCleanup() {
        lease.abandon()
    }

    private static func exchangeItemsAtomically(_ lhs: URL, _ rhs: URL) throws {
        var callErrno: Int32 = 0
        let result: Int32 = lhs.withUnsafeFileSystemRepresentation { lhsPath in
            rhs.withUnsafeFileSystemRepresentation { rhsPath in
                guard let lhsPath, let rhsPath else {
                    callErrno = EINVAL
                    return -1
                }
                let result = Darwin.renameatx_np(
                    AT_FDCWD,
                    lhsPath,
                    AT_FDCWD,
                    rhsPath,
                    UInt32(RENAME_SWAP)
                )
                if result != 0 { callErrno = errno }
                return result
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: callErrno) ?? .EIO)
        }
    }
}
