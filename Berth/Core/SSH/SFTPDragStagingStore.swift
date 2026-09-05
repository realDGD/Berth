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
    public var payloadBytes: UInt64?
    public var orphanedAt: Date?

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        payloadName: String,
        isDirectory: Bool,
        payloadBytes: UInt64? = nil,
        orphanedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.pid = pid
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.payloadName = payloadName
        self.isDirectory = isDirectory
        self.payloadBytes = payloadBytes
        self.orphanedAt = orphanedAt
    }
}

public struct SweepResult: Sendable, Equatable {
    public let examinedCount: Int
    public let reclaimedCount: Int
    public let reclaimedBytes: Int64
    public let reclaimedLegacyCount: Int

    public init(
        examinedCount: Int,
        reclaimedCount: Int,
        reclaimedBytes: Int64,
        reclaimedLegacyCount: Int = 0
    ) {
        self.examinedCount = examinedCount
        self.reclaimedCount = reclaimedCount
        self.reclaimedBytes = reclaimedBytes
        self.reclaimedLegacyCount = reclaimedLegacyCount
    }
}

/// 管理 Finder 拖拽下载 staging 临时数据的完整所有权与跨进程生命周期。
/// 保证:
/// 1. 下载失败或取消时立即删除 staging root。
/// 2. 交付成功后更新 deliveredAt 与真实 payloadBytes, 严格先持久化落盘再更新内存 active 状态。
/// 3. 单文件与文件夹统一采用 SFTPDragRetentionPolicy 预估消费保留窗口, 避免大文件/目录被提前回收。
/// 4. 进程异常退出或崩溃残留的 staging 在下次启动、新建拖拽或打开面板时安全 sweep。
/// 5. 严苛的安全边界: 仅删除位于 staging 根目录下、以 Berth-Drag- 为前缀、
///    UUID 格式严格校验、且符合 stale 条件的实体, 绝不盲目 glob 或跨越符号链接。
/// 6. 针对 89076ef 以前创建的 markerless legacy staging, 仅在严格满足直接子目录、
///    严格 UUID 名称格式、非符号链接、未越界且超过安全 TTL (默认 24h) 时才安全回收。
public actor SFTPDragStagingStore {
    public static let shared = SFTPDragStagingStore()

    public static let markerFilename = ".berth-lease.json"
    public static let prefix = "Berth-Drag-"

    public typealias ProcessLivenessChecker = @Sendable (Int32) -> Bool
    public typealias MarkerWriter = @Sendable (Data, URL) throws -> Void

    /// 严格遵循 POSIX 语义的进程存活检测器:
    /// kill(pid, 0) == 0: 进程存在
    /// errno == EPERM: 进程存在(无发信号权限)
    /// errno == ESRCH: 进程不存在
    public static let defaultProcessLivenessChecker: ProcessLivenessChecker = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    public static let defaultMarkerWriter: MarkerWriter = { data, url in
        try data.write(to: url, options: .atomic)
    }

    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private var activeLeases: [UUID: SFTPDragStagingLease] = [:]
    private var lastSweepDate: Date?

    public let interruptedGracePeriod: TimeInterval
    public let legacyGracePeriod: TimeInterval
    public let minimumSweepInterval: TimeInterval
    private let processLivenessChecker: ProcessLivenessChecker
    private let markerWriter: MarkerWriter

    public init(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        interruptedGracePeriod: TimeInterval = 60 * 60,
        legacyGracePeriod: TimeInterval = 24 * 3600,
        minimumSweepInterval: TimeInterval = 60,
        processLivenessChecker: @escaping ProcessLivenessChecker = SFTPDragStagingStore.defaultProcessLivenessChecker,
        markerWriter: @escaping MarkerWriter = SFTPDragStagingStore.defaultMarkerWriter
    ) {
        self.baseDirectory = baseDirectory
        self.interruptedGracePeriod = interruptedGracePeriod
        self.legacyGracePeriod = legacyGracePeriod
        self.minimumSweepInterval = minimumSweepInterval
        self.processLivenessChecker = processLivenessChecker
        self.markerWriter = markerWriter
    }

    /// 创建一个全新的 staging lease。
    /// 校验文件名有效性并根据节流间隔执行轻量 sweep。
    public func create(
        named: String,
        isDirectory: Bool,
        now: Date = Date()
    ) throws -> SFTPDragStagingLease {
        try LocalPathComponentValidator.validateComponent(named)

        if shouldSweep(now: now) {
            _ = try? sweepStale(now: now, force: false)
        }

        let id = UUID()
        let rootURL = baseDirectory.appendingPathComponent("\(Self.prefix)\(id.uuidString)", isDirectory: true)
        let payloadURL = try LocalPathComponentValidator.safeURL(in: rootURL, component: named, isDirectory: isDirectory)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        do {
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
            try markerWriter(data, markerURL)
        } catch {
            // The root is private to this just-created lease. A markerless root would otherwise
            // survive until the much longer legacy sweep window.
            try? fileManager.removeItem(at: rootURL)
            throw error
        }

        let lease = SFTPDragStagingLease(id: id, rootURL: rootURL, payloadURL: payloadURL, createdAt: now)
        activeLeases[id] = lease
        DebugLog.append("drag staging lease created id=\(id) name=\(LogSanitizer.safeFilename(named))")
        return lease
    }

    /// 标记 staging 已交付给 Finder。
    /// 严格事务语义: 先读取旧 marker, 更新 deliveredAt 与 payloadBytes 并持久化原子落盘。
    /// 仅当磁盘持久化成功后, 才将内存中 activeLeases 移除。
    /// 若写入失败, 抛出异常, 保持 active 保护状态由调用方安全清理, 绝不留下伪 delivered 态。
    public func markDelivered(
        _ lease: SFTPDragStagingLease,
        payloadBytes: UInt64,
        now: Date = Date()
    ) throws {
        let markerURL = lease.rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: markerURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)
        metadata.deliveredAt = now
        metadata.payloadBytes = payloadBytes

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let updated = try encoder.encode(metadata)

        // 注入式 marker writer 验证落盘
        try markerWriter(updated, markerURL)

        // 仅在落盘成功后更新内存状态
        activeLeases.removeValue(forKey: lease.id)
        DebugLog.append("drag staging delivered id=\(lease.id) bytes=\(payloadBytes)")
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
    /// 支持节流 (force == false 时距离上次扫描小于 minimumSweepInterval 则跳过)。
    @discardableResult
    public func sweepStale(now: Date = Date(), force: Bool = true) throws -> SweepResult {
        if !force && !shouldSweep(now: now) {
            return SweepResult(examinedCount: 0, reclaimedCount: 0, reclaimedBytes: 0, reclaimedLegacyCount: 0)
        }
        lastSweepDate = now

        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return SweepResult(examinedCount: 0, reclaimedCount: 0, reclaimedBytes: 0, reclaimedLegacyCount: 0)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var examined = 0
        var reclaimed = 0
        var reclaimedBytes: Int64 = 0
        var reclaimedLegacy = 0

        for url in contents {
            guard url.lastPathComponent.hasPrefix(Self.prefix) else { continue }
            examined += 1

            // 1. 严格目录与符号链接检查
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            // 2. 检查路径严格位于 base 内部
            guard LocalPathComponentValidator.isStrictlyContained(candidate: url, within: baseDirectory) else { continue }

            // 3. 检查是否有 Berth marker
            let markerURL = url.appendingPathComponent(Self.markerFilename, isDirectory: false)
            let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

            if markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true {
                // 有 marker: 按标准 metadata 策略回收
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

                // 当前进程 active lease 绝不删除
                guard activeLeases[metadata.id] == nil else { continue }

                let shouldReclaim: Bool
                if let deliveredAt = metadata.deliveredAt {
                    // 已投递给 Finder: 无论原进程是否存活, 均严格尊重单一来源 SFTPDragRetentionPolicy 窗口
                    let retention = SFTPDragRetentionPolicy.retentionInterval(payloadBytes: metadata.payloadBytes)
                    shouldReclaim = now.timeIntervalSince(deliveredAt) >= retention
                } else {
                    // 未成功投递 (下载中或中断):
                    if metadata.pid != ProcessInfo.processInfo.processIdentifier {
                        let isAlive = processLivenessChecker(metadata.pid)
                        if isAlive {
                            // 核心安全保证: 只要所有者进程确认存活, 绝不删除! 无论 age 经过多久 (30min/2h/48h)
                            if metadata.orphanedAt != nil {
                                var updated = metadata
                                updated.orphanedAt = nil
                                updateMarker(updated, at: markerURL)
                            }
                            shouldReclaim = false
                        } else {
                            // 所有者进程已确认死亡: 必须以首次检测到死亡的 orphanedAt 为起点计算 grace period
                            if let orphanedAt = metadata.orphanedAt {
                                shouldReclaim = now.timeIntervalSince(orphanedAt) >= interruptedGracePeriod
                            } else {
                                // 首次检测到所有者死亡: 写入 orphanedAt 标记, 本次 sweep 绝不删除
                                var updated = metadata
                                updated.orphanedAt = now
                                updateMarker(updated, at: markerURL)
                                shouldReclaim = false
                            }
                        }
                    } else {
                        // 同进程 (但已不在 activeLeases 中): 说明为此前崩溃或未正常清理的残留
                        let age = now.timeIntervalSince(metadata.createdAt)
                        shouldReclaim = age >= interruptedGracePeriod
                    }
                }

                guard shouldReclaim else { continue }

                let bytes = computeSize(of: url)
                if safelyRemoveStagingRoot(url) {
                    reclaimed += 1
                    reclaimedBytes += bytes
                }
            } else {
                // 无 marker: 严格检查是否为 89076ef 以前遗留的 legacy staging 候选
                guard isValidLegacyCandidate(url: url, values: values, now: now) else { continue }

                let bytes = computeSize(of: url)
                if safelyRemoveLegacyStagingRoot(url) {
                    reclaimed += 1
                    reclaimedLegacy += 1
                    reclaimedBytes += bytes
                }
            }
        }

        let result = SweepResult(
            examinedCount: examined,
            reclaimedCount: reclaimed,
            reclaimedBytes: reclaimedBytes,
            reclaimedLegacyCount: reclaimedLegacy
        )
        if reclaimed > 0 {
            DebugLog.append("drag staging sweep examined=\(examined) reclaimed=\(reclaimed) legacy=\(reclaimedLegacy) bytes=\(reclaimedBytes)")
        }
        return result
    }

    private func shouldSweep(now: Date) -> Bool {
        guard let lastSweep = lastSweepDate else { return true }
        return now.timeIntervalSince(lastSweep) >= minimumSweepInterval
    }

    /// 严格判断是否为旧版 (89076ef 之前) 遗留的无 marker staging 目录。
    /// 必须同时满足:
    /// 1. 名称严格匹配 Berth-Drag-<UUID> 且 <UUID> 为合法标准 UUID。
    /// 2. 是真实目录且不是符号链接。
    /// 3. 标准化路径严格在 baseDirectory 内部。
    /// 4. 文件的创建或修改时间已超过 legacyGracePeriod (默认 24h)。
    private func isValidLegacyCandidate(url: URL, values: URLResourceValues?, now: Date) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.prefix) else { return false }
        let rawUUID = String(name.dropFirst(Self.prefix.count))
        guard UUID(uuidString: rawUUID) != nil else { return false }

        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
        guard LocalPathComponentValidator.isStrictlyContained(candidate: url, within: baseDirectory) else { return false }

        let timestamp = values?.contentModificationDate ?? values?.creationDate
        guard let timestamp else { return false }

        return now.timeIntervalSince(timestamp) >= legacyGracePeriod
    }

    private func updateMarker(_ metadata: StagingMarkerMetadata, at markerURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(metadata) {
            try? markerWriter(data, markerURL)
        }
    }

    /// 严格安全检查并删除单个标准 staging root (必须含有 marker)
    @discardableResult
    private func safelyRemoveStagingRoot(_ rootURL: URL) -> Bool {
        guard LocalPathComponentValidator.isStrictlyContained(candidate: rootURL, within: baseDirectory) else { return false }
        guard rootURL.lastPathComponent.hasPrefix(Self.prefix) else { return false }
        let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }

        let markerURL = rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: markerURL.path) else { return false }

        do {
            try fileManager.removeItem(at: rootURL)
            return true
        } catch {
            DebugLog.append("drag staging remove failed url=\(LogSanitizer.safeFilename(rootURL.lastPathComponent)) error=\(error)")
            return false
        }
    }

    /// 严格安全检查并删除经校验确认的 legacy 无 marker staging root
    @discardableResult
    private func safelyRemoveLegacyStagingRoot(_ rootURL: URL) -> Bool {
        guard LocalPathComponentValidator.isStrictlyContained(candidate: rootURL, within: baseDirectory) else { return false }
        let name = rootURL.lastPathComponent
        guard name.hasPrefix(Self.prefix) else { return false }
        let rawUUID = String(name.dropFirst(Self.prefix.count))
        guard UUID(uuidString: rawUUID) != nil else { return false }

        let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }

        do {
            try fileManager.removeItem(at: rootURL)
            DebugLog.append("legacy drag staging reclaimed url=\(LogSanitizer.safeFilename(rootURL.lastPathComponent))")
            return true
        } catch {
            DebugLog.append("legacy drag staging remove failed url=\(LogSanitizer.safeFilename(rootURL.lastPathComponent)) error=\(error)")
            return false
        }
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
