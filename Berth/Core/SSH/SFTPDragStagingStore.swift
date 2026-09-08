import Foundation

public struct SFTPDragStagingLease: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ownerNonce: UUID
    public let rootURL: URL
    public let payloadURL: URL
    public let createdAt: Date

    public init(
        id: UUID,
        ownerNonce: UUID,
        rootURL: URL,
        payloadURL: URL,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.ownerNonce = ownerNonce
        self.rootURL = rootURL
        self.payloadURL = payloadURL
        self.createdAt = createdAt
    }
}

public struct StagingMarkerMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let pid: Int32
    public let ownerNonce: UUID?
    public let createdAt: Date
    public var heartbeatAt: Date?
    public var deliveredAt: Date?
    public let payloadName: String
    public let isDirectory: Bool
    public var payloadBytes: UInt64?
    public var orphanedAt: Date?

    public init(
        schemaVersion: Int = 2,
        id: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownerNonce: UUID? = nil,
        createdAt: Date = Date(),
        heartbeatAt: Date? = nil,
        deliveredAt: Date? = nil,
        payloadName: String,
        isDirectory: Bool,
        payloadBytes: UInt64? = nil,
        orphanedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.pid = pid
        self.ownerNonce = ownerNonce
        self.createdAt = createdAt
        self.heartbeatAt = heartbeatAt
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

    public init(
        examinedCount: Int,
        reclaimedCount: Int,
        reclaimedBytes: Int64
    ) {
        self.examinedCount = examinedCount
        self.reclaimedCount = reclaimedCount
        self.reclaimedBytes = reclaimedBytes
    }
}

/// 管理 Finder 拖拽下载 staging 临时数据的完整所有权与跨进程生命周期。
/// 保证:
/// 1. 下载失败或取消时立即删除 staging root。
/// 2. 交付成功后更新 deliveredAt 与真实 payloadBytes, 严格先持久化落盘再更新内存 active 状态。
/// 3. 单文件与文件夹统一采用 SFTPDragRetentionPolicy 预估消费保留窗口, 避免大文件/目录被提前回收。
/// 4. 进程异常退出或崩溃残留的 staging 在下次启动、新建拖拽或打开面板时安全 sweep。
/// 5. 严苛的安全边界: 仅删除位于 staging 根目录下、以 Berth-Drag- 为前缀、
///    UUID 格式严格校验、marker 所有权匹配且符合 stale 条件的实体。无 marker
///    目录一律保留，绝不靠名称猜测所有权或跨越符号链接。
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
    private var heartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var lastSweepDate: Date?

    public let interruptedGracePeriod: TimeInterval
    public let minimumSweepInterval: TimeInterval
    public let heartbeatInterval: TimeInterval
    public let heartbeatTimeout: TimeInterval
    private let processLivenessChecker: ProcessLivenessChecker
    private let markerWriter: MarkerWriter
    private let ownerNonce: UUID

    public init(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        interruptedGracePeriod: TimeInterval = 60 * 60,
        minimumSweepInterval: TimeInterval = 60,
        heartbeatInterval: TimeInterval = 60,
        heartbeatTimeout: TimeInterval = 5 * 60,
        ownerNonce: UUID = UUID(),
        processLivenessChecker: @escaping ProcessLivenessChecker = SFTPDragStagingStore.defaultProcessLivenessChecker,
        markerWriter: @escaping MarkerWriter = SFTPDragStagingStore.defaultMarkerWriter
    ) {
        self.baseDirectory = baseDirectory
        self.interruptedGracePeriod = interruptedGracePeriod
        self.minimumSweepInterval = minimumSweepInterval
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.ownerNonce = ownerNonce
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
                schemaVersion: 2,
                id: id,
                pid: ProcessInfo.processInfo.processIdentifier,
                ownerNonce: ownerNonce,
                createdAt: now,
                heartbeatAt: now,
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
            // The root is private to this just-created lease. Without a marker it can never be
            // proven to belong to Berth and therefore cannot be reclaimed by a later sweep.
            try? fileManager.removeItem(at: rootURL)
            throw error
        }

        let lease = SFTPDragStagingLease(
            id: id,
            ownerNonce: ownerNonce,
            rootURL: rootURL,
            payloadURL: payloadURL,
            createdAt: now
        )
        activeLeases[id] = lease
        startHeartbeat(for: lease)
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
        guard metadata.schemaVersion == 2,
              metadata.id == lease.id,
              metadata.ownerNonce == lease.ownerNonce else {
            throw CocoaError(.fileReadCorruptFile)
        }
        metadata.deliveredAt = now
        metadata.payloadBytes = payloadBytes

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let updated = try encoder.encode(metadata)

        // 注入式 marker writer 验证落盘
        try markerWriter(updated, markerURL)

        // 仅在落盘成功后更新内存状态
        activeLeases.removeValue(forKey: lease.id)
        stopHeartbeat(for: lease.id)
        DebugLog.append("drag staging delivered id=\(lease.id) bytes=\(payloadBytes)")
    }

    /// 下载失败或取消时立即删除 staging root。幂等安全。
    public func discard(_ lease: SFTPDragStagingLease) {
        activeLeases.removeValue(forKey: lease.id)
        stopHeartbeat(for: lease.id)
        safelyRemoveStagingRoot(lease.rootURL, expectedLease: lease)
        DebugLog.append("drag staging discarded id=\(lease.id)")
    }

    /// 延迟任务或定时任务在交付宽限期后调用。如果该 lease 仍在 active 态则绝不删除。
    public func discardIfDelivered(_ lease: SFTPDragStagingLease) {
        guard activeLeases[lease.id] == nil else { return }
        safelyRemoveStagingRoot(lease.rootURL, expectedLease: lease)
        DebugLog.append("drag staging delivered gc id=\(lease.id)")
    }

    /// 扫描 baseDirectory, 回收陈旧、已超时交付或遗弃的 staging。
    /// 支持节流 (force == false 时距离上次扫描小于 minimumSweepInterval 则跳过)。
    @discardableResult
    public func sweepStale(now: Date = Date(), force: Bool = true) throws -> SweepResult {
        if !force && !shouldSweep(now: now) {
            return SweepResult(examinedCount: 0, reclaimedCount: 0, reclaimedBytes: 0)
        }
        lastSweepDate = now

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

            // 2. 检查路径严格位于 base 内部
            guard LocalPathComponentValidator.isStrictlyContained(candidate: url, within: baseDirectory) else { continue }

            // 3. 检查是否有 Berth marker
            let markerURL = url.appendingPathComponent(Self.markerFilename, isDirectory: false)
            let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

            // 名称不是所有权凭证。无 marker、符号链接 marker 或不可读 marker 都不能删除。
            guard markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true,
                  let metadata = readMarker(at: markerURL),
                  (metadata.schemaVersion == 1 || metadata.schemaVersion == 2),
                  url.lastPathComponent == "\(Self.prefix)\(metadata.id.uuidString)" else { continue }

            // 当前 store 的 active lease 由内存状态直接保护。
            guard activeLeases[metadata.id] == nil else { continue }

            let shouldReclaim: Bool
            if let deliveredAt = metadata.deliveredAt {
                // 已投递给 Finder: 无论原进程是否存活, 均严格尊重单一 retention 策略。
                let retention = SFTPDragRetentionPolicy.retentionInterval(payloadBytes: metadata.payloadBytes)
                shouldReclaim = now.timeIntervalSince(deliveredAt) >= retention
            } else {
                shouldReclaim = shouldReclaimInterrupted(
                    metadata,
                    markerURL: markerURL,
                    now: now
                )
            }

            guard shouldReclaim else { continue }

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

    private func shouldSweep(now: Date) -> Bool {
        guard let lastSweep = lastSweepDate else { return true }
        return now.timeIntervalSince(lastSweep) >= minimumSweepInterval
    }

    private func shouldReclaimInterrupted(
        _ metadata: StagingMarkerMetadata,
        markerURL: URL,
        now: Date
    ) -> Bool {
        let ownerAlive = processLivenessChecker(metadata.pid)
        let heartbeatAge = metadata.heartbeatAt.map { max(0, now.timeIntervalSince($0)) }

        // schema v1 没有 nonce/heartbeat。为了兼容已经落盘的 marker，只能保守地保护
        // 存活 PID；所有新 lease 都使用下面可检测 PID 重用/停滞的 schema v2。
        if metadata.schemaVersion == 1, ownerAlive {
            return false
        }

        let belongsToThisStore = metadata.schemaVersion == 2
            && metadata.pid == ProcessInfo.processInfo.processIdentifier
            && metadata.ownerNonce == ownerNonce
        let heartbeatIsFresh = metadata.schemaVersion == 2
            && metadata.ownerNonce != nil
            && heartbeatAge.map { $0 <= heartbeatTimeout } == true

        if !belongsToThisStore, ownerAlive, heartbeatIsFresh {
            if metadata.orphanedAt != nil {
                var updated = metadata
                updated.orphanedAt = nil
                _ = updateMarker(updated, at: markerURL)
            }
            return false
        }

        // 死亡进程、PID 已重用或 heartbeat 停滞都先进入 abandoned grace，绝不首次发现即删。
        if let orphanedAt = metadata.orphanedAt {
            let shouldReclaim = now.timeIntervalSince(orphanedAt) >= interruptedGracePeriod
            DebugLog.append(
                "drag staging interrupted id=\(metadata.id) ownerLive=\(ownerAlive) heartbeatAge=\(heartbeatAge ?? -1) reclaim=\(shouldReclaim)"
            )
            return shouldReclaim
        }

        var updated = metadata
        updated.orphanedAt = now
        _ = updateMarker(updated, at: markerURL)
        return false
    }

    @discardableResult
    private func updateMarker(_ metadata: StagingMarkerMetadata, at markerURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try markerWriter(encoder.encode(metadata), markerURL)
            return true
        } catch {
            DebugLog.append("drag staging marker update failed id=\(metadata.id) error=\(error)")
            return false
        }
    }

    private func readMarker(at markerURL: URL) -> StagingMarkerMetadata? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StagingMarkerMetadata.self, from: data)
    }

    private func startHeartbeat(for lease: SFTPDragStagingLease) {
        let interval = heartbeatInterval
        heartbeatTasks[lease.id]?.cancel()
        heartbeatTasks[lease.id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.persistHeartbeat(for: lease)
            }
        }
    }

    private func stopHeartbeat(for id: UUID) {
        heartbeatTasks.removeValue(forKey: id)?.cancel()
    }

    private func persistHeartbeat(for lease: SFTPDragStagingLease, now: Date = Date()) {
        guard activeLeases[lease.id]?.ownerNonce == lease.ownerNonce else {
            stopHeartbeat(for: lease.id)
            return
        }
        let markerURL = lease.rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        guard var metadata = readMarker(at: markerURL),
              metadata.schemaVersion == 2,
              metadata.id == lease.id,
              metadata.ownerNonce == lease.ownerNonce else {
            DebugLog.append("drag staging heartbeat ownership mismatch id=\(lease.id)")
            return
        }
        metadata.heartbeatAt = now
        metadata.orphanedAt = nil
        _ = updateMarker(metadata, at: markerURL)
    }

    /// 严格安全检查并删除单个标准 staging root (必须含有 marker)
    @discardableResult
    private func safelyRemoveStagingRoot(
        _ rootURL: URL,
        expectedLease: SFTPDragStagingLease? = nil
    ) -> Bool {
        guard LocalPathComponentValidator.isStrictlyContained(candidate: rootURL, within: baseDirectory) else { return false }
        let name = rootURL.lastPathComponent
        guard name.hasPrefix(Self.prefix),
              let id = UUID(uuidString: String(name.dropFirst(Self.prefix.count))) else { return false }
        let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }

        let markerURL = rootURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true,
              let metadata = readMarker(at: markerURL),
              metadata.id == id,
              metadata.schemaVersion == 1 || metadata.schemaVersion == 2 else { return false }
        if let expectedLease {
            guard metadata.id == expectedLease.id,
                  metadata.schemaVersion == 2,
                  metadata.ownerNonce == expectedLease.ownerNonce else { return false }
        }

        do {
            try fileManager.removeItem(at: rootURL)
            return true
        } catch {
            DebugLog.append("drag staging remove failed url=\(LogSanitizer.safeFilename(rootURL.lastPathComponent)) error=\(error)")
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
