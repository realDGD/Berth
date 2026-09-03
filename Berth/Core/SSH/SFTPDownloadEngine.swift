import Citadel
import Foundation

/// The non-UI SFTP download engine.
///
/// SFTP is a request/response protocol, but requests are identified independently.  Keeping a
/// bounded number of READs in flight therefore lets the server and the SSH channel do useful work
/// while the previous response is being copied to disk.  The engine owns that scheduling policy so
/// callers do not accidentally create one unbounded pipeline per file.
enum SFTPDownloadEngine {

    typealias Configuration = SFTPTransferConfiguration

    struct File: Sendable, Equatable {
        let remotePath: String
        let relativeComponents: [String]
        let size: UInt64?

        init(remotePath: String, relativeComponents: [String], size: UInt64?) {
            self.remotePath = remotePath
            self.relativeComponents = relativeComponents
            self.size = size
        }
    }

    struct DirectoryEntry: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case directory, file, symlink }

        let name: String
        let kind: Kind
        let size: UInt64
        let sizeIsKnown: Bool

        init(name: String, kind: Kind, size: UInt64 = 0, sizeIsKnown: Bool = true) {
            self.name = name
            self.kind = kind
            self.size = size
            self.sizeIsKnown = sizeIsKnown
        }
    }

    struct DirectoryPlan: Sendable, Equatable {
        var directories: [[String]] = []
        var files: [File] = []
        /// `nil` means at least one file did not expose a size during the directory scan.  A
        /// partial sum must never be presented as a complete progress denominator.
        var totalBytes: UInt64? = 0
        var skippedSymlinks = 0
    }

    struct ProgressUpdate: Sendable, Equatable {
        let completedBytes: UInt64
        let totalBytes: UInt64?
        let isFinished: Bool
    }

    enum Error: Swift.Error, Equatable {
        case earlyEOF(offset: UInt64, expectedSize: UInt64)
        case invalidReadLength(requested: UInt32, received: Int)
    }

    /// Internal coordination primitive for exercising the cancellation boundary between a
    /// queued waiter being granted and that waiter confirming the grant.  It is inert unless a
    /// test explicitly installs it on a `TransferBudget`.
    internal actor GrantConfirmationGate {
        private var didReachGrant = false
        private var isArmed = true
        private var isReleased = false
        private var grantWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        /// Wait until the semaphore has resumed its waiter and the waiter is paused immediately
        /// before `confirm(_:)`.
        func waitUntilGrant() async {
            if didReachGrant { return }
            await withCheckedContinuation { continuation in
                if didReachGrant {
                    continuation.resume()
                } else {
                    grantWaiters.append(continuation)
                }
            }
        }

        /// Release the waiter paused by `waitUntilConfirmation`.  The gate is one-shot so later
        /// FIFO waiters follow the normal production path.
        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        /// Called by the resumed waiter, after `drain()` has marked it granted and resumed its
        /// continuation, but before cancellation is checked and the grant is confirmed.
        fileprivate func waitUntilConfirmation() async {
            guard isArmed else { return }
            isArmed = false
            didReachGrant = true
            let waiters = grantWaiters
            grantWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }

            if isReleased { return }
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }
    }

    /// A FIFO, cancellation-aware permit semaphore.  A single instance is owned by one SFTP
    /// session and shared by every top-level download from that session.  Normal waiters are
    /// resumed in arrival order; a cancelled waiter is removed without consuming a permit.
    private actor FIFOPermitSemaphore {
        private struct Waiter {
            let id: UInt64
            let continuation: CheckedContinuation<Void, Swift.Error>
            var granted = false
        }

        private let limit: Int
        private var inUse = 0
        private var peak = 0
        private var nextID: UInt64 = 0
        private var waiters: [UInt64: Waiter] = [:]
        private var queue: [UInt64] = []
        private var queueHead = 0
        private var grantConfirmationGate: GrantConfirmationGate?

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func acquire() async throws {
            try Task.checkCancellation()
            if inUse < limit, waiters.isEmpty {
                reserve()
                do {
                    try Task.checkCancellation()
                } catch {
                    release()
                    throw error
                }
                return
            }

            let id = allocateID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Void, Swift.Error>) in
                        enqueue(Waiter(id: id, continuation: continuation), isCancelled: Task.isCancelled)
                    }
                } onCancel: {
                    Task { await self.cancel(id) }
                }
                if let grantConfirmationGate {
                    await grantConfirmationGate.waitUntilConfirmation()
                }
                try Task.checkCancellation()
                confirm(id)
            } catch {
                cancel(id)
                throw error
            }
        }

        /// Cleanup (close) is deliberately uncancellable.  It is called only after the READ task
        /// group has drained, and must be able to obtain a slot before the remote handle is closed.
        func acquireForCleanup() async {
            if inUse < limit, waiters.isEmpty {
                reserve()
                return
            }

            let id = allocateID()
            _ = try? await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Swift.Error>) in
                enqueue(Waiter(id: id, continuation: continuation), isCancelled: false)
            }
            waiters.removeValue(forKey: id)
        }

        func release() {
            inUse = max(0, inUse - 1)
            drain()
        }

        func installGrantConfirmationGate(_ gate: GrantConfirmationGate?) {
            grantConfirmationGate = gate
        }

        var currentCount: Int { inUse }
        var peakCount: Int { peak }
        var waitingCount: Int { waiters.values.reduce(into: 0) { count, waiter in
            if !waiter.granted { count += 1 }
        } }

        private func allocateID() -> UInt64 {
            defer { nextID &+= 1 }
            return nextID
        }

        private func enqueue(_ waiter: Waiter, isCancelled: Bool) {
            if isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
            waiters[waiter.id] = waiter
            queue.append(waiter.id)
            drain()
        }

        private func reserve() {
            inUse += 1
            peak = max(peak, inUse)
        }

        private func drain() {
            while inUse < limit, queueHead < queue.count {
                let id = queue[queueHead]
                queueHead += 1
                guard var waiter = waiters[id], !waiter.granted else { continue }
                waiter.granted = true
                waiters[id] = waiter
                reserve()
                waiter.continuation.resume()
            }
            if queueHead > 64, queueHead * 2 > queue.count {
                queue.removeFirst(queueHead)
                queueHead = 0
            }
        }

        private func cancel(_ id: UInt64) {
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            if waiter.granted {
                release()
            } else {
                waiter.continuation.resume(throwing: CancellationError())
                drain()
            }
        }

        private func confirm(_ id: UInt64) {
            guard let waiter = waiters[id], waiter.granted else { return }
            waiters.removeValue(forKey: id)
        }
    }

    /// The session-level request and handle budgets.  The actor is intentionally cheap to pass
    /// through the engine; both semaphores are shared by directory listing, OPEN/FSTAT/READ/CLOSE,
    /// and all concurrently active files.
    actor TransferBudget {
        nonisolated let configuration: SFTPTransferConfiguration
        private let requests: FIFOPermitSemaphore
        private let handles: FIFOPermitSemaphore

        init(configuration: SFTPTransferConfiguration = .init()) {
            let normalized = configuration.normalized
            self.configuration = normalized
            self.requests = FIFOPermitSemaphore(limit: normalized.requestLimit)
            self.handles = FIFOPermitSemaphore(limit: normalized.handleLimit)
        }

        init(requestLimit: Int, handleLimit: Int = 16) {
            self.init(configuration: SFTPTransferConfiguration(
                requestLimit: requestLimit,
                handleLimit: handleLimit
            ))
        }

        func acquireRequest() async throws { try await requests.acquire() }
        func releaseRequest() async { await requests.release() }
        func acquireRequestForCleanup() async { await requests.acquireForCleanup() }
        /// Internal coordination hook used only by deterministic cancellation tests.
        internal func installRequestGrantConfirmationGate(_ gate: GrantConfirmationGate?) async {
            await requests.installGrantConfirmationGate(gate)
        }
        func acquireHandle() async throws { try await handles.acquire() }
        func releaseHandle() async { await handles.release() }

        var currentRequestCount: Int { get async { await requests.currentCount } }
        var currentHandleCount: Int { get async { await handles.currentCount } }
        var peakRequestCount: Int { get async { await requests.peakCount } }
        var peakHandleCount: Int { get async { await handles.peakCount } }
        /// Internal coordination hook used by deterministic cancellation tests; it exposes only
        /// queued request waiters, never the semaphore implementation itself.
        var requestWaiterCount: Int { get async { await requests.waitingCount } }
    }

    /// Throttle UI-facing progress to at most approximately ten updates per second.  A single
    /// AsyncStream consumer performs delivery, with a one-element newest-value buffer.  Producers
    /// only enqueue/coalesce from the engine actor; they never wait for a potentially slow UI
    /// actor. `finish()` closes the stream and awaits that one task, so the final event is ordered
    /// before the public operation returns without creating one unstructured task per READ.
    private actor ProgressAccumulator {
        private var totalBytes: UInt64?
        private var unresolvedFileSizes: Int
        private var observedKnownTotal: UInt64 = 0
        private let sink: @Sendable (ProgressUpdate) async -> Void
        private let streamContinuation: AsyncStream<ProgressUpdate>.Continuation
        private let deliveryTask: Task<Void, Never>
        private var completedBytes: UInt64 = 0
        private var lastEmissionNanos: UInt64 = 0
        private var isClosed = false

        init(
            totalBytes: UInt64?,
            unresolvedFileSizes: Int,
            sink: @escaping @Sendable (ProgressUpdate) async -> Void
        ) {
            self.totalBytes = totalBytes
            self.unresolvedFileSizes = max(0, unresolvedFileSizes)
            self.sink = sink

            var continuation: AsyncStream<ProgressUpdate>.Continuation!
            let stream = AsyncStream<ProgressUpdate>(bufferingPolicy: .bufferingNewest(1)) {
                continuation = $0
            }
            self.streamContinuation = continuation
            self.deliveryTask = Task {
                for await update in stream {
                    await sink(update)
                }
            }
        }

        func emitInitial() {
            enqueue(ProgressUpdate(completedBytes: 0, totalBytes: totalBytes, isFinished: false))
            lastEmissionNanos = DispatchTime.now().uptimeNanoseconds
        }

        /// Record the size observed by FSTAT for one opened file.  For an initially complete
        /// directory total, adjust the denominator by the snapshot-vs-listing delta.  If scanning
        /// found an unknown file, publish a total only after every file has an effective size.
        func observeFileSize(listedSize: UInt64?, snapshotSize: UInt64?) {
            if let totalBytes {
                if let listedSize, let snapshotSize {
                    self.totalBytes = adjustedTotal(
                        totalBytes,
                        listedSize: listedSize,
                        snapshotSize: snapshotSize
                    )
                    enqueueCurrent()
                }
                return
            }

            guard unresolvedFileSizes > 0 else { return }
            guard let effectiveSize = snapshotSize ?? listedSize else {
                // This file will use the EOF-terminated fallback; the directory denominator
                // remains unknown because no future value can be inferred safely.
                return
            }
            observedKnownTotal = saturatingAdd(observedKnownTotal, effectiveSize)
            unresolvedFileSizes -= 1
            if unresolvedFileSizes == 0 {
                totalBytes = observedKnownTotal
            }
            enqueueCurrent()
        }

        func add(_ bytes: UInt64) {
            completedBytes = saturatingAdd(completedBytes, bytes)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- lastEmissionNanos >= 100_000_000 else { return }
            enqueueCurrent()
            lastEmissionNanos = now
        }

        func finish() async {
            guard !isClosed else {
                await deliveryTask.value
                return
            }
            isClosed = true
            streamContinuation.yield(ProgressUpdate(
                completedBytes: totalBytes ?? completedBytes,
                totalBytes: totalBytes,
                isFinished: true
            ))
            streamContinuation.finish()
            await deliveryTask.value
        }

        /// End delivery after a failed/cancelled transfer.  There is intentionally no misleading
        /// `isFinished` progress event, but the already queued UI update is still drained.
        func cancelDelivery() async {
            guard !isClosed else {
                await deliveryTask.value
                return
            }
            isClosed = true
            streamContinuation.finish()
            await deliveryTask.value
        }

        private func enqueueCurrent() {
            enqueue(ProgressUpdate(
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                isFinished: false
            ))
        }

        private func enqueue(_ update: ProgressUpdate) {
            guard !isClosed else { return }
            streamContinuation.yield(update)
        }

        private func adjustedTotal(
            _ total: UInt64,
            listedSize: UInt64,
            snapshotSize: UInt64
        ) -> UInt64 {
            if snapshotSize >= listedSize {
                return saturatingAdd(total, snapshotSize - listedSize)
            }
            let decrease = listedSize - snapshotSize
            return total >= decrease ? total - decrease : 0
        }
    }

    private struct ReadRange: Sendable {
        let offset: UInt64
        let length: UInt32
    }

    private struct ReadResult: Sendable {
        let range: ReadRange
        let data: Data
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private static func withRequest<R: Sendable>(
        _ budget: TransferBudget,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        try await budget.acquireRequest()
        do {
            let result = try await operation()
            await budget.releaseRequest()
            return result
        } catch {
            await budget.releaseRequest()
            throw error
        }
    }

    private static func withCleanupRequest<R: Sendable>(
        _ budget: TransferBudget,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        await budget.acquireRequestForCleanup()
        do {
            let result = try await operation()
            await budget.releaseRequest()
            return result
        } catch {
            await budget.releaseRequest()
            throw error
        }
    }

    private static func withDirectoryList(
        _ path: String,
        budget: TransferBudget,
        list: @escaping @Sendable (String) async throws -> [DirectoryEntry]
    ) async throws -> [DirectoryEntry] {
        // listDirectory internally owns an OPENDIR handle until the call returns.  Holding a handle
        // permit across the whole operation makes that lifetime part of the same global budget.
        try await budget.acquireHandle()
        do {
            let result = try await withRequest(budget) { try await list(path) }
            await budget.releaseHandle()
            return result
        } catch {
            await budget.releaseHandle()
            throw error
        }
    }

    /// Scan a remote tree breadth-first with a bounded number of concurrent OPENDIR operations.
    /// Results are sorted before being added to the plan so completion order cannot change local
    /// layout or make tests/non-deterministic retries differ.
    static func makeDirectoryDownloadPlan(
        remoteRoot: String,
        budget: TransferBudget,
        configuration: Configuration = .init(),
        list: @escaping @Sendable (String) async throws -> [DirectoryEntry]
    ) async throws -> DirectoryPlan {
        let configuration = configuration.normalized

        struct PendingDirectory: Sendable {
            let remotePath: String
            let relativeComponents: [String]
        }
        struct ListedDirectory: Sendable {
            let pending: PendingDirectory
            let entries: [DirectoryEntry]
        }

        var pending = [PendingDirectory(remotePath: remoteRoot, relativeComponents: [])]
        var plan = DirectoryPlan()

        while !pending.isEmpty {
            let batchCount = min(configuration.maxConcurrentDirectories, pending.count)
            let batch = Array(pending.prefix(batchCount))
            pending.removeFirst(batchCount)

            var listed: [ListedDirectory] = []
            try await withThrowingTaskGroup(of: ListedDirectory.self) { group in
                for item in batch {
                    group.addTask {
                        let entries = try await withDirectoryList(item.remotePath, budget: budget, list: list)
                        return ListedDirectory(pending: item, entries: entries)
                    }
                }
                while let result = try await group.next() {
                    listed.append(result)
                }
            }

            listed.sort {
                $0.pending.relativeComponents.map { $0 }.joined(separator: "/")
                    < $1.pending.relativeComponents.map { $0 }.joined(separator: "/")
            }
            for result in listed {
                plan.directories.append(result.pending.relativeComponents)
                for entry in result.entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    try Task.checkCancellation()
                    guard entry.name != ".", entry.name != ".." else { continue }
                    let childPath = appendRemotePath(result.pending.remotePath, entry.name)
                    let childComponents = result.pending.relativeComponents + [entry.name]
                    switch entry.kind {
                    case .directory:
                        pending.append(PendingDirectory(remotePath: childPath, relativeComponents: childComponents))
                    case .file:
                        plan.files.append(File(
                            remotePath: childPath,
                            relativeComponents: childComponents,
                            size: entry.sizeIsKnown ? entry.size : nil
                        ))
                        if entry.sizeIsKnown, let totalBytes = plan.totalBytes {
                            plan.totalBytes = saturatingAdd(totalBytes, entry.size)
                        } else if !entry.sizeIsKnown {
                            plan.totalBytes = nil
                        }
                    case .symlink:
                        plan.skippedSymlinks += 1
                    }
                }
            }
        }
        return plan
    }

    /// Download a tree after scanning it.  At most maxConcurrentFiles files are active, while the
    /// shared budget caps the aggregate READ/OPEN/CLOSE operations across those files.
    @discardableResult
    static func downloadDirectory(
        remoteRoot: String,
        localRoot: URL,
        sftp: SFTPClient,
        budget: TransferBudget? = nil,
        configuration: Configuration = .init(),
        onPlan: @escaping @Sendable (DirectoryPlan) async -> Void = { _ in },
        onProgress: @escaping @Sendable (ProgressUpdate) async -> Void = { _ in }
    ) async throws -> DirectoryPlan {
        let configuration = configuration.normalized
        let budget = budget ?? TransferBudget(configuration: configuration)
        let plan = try await makeDirectoryDownloadPlan(
            remoteRoot: remoteRoot,
            budget: budget,
            configuration: configuration
        ) { path in
            let names = try await sftp.listDirectory(atPath: path)
            return names.flatMap(\.components).compactMap { component in
                guard component.filename != ".", component.filename != ".." else { return nil }
                let kind: DirectoryEntry.Kind
                if let permissions = component.attributes.permissions {
                    switch permissions & 0o170000 {
                    case 0o040000: kind = .directory
                    case 0o120000: kind = .symlink
                    default: kind = .file
                    }
                } else {
                    kind = component.longname.first == "d" ? .directory
                        : (component.longname.first == "l" ? .symlink : .file)
                }
                return DirectoryEntry(
                    name: component.filename,
                    kind: kind,
                    size: component.attributes.size ?? 0,
                    sizeIsKnown: component.attributes.size != nil
                )
            }
        }

        await onPlan(plan)
        let reporter = ProgressAccumulator(
            totalBytes: plan.totalBytes,
            unresolvedFileSizes: plan.totalBytes == nil ? plan.files.count : 0,
            sink: onProgress
        )
        await reporter.emitInitial()

        do {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            for components in plan.directories {
                try Task.checkCancellation()
                let destination = components.reduce(localRoot) { $0.appendingPathComponent($1, isDirectory: true) }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }

            try await downloadFiles(
                plan.files,
                localRoot: localRoot,
                sftp: sftp,
                configuration: configuration,
                budget: budget,
                reporter: reporter
            )
            await reporter.finish()
            return plan
        } catch {
            await reporter.cancelDelivery()
            throw error
        }
    }

    /// Download one file.  A known size uses the pipelined path and never asks for an extra EOF
    /// packet.  Unknown-size files retain the conservative sequential EOF-terminated path.
    @discardableResult
    static func downloadFile(
        remotePath: String,
        expectedSize: UInt64?,
        localURL: URL,
        sftp: SFTPClient,
        budget: TransferBudget? = nil,
        configuration: Configuration = .init(),
        onProgress: @escaping @Sendable (ProgressUpdate) async -> Void = { _ in }
    ) async throws -> UInt64 {
        let configuration = configuration.normalized
        let budget = budget ?? TransferBudget(configuration: configuration)
        let reporter = ProgressAccumulator(
            totalBytes: expectedSize,
            unresolvedFileSizes: expectedSize == nil ? 1 : 0,
            sink: onProgress
        )
        await reporter.emitInitial()
        do {
            let copied = try await downloadOpenedFile(
                remotePath: remotePath,
                expectedSize: expectedSize,
                localURL: localURL,
                sftp: sftp,
                configuration: configuration,
                budget: budget,
                reporter: reporter
            )
            await reporter.finish()
            return copied
        } catch {
            await reporter.cancelDelivery()
            throw error
        }
    }

    private static func downloadFiles(
        _ files: [File],
        localRoot: URL,
        sftp: SFTPClient,
        configuration: Configuration,
        budget: TransferBudget,
        reporter: ProgressAccumulator
    ) async throws {
        guard !files.isEmpty else { return }
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            var nextIndex = 0
            var active = 0

            while nextIndex < files.count || active > 0 {
                while active < configuration.maxConcurrentFiles, nextIndex < files.count {
                    try Task.checkCancellation()
                    let item = files[nextIndex]
                    nextIndex += 1
                    active += 1
                    let localURL = item.relativeComponents.reduce(localRoot) {
                        $0.appendingPathComponent($1, isDirectory: false)
                    }
                    group.addTask {
                        try await downloadOpenedFile(
                            remotePath: item.remotePath,
                            expectedSize: item.size,
                            localURL: localURL,
                            sftp: sftp,
                            configuration: configuration,
                            budget: budget,
                            reporter: reporter
                        )
                    }
                }

                if active > 0 {
                    _ = try await group.next()
                    active -= 1
                }
            }
        }
    }

    private static func downloadOpenedFile(
        remotePath: String,
        expectedSize: UInt64?,
        localURL: URL,
        sftp: SFTPClient,
        configuration: Configuration,
        budget: TransferBudget,
        reporter: ProgressAccumulator
    ) async throws -> UInt64 {
        return try await downloadOpenedFileLifecycle(
            expectedSize: expectedSize,
            localURL: localURL,
            chunkSize: readChunkSize(for: sftp, configuration: configuration),
            configuration: configuration,
            budget: budget,
            open: {
                try await sftp.openFile(filePath: remotePath, flags: .read)
            },
            snapshot: { file in
                try await file.readAttributes().size
            },
            read: { file, offset, length in
                let buffer = try await file.read(from: offset, length: length)
                return Data(buffer.readableBytesView)
            },
            close: { file in
                try await file.close()
            },
            onFileSize: { listedSize, snapshotSize in
                await reporter.observeFileSize(listedSize: listedSize, snapshotSize: snapshotSize)
            },
            onBytes: { bytes in await reporter.add(bytes) }
        )
    }

    /// The resource-lifecycle seam used by production and deterministic tests.  The SFTP-specific
    /// adapter above supplies OPEN/FSTAT/READ/CLOSE; this function owns the ordering and budgets so
    /// a cancelled transfer cannot close an open handle until every in-flight READ has drained.
    static func downloadOpenedFileLifecycle<RemoteHandle: Sendable>(
        expectedSize: UInt64?,
        localURL: URL,
        chunkSize: UInt32,
        configuration: Configuration = .init(),
        budget: TransferBudget,
        open: @escaping @Sendable () async throws -> RemoteHandle,
        snapshot: @escaping @Sendable (RemoteHandle) async throws -> UInt64?,
        read: @escaping @Sendable (RemoteHandle, UInt64, UInt32) async throws -> Data,
        close: @escaping @Sendable (RemoteHandle) async throws -> Void,
        onFileSize: @escaping @Sendable (UInt64?, UInt64?) async -> Void = { _, _ in },
        onBytes: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) async throws -> UInt64 {
        let configuration = configuration.normalized
        try Task.checkCancellation()
        try await budget.acquireHandle()

        var openedHandle: RemoteHandle? = nil
        var remoteClosed = false
        do {
            let handle = try await withRequest(budget) {
                try await open()
            }
            openedHandle = handle

            // FSTAT happens after OPEN and before any READ scheduling.  If the listing supplied a
            // hint, it remains only as a fallback for a server that omits the size attribute.
            try Task.checkCancellation()
            let snapshotSize = try await withRequest(budget) {
                try await snapshot(handle)
            }
            let size = snapshotSize ?? expectedSize
            await onFileSize(expectedSize, snapshotSize)

            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.createFile(atPath: localURL.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            let localHandle = try FileHandle(forWritingTo: localURL)
            let copied: UInt64
            do {
                try localHandle.truncate(atOffset: 0)
                let readAtOffset: @Sendable (UInt64, UInt32) async throws -> Data = { offset, length in
                    try await read(handle, offset, length)
                }
                let writeAtOffset: @Sendable (Data, UInt64) throws -> Void = { data, offset in
                    try localHandle.seek(toOffset: offset)
                    try localHandle.write(contentsOf: data)
                }
                let activeHandles = await budget.currentHandleCount
                let activeRequests = await budget.currentRequestCount
                DebugLog.append("sftp file start name=\(localURL.lastPathComponent) size=\(size ?? 0) activeHandles=\(activeHandles) activeRequests=\(activeRequests)")
                if let size {
                    copied = try await copyKnownSize(
                        expectedSize: size,
                        chunkSize: chunkSize,
                        initialPipelineDepth: configuration.initialPipelineDepth,
                        maxPipelineDepth: configuration.maxPipelineDepth,
                        budget: budget,
                        read: readAtOffset,
                        write: writeAtOffset,
                        onBytes: onBytes
                    )
                    try localHandle.truncate(atOffset: size)
                } else {
                    copied = try await copyUnknownSize(
                        chunkSize: chunkSize,
                        budget: budget,
                        read: readAtOffset,
                        write: writeAtOffset,
                        onBytes: onBytes
                    )
                }
                try localHandle.close()
                DebugLog.append("sftp file done name=\(localURL.lastPathComponent) copied=\(copied)")
            } catch {
                try? localHandle.close()
                DebugLog.append("sftp file failed name=\(localURL.lastPathComponent) error=\(error)")
                throw error
            }

            // copyKnownSize/copyUnknownSize have drained their structured task groups here.  The
            // remote CLOSE is therefore the first request after every in-flight READ completes.
            try await withCleanupRequest(budget) {
                try await close(handle)
            }
            remoteClosed = true
            await budget.releaseHandle()
            return copied
        } catch {
            if let openedHandle, !remoteClosed {
                // Cleanup deliberately obtains a non-cancellable request slot.  The close is
                // awaited before this lifecycle function releases the handle permit or rethrows.
                try? await withCleanupRequest(budget) {
                    try await close(openedHandle)
                }
            }
            await budget.releaseHandle()
            throw error
        }
    }

    private static func readChunkSize(for sftp: SFTPClient, configuration: Configuration) -> UInt32 {
        // limits@openssh.com is deliberately left for a follow-up vendor change.  Keep the
        // interoperable OpenSSH fallback here and make it configurable only for deterministic tests.
        _ = sftp
        return UInt32(clamping: max(1, configuration.fallbackChunkSize))
    }

    /// Pipeline a known-size file.  Responses are intentionally consumed in completion order and
    /// written at their recorded offsets, so a server may legally return DATA packets out of order.
    /// A short DATA response queues the unfilled tail of that range; only an empty response before
    /// the expected size is treated as an early EOF error.
    @discardableResult
    static func copyKnownSize(
        expectedSize: UInt64,
        chunkSize: UInt32,
        initialPipelineDepth: Int = 2,
        maxPipelineDepth: Int = 8,
        budget: TransferBudget? = nil,
        read: @escaping @Sendable (UInt64, UInt32) async throws -> Data,
        write: @escaping @Sendable (Data, UInt64) throws -> Void,
        onBytes: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) async throws -> UInt64 {
        guard expectedSize > 0 else { return 0 }
        precondition(chunkSize > 0)
        let initialDepth = max(1, initialPipelineDepth)
        let maximumDepth = max(initialDepth, maxPipelineDepth)
        // Only the active window and short-read remainders are retained.  In particular, do not
        // materialize one ReadRange per chunk: a multi-terabyte file must have the same scheduler
        // memory footprint as a small file.
        var nextOffset: UInt64 = 0
        var pendingRemainders: [ReadRange] = []
        var inFlight = 0
        var depth = initialDepth
        // Servers commonly cap a DATA response below the requested length.  Once that is
        // observed, use the returned size as the upper bound for future requests.  Keep a small
        // floor so a pathological one-byte short read cannot collapse the pipeline into needless
        // single-byte requests; outstanding ranges still complete at their original offsets.
        let minimumChunkSize = max(1, min(chunkSize / 4, UInt32(4 * 1024)))
        var effectiveChunkSize = chunkSize
        var copied: UInt64 = 0

        try await withThrowingTaskGroup(of: ReadResult.self) { group in
            func nextRange() -> ReadRange? {
                if let remainder = pendingRemainders.popLast() {
                    let length = min(effectiveChunkSize, remainder.length)
                    if length < remainder.length {
                        pendingRemainders.append(ReadRange(
                            offset: remainder.offset + UInt64(length),
                            length: remainder.length - length
                        ))
                    }
                    return ReadRange(offset: remainder.offset, length: length)
                }
                guard nextOffset < expectedSize else { return nil }
                let remaining = expectedSize - nextOffset
                let length = UInt32(min(UInt64(effectiveChunkSize), remaining))
                let range = ReadRange(offset: nextOffset, length: length)
                nextOffset += UInt64(length)
                return range
            }

            func schedule() throws {
                while inFlight < depth {
                    try Task.checkCancellation()
                    guard let range = nextRange() else { return }
                    inFlight += 1
                    group.addTask {
                        let data: Data
                        if let budget {
                            data = try await withRequest(budget) {
                                try await read(range.offset, range.length)
                            }
                        } else {
                            data = try await read(range.offset, range.length)
                        }
                        return ReadResult(range: range, data: data)
                    }
                }
            }

            try schedule()
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1
                let received = result.data.count
                guard received > 0 else {
                    throw Error.earlyEOF(offset: result.range.offset, expectedSize: expectedSize)
                }
                guard received <= Int(result.range.length) else {
                    throw Error.invalidReadLength(requested: result.range.length, received: received)
                }

                try write(result.data, result.range.offset)
                copied = saturatingAdd(copied, UInt64(received))
                await onBytes(UInt64(received))

                if received < Int(result.range.length) {
                    let receivedLength = UInt32(received)
                    effectiveChunkSize = max(
                        minimumChunkSize,
                        min(effectiveChunkSize, max(minimumChunkSize, receivedLength))
                    )
                    // Keep one interval for the missing tail; nextRange() splits it lazily at the
                    // current effective size.  Thus the remainder queue stays proportional to the
                    // active window even when every response is short.
                    pendingRemainders.append(ReadRange(
                        offset: result.range.offset + UInt64(received),
                        length: result.range.length - receivedLength
                    ))
                } else if depth < maximumDepth {
                    // Like OpenSSH, ramp up only after a complete response.  Short reads often
                    // indicate a server-side packet cap and should not increase pressure.
                    depth += 1
                    DebugLog.append("sftp pipeline ramp depth=\(depth) max=\(maximumDepth) offset=\(result.range.offset)")
                }
                try schedule()
            }
        }
        guard copied == expectedSize else {
            throw Error.earlyEOF(offset: copied, expectedSize: expectedSize)
        }
        return copied
    }

    /// Sequential unknown-size fallback.  A short non-empty read is data, not EOF; only an empty
    /// DATA response marks completion.
    @discardableResult
    static func copyUnknownSize(
        chunkSize: UInt32,
        budget: TransferBudget? = nil,
        read: @escaping @Sendable (UInt64, UInt32) async throws -> Data,
        write: @escaping @Sendable (Data, UInt64) throws -> Void,
        onBytes: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) async throws -> UInt64 {
        precondition(chunkSize > 0)
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let readOffset = offset
            let data: Data
            if let budget {
                data = try await withRequest(budget) {
                    try await read(readOffset, chunkSize)
                }
            } else {
                data = try await read(readOffset, chunkSize)
            }
            guard !data.isEmpty else { return offset }
            guard data.count <= Int(chunkSize) else {
                throw Error.invalidReadLength(requested: chunkSize, received: data.count)
            }
            try write(data, offset)
            offset = saturatingAdd(offset, UInt64(data.count))
            await onBytes(UInt64(data.count))
        }
    }

    private static func appendRemotePath(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

private extension Int {
    static var UInt32MaxAsInt: Int { Int(UInt32.max) }
}
