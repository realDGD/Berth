#if canImport(AppKit)
import AppKit
#endif
import Citadel
import Foundation
import NIOCore

/// Bridges worker-thread progress to the observable browser state.  Disk and network work never
/// calls the MainActor directly; updates are already throttled by SFTPDownloadEngine.
@MainActor
private final class SFTPDownloadProgressSink {
    private let progress: Progress?
    private let apply: (SFTPDownloadEngine.ProgressUpdate) -> Void

    init(
        progress: Progress?,
        apply: @escaping (SFTPDownloadEngine.ProgressUpdate) -> Void
    ) {
        self.progress = progress
        self.apply = apply
    }

    func consume(_ update: SFTPDownloadEngine.ProgressUpdate) {
        if update.isFinished {
            // Foundation Progress treats a zero-byte transfer as indeterminate unless it has a
            // positive total.  Represent the completed empty file as one logical unit so Finder
            // receives a deterministic 1/1 completion event.
            let total = max(1, update.totalBytes ?? update.completedBytes)
            progress?.totalUnitCount = Int64(clamping: total)
            progress?.completedUnitCount = progress?.totalUnitCount ?? 1
        } else if let totalBytes = update.totalBytes {
            progress?.totalUnitCount = Int64(clamping: max(1, totalBytes))
            progress?.completedUnitCount = min(
                progress?.totalUnitCount ?? 0,
                Int64(clamping: update.completedBytes)
            )
        }
        apply(update)
    }
}

/// SFTP 文件浏览:复用会话 SSHClient 打开 SFTP,维护当前目录与条目,提供上传/下载/增删改。
@MainActor
@Observable
final class SFTPBrowser {

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64
        /// `SFTPFileAttributes.size` is optional.  Preserve that distinction so a reported zero
        /// byte file can skip READ entirely while an unknown-size file still uses EOF fallback.
        let sizeIsKnown: Bool
        let modified: Date?
        var permissions: UInt32 = 0
        /// 权限低 9 位(rwxrwxrwx)
        var mode: UInt32 { permissions & 0o777 }
    }

    /// 目录下载扫描时使用的轻量条目,与 Citadel 类型解耦,便于覆盖递归与符号链接边界。
    struct DownloadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
        let sizeIsKnown: Bool

        init(name: String, kind: Kind, size: UInt64, sizeIsKnown: Bool = true) {
            self.name = name
            self.kind = kind
            self.size = size
            self.sizeIsKnown = sizeIsKnown
        }
    }

    /// 目录上传扫描时使用的轻量条目(issue #17),与下载侧对称,便于覆盖递归与符号链接边界
    struct UploadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
    }

    struct UploadTreeFile: Equatable, Sendable {
        let localURL: URL
        let relativeComponents: [String]
        let size: UInt64
    }

    struct DirectoryUploadPlan: Equatable, Sendable {
        var directories: [[String]] = []
        var files: [UploadTreeFile] = []
        var totalBytes: UInt64 = 0
        var skippedSymlinks = 0
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 一次进行中的传输。并发传输(如连拖两个文件下载)各持独立条目,
    /// 互不覆盖标签/进度,先完成的只清自己,不会把别人的进度条带走。
    struct ActiveTransfer: Identifiable, Equatable {
        let id: UUID
        var label: String
        /// 0...1;nil 表示不确定(扫描中/体积未知)
        var progress: Double?
        var isCancelling: Bool
        var canCancel: Bool

        init(
            id: UUID,
            label: String,
            progress: Double? = nil,
            isCancelling: Bool = false,
            canCancel: Bool = false
        ) {
            self.id = id
            self.label = label
            self.progress = progress
            self.isCancelling = isCancelling
            self.canCancel = canCancel
        }
    }

    private(set) var state: State = .idle
    private(set) var path = "/"
    /// 登录 home,供路径输入的 ~ 展开
    private(set) var homePath = "/"
    private(set) var entries: [Entry] = []
    /// 进行中的传输,按开始顺序排列;空表示空闲
    private(set) var transfers: [ActiveTransfer] = []

    private var sftp: SFTPClient?
    public let configuration: SFTPTransferConfiguration
    /// One budget per browser/SFTP session.  Concurrent drag and panel downloads share this cap
    /// instead of creating an independent request window for every file or directory.
    private let transferBudget: SFTPDownloadEngine.TransferBudget
    private let opener: () async throws -> SFTPClient
    /// 打开后首先落在哪个目录(取该 pane 终端的当前目录);nil 或列不出来时回落 home
    private let initialPath: String?
    /// 面板已关闭:打开中(await opener)被关时,迟到的 client 要立即关掉,不能泄漏子通道
    private var isClosed = false

    init(
        initialPath: String? = nil,
        configuration: SFTPTransferConfiguration = .init(),
        opener: @escaping () async throws -> SFTPClient
    ) {
        let normalized = configuration.normalized
        self.initialPath = initialPath
        self.configuration = normalized
        self.transferBudget = SFTPDownloadEngine.TransferBudget(configuration: normalized)
        self.opener = opener
    }

    #if DEBUG
    /// 测试专用初始化方法: 强制校验注入的 transferBudget 与 configuration 必须绝对一致
    init(
        initialPath: String? = nil,
        configuration: SFTPTransferConfiguration,
        testBudget: SFTPDownloadEngine.TransferBudget,
        opener: @escaping () async throws -> SFTPClient
    ) {
        let normalized = configuration.normalized
        precondition(
            testBudget.configuration == normalized,
            "TransferBudget configuration must match SFTPBrowser configuration"
        )
        self.initialPath = initialPath
        self.configuration = normalized
        self.transferBudget = testBudget
        self.opener = opener
    }
    #endif

    /// 打开 SFTP 并列出 home 目录。子通道打开可能被服务器无响应地挂住
    /// (sshd 未启用 SFTP 子系统 / MaxSessions 限制),15s 看门狗置失败态可重试。
    func start() async {
        guard sftp == nil, state != .loading else { return }
        Task { _ = try? await SFTPDragStagingStore.shared.sweepStale() }
        state = .loading
        let opening = Task { try await self.opener() }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.state == .loading, self.sftp == nil else { return }
            opening.cancel()
            self.state = .failed(String(localized: "打开 SFTP 超时:服务器可能未启用 SFTP 子系统或已达会话上限,点刷新重试。"))
            // 迟到的 client 直接关掉,不能泄漏子通道
            Task.detached { if let late = try? await opening.value { try? await late.close() } }
        }
        do {
            let client = try await opening.value
            watchdog.cancel()
            if isClosed || state != .loading {
                Task.detached { try? await client.close() }
                return
            }
            sftp = client
            let home = (try? await client.getRealPath(atPath: ".")) ?? "/"
            homePath = home
            // 优先落在该 pane 终端的当前目录;那个目录可能已被删/无权限,失败就回落 home
            if let initialPath, initialPath != home {
                await list(path: initialPath)
                if case .failed = state { await list(path: home) }
            } else {
                await list(path: home)
            }
        } catch {
            // 看门狗超时置败后,opening 被 cancel 抛错到这里,不要覆盖超时提示
            if state == .loading { state = .failed(friendly(error)) }
        }
    }

    /// 已连上则重新列目录;打开失败/未打开(如面板先于连接打开)则重试整个打开流程
    func refresh() async {
        if sftp == nil {
            await start()
        } else {
            await list(path: path)
        }
    }

    func enter(_ entry: Entry) async {
        guard entry.isDirectory || entry.isSymlink else { return }
        await list(path: join(path, entry.name))
    }

    func goUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await list(path: parent.isEmpty ? "/" : parent)
    }

    /// 手输路径跳转:支持 ~、~/xxx 与相对当前目录的路径
    func navigate(to newPath: String) async {
        var target = newPath.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if target == "~" {
            target = homePath
        } else if target.hasPrefix("~/") {
            target = join(homePath, String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = join(path, target)
        }
        if target.count > 1, target.hasSuffix("/") { target.removeLast() }
        await list(path: target)
    }

    private func list(path newPath: String) async {
        guard let sftp else { return }
        state = .loading
        do {
            let names = try await sftp.listDirectory(atPath: newPath)
            let components = names.flatMap(\.components)
            let mapped: [Entry] = components.compactMap { component in
                let name = component.filename
                guard name != ".", name != ".." else { return nil }
                let type = fileType(component)
                return Entry(
                    name: name,
                    isDirectory: type == .directory,
                    isSymlink: type == .symlink,
                    size: component.attributes.size ?? 0,
                    sizeIsKnown: component.attributes.size != nil,
                    modified: component.attributes.accessModificationTime?.modificationTime,
                    permissions: component.attributes.permissions ?? 0
                )
            }
            entries = mapped.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            path = newPath
            state = .ready
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 传输

    /// 本地上传的读取块大小(256KB):摊薄往返开销,同时避免整文件读入内存
    private static let uploadChunkSize = 256 * 1024

    private var downloadTasks: [UUID: Task<SFTPDownloadEngine.SFTPDownloadResult, Error>] = [:]
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    typealias DownloadExecutor = @Sendable (
        _ entry: Entry,
        _ remotePath: String,
        _ localURL: URL,
        _ sftp: SFTPClient?,
        _ budget: SFTPDownloadEngine.TransferBudget,
        _ configuration: SFTPTransferConfiguration,
        _ onPlan: @escaping @Sendable (SFTPDownloadEngine.DirectoryPlan) async -> Void,
        _ onProgress: @escaping @Sendable (SFTPDownloadEngine.ProgressUpdate) async -> Void
    ) async throws -> SFTPDownloadEngine.SFTPDownloadResult

    static let defaultDownloadExecutor: DownloadExecutor = { entry, remotePath, localURL, sftp, budget, configuration, onPlan, onProgress in
        guard let sftp else { throw TransferError.sftpUnavailable }
        if entry.isDirectory {
            let plan = try await SFTPDownloadEngine.downloadDirectory(
                remoteRoot: remotePath,
                localRoot: localURL,
                sftp: sftp,
                budget: budget,
                configuration: configuration,
                onPlan: onPlan,
                onProgress: onProgress
            )
            return SFTPDownloadEngine.SFTPDownloadResult(copiedBytes: plan.copiedBytes)
        } else {
            let copiedBytes = try await SFTPDownloadEngine.downloadFile(
                remotePath: remotePath,
                expectedSize: entry.sizeIsKnown ? entry.size : nil,
                localURL: localURL,
                sftp: sftp,
                budget: budget,
                configuration: configuration,
                onProgress: onProgress
            )
            return SFTPDownloadEngine.SFTPDownloadResult(copiedBytes: copiedBytes)
        }
    }

    private var isCustomDownloadExecutor = false
    var downloadExecutor: DownloadExecutor = SFTPBrowser.defaultDownloadExecutor {
        didSet {
            isCustomDownloadExecutor = true
        }
    }

    private func beginTransfer(_ label: String, progress: Double? = nil, canCancel: Bool = false) -> UUID {
        let id = UUID()
        transfers.append(ActiveTransfer(
            id: id,
            label: label,
            progress: progress,
            isCancelling: false,
            canCancel: canCancel
        ))
        return id
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].canCancel, !transfers[index].isCancelling else { return }
        transfers[index].isCancelling = true
        if let handler = cancellationHandlers[id] {
            handler()
        } else {
            downloadTasks[id]?.cancel()
        }
    }

    private func setTransfer(_ id: UUID, label: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].label = label
    }

    private func setTransfer(_ id: UUID, progress: Double?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = progress
    }

    private func endTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    func download(_ entry: Entry, to localURL: URL) async {
        do {
            let worker = DownloadDestinationTransactionWorker.shared
            let tx = try await worker.begin(
                finalURL: localURL,
                isDirectory: entry.isDirectory
            )
            do {
                try Task.checkCancellation()
                try await performDownload(
                    entry,
                    remoteDirectory: path,
                    to: tx.workingURL,
                    externalProgress: nil
                )
                try Task.checkCancellation()
                try await worker.commit(tx)
            } catch {
                await worker.discard(tx)
                throw error
            }
        } catch is CancellationError {
            // 用户主动取消, 不改变 state 为 .failed
        } catch where (error as? CocoaError)?.code == .userCancelled {
            // 用户主动取消
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// Finder 拖出下载使用。拖拽开始时冻结 remoteDirectory,避免传输过程中切换目录后
    /// 同名文件被解析到新的当前位置。错误必须继续抛给 NSItemProvider,让 Finder 显示失败。
    @discardableResult
    func downloadForDrag(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        progress: Progress
    ) async throws -> SFTPDownloadEngine.SFTPDownloadResult {
        try await performDownload(
            entry,
            remoteDirectory: remoteDirectory,
            to: localURL,
            externalProgress: progress
        )
    }

    @discardableResult
    private func performDownload(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        externalProgress: Progress?
    ) async throws -> SFTPDownloadEngine.SFTPDownloadResult {
        // The top-level name is server-controlled too. Validate it before opening a handle or
        // touching the caller-provided local destination; recursive entries are validated by the
        // download engine while it builds the directory plan.
        try LocalPathComponentValidator.validateComponent(entry.name)
        if !isCustomDownloadExecutor {
            guard sftp != nil else { throw TransferError.sftpUnavailable }
        }

        let remotePath = join(remoteDirectory, entry.name)
        let transferID = beginTransfer(
            entry.isDirectory
                ? String(localized: "扫描 \(entry.name)…")
                : String(localized: "下载 \(entry.name)…"),
            progress: !entry.isDirectory && entry.size > 0 ? 0 : nil,
            canCancel: true
        )
        let sink = SFTPDownloadProgressSink(progress: externalProgress) { [weak self] update in
            guard let self else { return }
            if let totalBytes = update.totalBytes, totalBytes > 0 {
                self.setTransfer(transferID, progress: min(
                    1,
                    Double(update.completedBytes) / Double(totalBytes)
                ))
            } else if update.isFinished {
                self.setTransfer(transferID, progress: 1)
            }
        }
        let onProgress: @Sendable (SFTPDownloadEngine.ProgressUpdate) async -> Void = { update in
            await MainActor.run {
                sink.consume(update)
            }
        }

        let onPlan: @Sendable (SFTPDownloadEngine.DirectoryPlan) async -> Void = { [weak self] plan in
            guard let self else { return }
            await MainActor.run {
                self.setTransfer(transferID, label: plan.skippedSymlinks > 0
                    ? String(localized: "下载 \(entry.name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
                    : String(localized: "下载 \(entry.name)…"))
            }
        }

        let transferTask = Task { [weak self] () -> SFTPDownloadEngine.SFTPDownloadResult in
            guard let self else { throw CancellationError() }
            return try await self.downloadExecutor(
                entry,
                remotePath,
                localURL,
                self.sftp,
                self.transferBudget,
                self.configuration,
                onPlan,
                onProgress
            )
        }
        downloadTasks[transferID] = transferTask
        if let externalProgress {
            cancellationHandlers[transferID] = { [weak externalProgress] in
                externalProgress?.cancel()
                transferTask.cancel()
            }
        } else {
            cancellationHandlers[transferID] = {
                transferTask.cancel()
            }
        }
        defer {
            cancellationHandlers.removeValue(forKey: transferID)
            downloadTasks.removeValue(forKey: transferID)
            endTransfer(transferID)
        }

        if Task.isCancelled {
            transferTask.cancel()
        }

        return try await withTaskCancellationHandler {
            let result = try await transferTask.value
            // Task cancellation is cooperative: a custom/finishing executor may return success
            // after cancelTransfer() has already cancelled it. Never let that race reach commit().
            if transferTask.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            return result
        } onCancel: {
            transferTask.cancel()
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    /// 递归删除的执行顺序:先删文件与符号链接(链接删自身、不跟随),再按「最深优先」
    /// 删目录(rmdir 只认空目录)。root 排在 directories 最后。
    struct DirectoryDeletePlan: Equatable, Sendable {
        var removals: [String] = []
        var directories: [String] = []
    }

    static func makeDirectoryDeletePlan(
        remoteRoot: String,
        list: (_ remotePath: String) async throws -> [DownloadTreeEntry]
    ) async throws -> DirectoryDeletePlan {
        var plan = DirectoryDeletePlan()

        func scan(remotePath: String) async throws {
            try Task.checkCancellation()
            for entry in try await list(remotePath) {
                guard entry.name != ".", entry.name != ".." else { continue }
                let childPath = remotePath == "/" ? "/\(entry.name)" : "\(remotePath)/\(entry.name)"
                switch entry.kind {
                case .directory:
                    try await scan(remotePath: childPath)
                case .file, .symlink:
                    plan.removals.append(childPath)
                }
            }
            plan.directories.append(remotePath)
        }

        try await scan(remotePath: remoteRoot)
        return plan
    }

    /// 上传前先扫描本地目录树(issue #17),与下载 plan 对称:符号链接不跟随,
    /// 避免循环与把树外目标意外上传;list 可注入便于测试。
    static func makeDirectoryUploadPlan(
        localRoot: URL,
        list: (_ url: URL) throws -> [UploadTreeEntry]
    ) throws -> DirectoryUploadPlan {
        var plan = DirectoryUploadPlan()

        func scan(url: URL, relativeComponents: [String]) throws {
            try Task.checkCancellation()
            plan.directories.append(relativeComponents)
            for entry in try list(url) {
                let childURL = url.appendingPathComponent(entry.name)
                let childComponents = relativeComponents + [entry.name]
                switch entry.kind {
                case .directory:
                    try scan(url: childURL, relativeComponents: childComponents)
                case .file:
                    plan.files.append(UploadTreeFile(
                        localURL: childURL,
                        relativeComponents: childComponents,
                        size: entry.size
                    ))
                    plan.totalBytes = saturatingAdd(plan.totalBytes, entry.size)
                case .symlink:
                    plan.skippedSymlinks += 1
                }
            }
        }

        try scan(url: localRoot, relativeComponents: [])
        return plan
    }

    /// 生产用的本地目录列举:先判符号链接(symlink 指向目录时 isDirectory 会随目标为真,
    /// 判断顺序反了就会跟着链接走);按名字排序保证顺序稳定。
    static func listLocalDirectory(_ url: URL) throws -> [UploadTreeEntry] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        return try contents.map { child in
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let kind: UploadTreeEntry.Kind = values.isSymbolicLink == true
                ? .symlink
                : (values.isDirectory == true ? .directory : .file)
            return UploadTreeEntry(
                name: child.lastPathComponent,
                kind: kind,
                size: UInt64(clamping: values.fileSize ?? 0)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 流式分块上传单个本地文件(大文件不整读进内存)。面板与终端拖拽共用。
    @discardableResult
    static func uploadLocalFile(
        _ localURL: URL,
        to remotePath: String,
        sftp: SFTPClient,
        onProgress: (_ copied: UInt64) -> Void = { _ in }
    ) async throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: localURL)
        do {
            let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let data = try handle.read(upToCount: uploadChunkSize), !data.isEmpty else { break }
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await file.write(buffer, at: offset)
                    offset += UInt64(data.count)
                    onProgress(offset)
                }
                if offset == 0 {
                    // 空文件也要建出来
                    try await file.write(ByteBufferAllocator().buffer(capacity: 0), at: 0)
                }
                try await file.close()
                try handle.close()
                return offset
            } catch {
                try? await file.close()
                try? handle.close()
                throw error
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// 递归上传整个目录:扫描出 plan → 建远端目录 → 逐文件流式上传。
    /// createDirectory 的失败不当场报错(目录可能已存在,语义是合并);
    /// 若确实建不出来,随后第一个文件写入会抛出更明确的错误。
    static func performDirectoryUpload(
        localRoot: URL,
        remoteRoot: String,
        sftp: SFTPClient,
        onPlan: (DirectoryUploadPlan) -> Void = { _ in },
        onProgress: (_ copied: UInt64, _ total: UInt64) -> Void = { _, _ in }
    ) async throws {
        let plan = try makeDirectoryUploadPlan(localRoot: localRoot, list: listLocalDirectory)
        onPlan(plan)

        for components in plan.directories {
            try Task.checkCancellation()
            let remote = components.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            try? await sftp.createDirectory(atPath: remote)
        }

        var completedBytes: UInt64 = 0
        for item in plan.files {
            try Task.checkCancellation()
            let remote = item.relativeComponents.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            let base = completedBytes
            let copied = try await uploadLocalFile(item.localURL, to: remote, sftp: sftp) { fileBytes in
                onProgress(saturatingAdd(base, fileBytes), plan.totalBytes)
            }
            completedBytes = saturatingAdd(completedBytes, copied)
        }
        onProgress(completedBytes, plan.totalBytes)
    }

    /// 上传文件或整个目录(issue #17):目录先扫描再递归,文件流式分块不整读进内存
    func upload(from localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        let transferID = beginTransfer(isDir.boolValue
            ? String(localized: "扫描 \(name)…")
            : String(localized: "上传 \(name)…"))
        defer { endTransfer(transferID) }
        do {
            if isDir.boolValue {
                try await Self.performDirectoryUpload(
                    localRoot: localURL,
                    remoteRoot: join(path, name),
                    sftp: sftp,
                    onPlan: { plan in
                        setTransfer(transferID, label: plan.skippedSymlinks > 0
                            ? String(localized: "上传 \(name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
                            : String(localized: "上传 \(name)…"))
                        setTransfer(transferID, progress: plan.totalBytes > 0 ? 0 : nil)
                    },
                    onProgress: { copied, total in
                        if total > 0 {
                            setTransfer(transferID, progress: min(1, Double(copied) / Double(total)))
                        }
                    }
                )
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
                setTransfer(transferID, progress: size > 0 ? 0 : nil)
                try await Self.uploadLocalFile(localURL, to: join(path, name), sftp: sftp) { copied in
                    if size > 0 {
                        setTransfer(transferID, progress: min(1, Double(copied) / Double(size)))
                    }
                }
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 服务端文件编辑(下载 → 本地编辑器 → 保存自动回传)

    /// 用设置里指定的编辑器打开本地临时副本;未指定(或指定的 app 已不存在)则退回
    /// LaunchServices 默认应用,与之前行为一致。
    private static func openWithPreferredEditor(_ url: URL) {
        #if canImport(AppKit)
        let customPath = UserDefaults.standard.string(forKey: SettingsKeys.externalEditorPath) ?? ""
        if !customPath.isEmpty {
            let editorURL = URL(fileURLWithPath: customPath)
            if FileManager.default.fileExists(atPath: customPath) {
                NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
        #endif
    }

    /// 正在编辑中的远端文件(远端绝对路径 → 状态),供 UI 显示角标
    private(set) var editing: [String: EditState] = [:]
    enum EditState: Equatable { case syncing, idle, failed }
    @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
    /// 已在编辑的远端路径 → 本地临时副本(供再次点击时直接重开编辑器)
    @ObservationIgnored private var editLocalURLs: [String: URL] = [:]

    /// 双击文件时:拉到本地临时目录,用默认编辑器打开,轮询本地改动自动回传到原路径。
    /// openInEditor=false 仅供自动化验收(不真的启动编辑器),返回本地临时文件路径。
    @discardableResult
    func editRemotely(_ entry: Entry, openInEditor: Bool = true) -> URL? {
        guard let sftp, !entry.isDirectory else { return nil }
        let remotePath = join(path, entry.name)
        // 已在编辑:直接重开已有本地副本,不再重复下载/新建监听
        if editTasks[remotePath] != nil {
            if let existing = editLocalURLs[remotePath], openInEditor {
                Self.openWithPreferredEditor(existing)
            }
            return editLocalURLs[remotePath]
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-edit-\(UUID().uuidString)", isDirectory: true)
        guard let localURL = try? LocalPathComponentValidator.safeURL(in: dir, component: entry.name) else {
            return nil
        }
        editLocalURLs[remotePath] = localURL

        editing[remotePath] = .syncing
        let task = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // 下载
                let file = try await sftp.openFile(filePath: remotePath, flags: .read)
                let buffer = try await file.readAll()
                try? await file.close()
                try Data(buffer.readableBytesView).write(to: localURL)
                await MainActor.run {
                    self?.editing[remotePath] = .idle
                    if openInEditor { Self.openWithPreferredEditor(localURL) }
                }
                await self?.watchAndSync(localURL: localURL, remotePath: remotePath, sftp: sftp)
            } catch {
                await MainActor.run { self?.editing[remotePath] = .failed }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        editTasks[remotePath] = task
        return localURL
    }

    /// 轮询本地文件 mtime,变化即回传(对 vim/VSCode 的原子保存-重命名也可靠)
    private func watchAndSync(localURL: URL, remotePath: String, sftp: SFTPClient) async {
        func mtime() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
        }
        var lastModified = mtime()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1200))
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            let current = mtime()
            guard current != lastModified else { continue }
            lastModified = current
            editing[remotePath] = .syncing
            do {
                let data = try Data(contentsOf: localURL)
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: 0)
                try? await file.close()
                editing[remotePath] = .idle
                if path == (remotePath as NSString).deletingLastPathComponent { await refresh() }
            } catch {
                editing[remotePath] = .failed
            }
        }
    }

    func stopEditing(_ remotePath: String) {
        editTasks[remotePath]?.cancel()
        editTasks[remotePath] = nil
        editLocalURLs[remotePath] = nil
        editing[remotePath] = nil
    }

    // MARK: - chmod / 预览 / 书签

    /// 修改权限(保留文件类型高位,仅换低 12 位)
    func chmod(_ entry: Entry, mode: UInt32) async {
        guard let sftp else { return }
        do {
            var attrs = SFTPFileAttributes()
            attrs.permissions = (entry.permissions & ~0o7777) | (mode & 0o7777)
            try await sftp.setAttributes(at: join(path, entry.name), to: attrs)
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// 快速预览:下载小文本文件(≤256KB)返回内容;过大或二进制返回 nil
    func previewText(_ entry: Entry) async -> String? {
        guard let sftp, !entry.isDirectory, entry.size <= 256 * 1024 else { return nil }
        do {
            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            let buffer = try await file.readAll()
            try? await file.close()
            let data = Data(buffer.readableBytesView)
            // 含 NUL 视为二进制
            if data.prefix(8000).contains(0) { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // 书签(常用远端目录,全局持久化)
    private static let bookmarksKey = "sftp.bookmarks"
    private(set) var bookmarks: [String] = UserDefaults.standard.stringArray(forKey: SFTPBrowser.bookmarksKey) ?? []

    func toggleBookmark() {
        if let idx = bookmarks.firstIndex(of: path) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(path)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    var isCurrentBookmarked: Bool { bookmarks.contains(path) }

    func makeDirectory(name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: join(path, name))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// 删除文件/符号链接直接 remove;目录递归删除(rmdir 只认空目录,非空必须先清内容)
    func delete(_ entry: Entry) async {
        guard let sftp else { return }
        do {
            let full = join(path, entry.name)
            if entry.isDirectory {
                let transferID = beginTransfer(String(localized: "删除 \(entry.name)…"))
                defer { endTransfer(transferID) }
                let plan = try await Self.makeDirectoryDeletePlan(remoteRoot: full) { path in
                    let names = try await sftp.listDirectory(atPath: path)
                    return names.flatMap(\.components).compactMap { component in
                        guard component.filename != ".", component.filename != ".." else { return nil }
                        let kind: DownloadTreeEntry.Kind = switch fileType(component) {
                        case .directory: .directory
                        case .symlink: .symlink
                        case .file: .file
                        }
                        return DownloadTreeEntry(
                            name: component.filename, kind: kind,
                            size: component.attributes.size ?? 0
                        )
                    }
                }
                let total = plan.removals.count + plan.directories.count
                var done = 0
                for removal in plan.removals {
                    try Task.checkCancellation()
                    try await sftp.remove(at: removal)
                    done += 1
                    setTransfer(transferID, progress: Double(done) / Double(total))
                }
                for directory in plan.directories {
                    try Task.checkCancellation()
                    try await sftp.rmdir(at: directory)
                    done += 1
                    setTransfer(transferID, progress: Double(done) / Double(total))
                }
            } else {
                try await sftp.remove(at: full)
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func rename(_ entry: Entry, to newName: String) async {
        guard let sftp, !newName.isEmpty, newName != entry.name else { return }
        do {
            try await sftp.rename(at: join(path, entry.name), to: join(path, newName))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func close() {
        isClosed = true
        for task in editTasks.values { task.cancel() }
        editTasks = [:]
        editLocalURLs = [:]
        editing = [:]
        for handler in cancellationHandlers.values { handler() }
        cancellationHandlers = [:]
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]
        let client = sftp
        sftp = nil
        Task.detached { try? await client?.close() }
    }

    // MARK: - 工具

    private enum FileType { case directory, symlink, file }

    private enum TransferError: LocalizedError {
        case sftpUnavailable

        var errorDescription: String? {
            switch self {
            case .sftpUnavailable: String(localized: "SFTP 连接不可用")
            }
        }
    }

    private func fileType(_ component: SFTPPathComponent) -> FileType {
        if let permissions = component.attributes.permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .file
            }
        }
        // permissions 缺失时看 ls -l 首字符
        switch component.longname.first {
        case "d": return .directory
        case "l": return .symlink
        default: return .file
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func friendly(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("permission") { return String(localized: "权限不足") }
        if raw.localizedCaseInsensitiveContains("noSuchFile") || raw.localizedCaseInsensitiveContains("no such") {
            return String(localized: "文件或目录不存在")
        }
        return String(localized: "SFTP 操作失败:\(raw)")
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String], directory: Bool) -> URL {
        components.enumerated().reduce(self) { url, pair in
            let (index, component) = pair
            return url.appendingPathComponent(
                component,
                isDirectory: index < components.count - 1 || directory
            )
        }
    }
}
