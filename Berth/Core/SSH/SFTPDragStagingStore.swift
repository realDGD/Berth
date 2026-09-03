import Foundation

public struct SFTPDragStagingLease: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootURL: URL
    public let payloadURL: URL
    public let createdAt: Date

    public init(id: UUID, rootURL: URL, payloadURL: URL, createdAt: Date = Date()) {
        self.id = id
        self.rootURL = rootURL
        self.payloadURL = payloadURL
        self.createdAt = createdAt
    }
}

public struct StagingMarkerMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let pid: Int32
    public let createdAt: Date
    public var deliveredAt: Date?
    public let payloadName: String
    public let isDirectory: Bool

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        payloadName: String,
        isDirectory: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.pid = pid
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.payloadName = payloadName
        self.isDirectory = isDirectory
    }
}

public struct SweepResult: Sendable, Equatable {
    public let examinedCount: Int
    public let reclaimedCount: Int
    public let reclaimedBytes: Int64

    public init(examinedCount: Int, reclaimedCount: Int, reclaimedBytes: Int64) {
        self.examinedCount = examinedCount
        self.reclaimedCount = reclaimedCount
        self.reclaimedBytes = reclaimedBytes
    }
}

/// 管理 Finder 拖拽下载 staging 临时数据的完整所有权与跨进程生命周期。
/// 保证:
/// 1. 下载失败或取消时立即删除 staging root。
/// 2. 交付成功后记录 deliveredAt, 并在宽限期后安全回收。
/// 3. 进程异常退出或崩溃残留的 staging 在下次启动、新建拖拽或打开面板时安全 sweep。
/// 4. 严苛的安全边界: 仅删除位于 staging 根目录下、以 Berth-Drag- 为前缀、
///    含有合法 Berth marker、且符合 stale 条件的实体, 绝不盲目 glob 或跨越符号链接。
public actor SFTPDragStagingStore {
    public static let shared = SFTPDragStagingStore()

    public static let markerFilename = ".berth-lease.json"
    public static let prefix = "Berth-Drag-"

    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private var activeLeases: [UUID: SFTPDragStagingLease] = [:]

    public let deliveredGracePeriod: TimeInterval
    public let interruptedGracePeriod: TimeInterval
    public let absoluteCeiling: TimeInterval

    public init(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        deliveredGracePeriod: TimeInterval = 30 * 60,
        interruptedGracePeriod: TimeInterval = 60 * 60,
        absoluteCeiling: TimeInterval = 24 * 3600
    ) {
        self.baseDirectory = baseDirectory
        self.deliveredGracePeriod = deliveredGracePeriod
        self.interruptedGracePeriod = interruptedGracePeriod
        self.absoluteCeiling = absoluteCeiling
    }

    /// 创建一个全新的 staging lease。
    /// 在创建前执行一次轻量 sweep 回收陈旧残留。
    public func create(
        named: String,
        isDirectory: Bool,
        now: Date = Date()
    ) throws -> SFTPDragStagingLease {
        _ = try? sweepStale(now: now)

        let id = UUID()
        let rootURL = baseDirectory.appendingPathComponent("\(Self.prefix)\(id.uuidString)", isDirectory: true)
        let payloadURL = rootURL.appendingPathComponent(named, isDirectory: isDirectory)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: id,
            pid: ProcessInfo.processInfo.processIdentifier,
            createdAt: now,
            deliveredAt: nil,
            payloadName: named,
            isDirectory: isDirectory
        )
        let markerURL = rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL, options: .atomic)

        let lease = SFTPDragStagingLease(id: id, rootURL: rootURL, payloadURL: payloadURL, createdAt: now)
        activeLeases[id] = lease
        DebugLog.append("drag staging lease created id=\(id) name=\(named)")
        return lease
    }

    /// 标记 staging 已交付给 Finder。移除 active 状态, 并写入 delivered 时间戳。
    public func markDelivered(_ lease: SFTPDragStagingLease, now: Date = Date()) {
        activeLeases.removeValue(forKey: lease.id)
        let markerURL = lease.rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        do {
            let data = try Data(contentsOf: markerURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)
            metadata.deliveredAt = now
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let updated = try encoder.encode(metadata)
            try updated.write(to: markerURL, options: .atomic)
            DebugLog.append("drag staging delivered id=\(lease.id)")
        } catch {
            DebugLog.append("drag staging delivered update failed id=\(lease.id) error=\(error)")
        }
    }

    /// 下载失败或取消时立即删除 staging root。幂等安全。
    public func discard(_ lease: SFTPDragStagingLease) {
        activeLeases.removeValue(forKey: lease.id)
        safelyRemoveStagingRoot(lease.rootURL)
        DebugLog.append("drag staging discarded id=\(lease.id)")
    }

    /// 延迟任务或定时任务在交付宽限期后调用。如果该 lease 仍在 active 态则绝不删除。
    public func discardIfDelivered(_ lease: SFTPDragStagingLease) {
        guard activeLeases[lease.id] == nil else { return }
        safelyRemoveStagingRoot(lease.rootURL)
        DebugLog.append("drag staging delivered gc id=\(lease.id)")
    }

    /// 扫描 baseDirectory, 回收陈旧、已超时交付或遗弃的 staging。
    public func sweepStale(now: Date = Date()) throws -> SweepResult {
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return SweepResult(examinedCount: 0, reclaimedCount: 0, reclaimedBytes: 0)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var examined = 0
        var reclaimed = 0
        var reclaimedBytes: Int64 = 0

        for url in contents {
            guard url.lastPathComponent.hasPrefix(Self.prefix) else { continue }
            examined += 1

            // 1. 严格目录与符号链接检查
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            // 2. 检查路径不越界
            guard isPathWithinBase(url) else { continue }

            // 3. 检查并读取 Berth marker
            let markerURL = url.appendingPathComponent(Self.markerFilename, isDirectory: false)
            let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true else {
                continue
            }
            guard let data = try? Data(contentsOf: markerURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let metadata = try? decoder.decode(StagingMarkerMetadata.self, from: data) else {
                continue
            }
            guard metadata.schemaVersion >= 1,
                  url.lastPathComponent == "\(Self.prefix)\(metadata.id.uuidString)" else {
                continue
            }

            // 4. 当前进程 active lease 绝不删除
            guard activeLeases[metadata.id] == nil else { continue }

            // 5. 判断是否达到 stale 条件
            let shouldReclaim: Bool
            if let deliveredAt = metadata.deliveredAt {
                shouldReclaim = now.timeIntervalSince(deliveredAt) >= deliveredGracePeriod
            } else {
                let age = now.timeIntervalSince(metadata.createdAt)
                if age >= absoluteCeiling {
                    shouldReclaim = true
                } else if metadata.pid != ProcessInfo.processInfo.processIdentifier {
                    let isDead = kill(metadata.pid, 0) != 0
                    shouldReclaim = isDead || age >= interruptedGracePeriod
                } else {
                    shouldReclaim = age >= interruptedGracePeriod
                }
            }

            guard shouldReclaim else { continue }

            // 6. 计算字节数并安全删除
            let bytes = computeSize(of: url)
            if safelyRemoveStagingRoot(url) {
                reclaimed += 1
                reclaimedBytes += bytes
            }
        }

        let result = SweepResult(
            examinedCount: examined,
            reclaimedCount: reclaimed,
            reclaimedBytes: reclaimedBytes
        )
        if reclaimed > 0 {
            DebugLog.append("drag staging sweep examined=\(examined) reclaimed=\(reclaimed) bytes=\(reclaimedBytes)")
        }
        return result
    }

    /// 严格安全检查并删除单个 staging root
    @discardableResult
    private func safelyRemoveStagingRoot(_ rootURL: URL) -> Bool {
        guard isPathWithinBase(rootURL) else { return false }
        guard rootURL.lastPathComponent.hasPrefix(Self.prefix) else { return false }
        let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }

        let markerURL = rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: markerURL.path) else { return false }

        do {
            try fileManager.removeItem(at: rootURL)
            return true
        } catch {
            DebugLog.append("drag staging remove failed url=\(rootURL.lastPathComponent) error=\(error)")
            return false
        }
    }

    private func isPathWithinBase(_ url: URL) -> Bool {
        let basePath = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return targetPath.hasPrefix(basePath + "/") || targetPath == basePath
    }

    private func computeSize(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
