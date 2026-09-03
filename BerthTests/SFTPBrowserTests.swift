import XCTest
@testable import Berth

private final class SFTPLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class SFTPBrowserTests: XCTestCase {

    /// 递归删除:文件与符号链接先删(链接删自身),目录按最深优先,root 最后
    func testDirectoryDeletePlanOrdersDeepestFirst() async throws {
        typealias Item = SFTPBrowser.DownloadTreeEntry
        let tree: [String: [Item]] = [
            "/srv/junk": [
                Item(name: "a.txt", kind: .file, size: 1),
                Item(name: "link", kind: .symlink, size: 1),
                Item(name: "sub", kind: .directory, size: 0),
            ],
            "/srv/junk/sub": [
                Item(name: "deep", kind: .directory, size: 0),
                Item(name: "b.txt", kind: .file, size: 1),
            ],
            "/srv/junk/sub/deep": [],
        ]

        let plan = try await SFTPBrowser.makeDirectoryDeletePlan(remoteRoot: "/srv/junk") { path in
            tree[path] ?? []
        }

        XCTAssertEqual(plan.removals, ["/srv/junk/a.txt", "/srv/junk/link", "/srv/junk/sub/b.txt"])
        XCTAssertEqual(plan.directories, ["/srv/junk/sub/deep", "/srv/junk/sub", "/srv/junk"])
    }

    func testDirectoryUploadPlanRecursesAndSkipsSymlinks() throws {
        typealias Item = SFTPBrowser.UploadTreeEntry
        let root = URL(fileURLWithPath: "/local/project")
        let tree: [String: [Item]] = [
            "/local/project": [
                Item(name: "README.md", kind: .file, size: 12),
                Item(name: "empty", kind: .directory, size: 0),
                Item(name: "link", kind: .symlink, size: 8),
                Item(name: "nested", kind: .directory, size: 0),
            ],
            "/local/project/empty": [],
            "/local/project/nested": [
                Item(name: "data.bin", kind: .file, size: 32),
                Item(name: "deeper", kind: .directory, size: 0),
            ],
            "/local/project/nested/deeper": [
                Item(name: "zero", kind: .file, size: 0),
            ],
        ]
        var listedPaths: [String] = []

        let plan = try SFTPBrowser.makeDirectoryUploadPlan(localRoot: root) { url in
            listedPaths.append(url.path)
            return tree[url.path] ?? []
        }

        XCTAssertEqual(listedPaths, [
            "/local/project",
            "/local/project/empty",
            "/local/project/nested",
            "/local/project/nested/deeper",
        ])
        XCTAssertEqual(plan.directories, [[], ["empty"], ["nested"], ["nested", "deeper"]])
        XCTAssertEqual(plan.files.map(\.relativeComponents), [
            ["README.md"],
            ["nested", "data.bin"],
            ["nested", "deeper", "zero"],
        ])
        XCTAssertEqual(plan.files.map(\.localURL.path), [
            "/local/project/README.md",
            "/local/project/nested/data.bin",
            "/local/project/nested/deeper/zero",
        ])
        XCTAssertEqual(plan.totalBytes, 44)
        XCTAssertEqual(plan.skippedSymlinks, 1)
    }

    /// 真实文件系统:symlink 指向目录时 isDirectory 会随目标为真,必须先判 symlink,
    /// 否则会跟着链接把树外内容传上去(甚至循环)。
    func testListLocalDirectoryClassifiesSymlinkBeforeDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-upload-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dirlink"),
            withDestinationURL: sub
        )

        let entries = try SFTPBrowser.listLocalDirectory(root)

        XCTAssertEqual(entries.map(\.name), ["a.txt", "dirlink", "sub"])
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.kind, .file)
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.size, 5)
        XCTAssertEqual(entries.first { $0.name == "dirlink" }?.kind, .symlink)
        XCTAssertEqual(entries.first { $0.name == "sub" }?.kind, .directory)
    }

    /// SFTP 服务端通常把大 read 拆成几十 KB 的短包;只有空包才是 EOF。
    func testChunkCopyContinuesAfterShortRead() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let serverPacketSize = 32 * 1024
        let readOffsets = SFTPLockedValue<[UInt64]>([])
        let downloaded = SFTPLockedValue<Data>(Data())

        let copied = try await SFTPDownloadEngine.copyUnknownSize(
            chunkSize: UInt32(256 * 1024),
            read: { offset, requestedLength in
                readOffsets.withValue { $0.append(offset) }
                let start = Int(offset)
                guard start < payload.count else { return Data() }
                let count = min(serverPacketSize, Int(requestedLength), payload.count - start)
                return payload.subdata(in: start..<(start + count))
            },
            write: { data, _ in downloaded.withValue { $0.append(data) } }
        )

        XCTAssertEqual(downloaded.snapshot(), payload)
        XCTAssertEqual(copied, UInt64(payload.count))
        let offsets = readOffsets.snapshot()
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(offsets.last, UInt64(payload.count), "完整写入后还应再读一次空包确认 EOF")
        XCTAssertGreaterThan(offsets.count, 2, "首个短包后不能提前结束")
    }

    func testKnownSizePipelineWritesOutOfOrderResponsesAtTheirOffsets() async throws {
        let payload = Data((0..<100).map { UInt8($0) })
        let writes = SFTPLockedValue<[UInt64: Data]>([:])

        let copied = try await SFTPDownloadEngine.copyKnownSize(
            expectedSize: UInt64(payload.count),
            chunkSize: 25,
            initialPipelineDepth: 4,
            maxPipelineDepth: 4,
            read: { offset, length in
                // Deliberately make higher offsets complete first.
                try await Task.sleep(for: .milliseconds(5 * Int((100 - offset) / 25)))
                let start = Int(offset)
                let count = min(Int(length), payload.count - start)
                return payload.subdata(in: start..<(start + count))
            },
            write: { data, offset in writes.withValue { $0[offset] = data } }
        )

        XCTAssertEqual(copied, 100)
        let written = writes.snapshot()
        XCTAssertEqual(written.keys.sorted(), [0, 25, 50, 75])
        XCTAssertEqual(Data(written.sorted { $0.key < $1.key }.flatMap(\.value)), payload)
    }

    func testKnownSizePipelineLazilySchedulesHugeFile() async throws {
        actor Probe {
            var calls = 0
            func record() { calls += 1 }
            var count: Int { calls }
        }
        let probe = Probe()

        do {
            _ = try await SFTPDownloadEngine.copyKnownSize(
                expectedSize: UInt64.max,
                chunkSize: 64,
                initialPipelineDepth: 2,
                maxPipelineDepth: 2,
                read: { _, length in
                    await probe.record()
                    return Data(repeating: 0, count: Int(length) + 1)
                },
                write: { _, _ in }
            )
            XCTFail("expected invalid read length")
        } catch let error as SFTPDownloadEngine.Error {
            XCTAssertEqual(error, .invalidReadLength(requested: 64, received: 65))
        }

        // A pre-generated range array would attempt to create UInt64.max / 64 entries.  The
        // lazy scheduler dispatches only the configured initial window before the first error.
        let calls = await probe.count
        XCTAssertLessThanOrEqual(calls, 2)
    }

    func testKnownSizePipelineRefillsShortReadsWithoutAnExtraEOFRead() async throws {
        let payload = Data((0..<53).map { UInt8($0 % 251) })
        let offsets = SFTPLockedValue<[UInt64]>([])
        let requestedLengths = SFTPLockedValue<[UInt32]>([])
        let writes = SFTPLockedValue<[UInt64: Data]>([:])

        let copied = try await SFTPDownloadEngine.copyKnownSize(
            expectedSize: UInt64(payload.count),
            chunkSize: 32,
            initialPipelineDepth: 2,
            maxPipelineDepth: 2,
            read: { offset, requestedLength in
                offsets.withValue { $0.append(offset) }
                requestedLengths.withValue { $0.append(requestedLength) }
                let start = Int(offset)
                guard start < payload.count else { return Data() }
                let count = min(7, Int(requestedLength), payload.count - start)
                return payload.subdata(in: start..<(start + count))
            },
            write: { data, offset in writes.withValue { $0[offset] = data } }
        )

        XCTAssertEqual(copied, UInt64(payload.count))
        let written = writes.snapshot()
        XCTAssertEqual(written.values.reduce(0) { $0 + $1.count }, payload.count)
        XCTAssertEqual(Data(written.sorted { $0.key < $1.key }.flatMap(\.value)), payload)
        let requestedOffsets = offsets.snapshot()
        XCTAssertFalse(requestedOffsets.contains(UInt64(payload.count)), "已知大小不应额外发送 EOF READ")
        XCTAssertGreaterThan(requestedOffsets.count, 2)
        XCTAssertTrue(requestedLengths.snapshot().contains(8), "短读后后续 READ 应降低到自适应 chunk")
    }

    func testKnownSizePipelineReportsEarlyEOF() async throws {
        do {
            _ = try await SFTPDownloadEngine.copyKnownSize(
                expectedSize: 40,
                chunkSize: 16,
                initialPipelineDepth: 1,
                maxPipelineDepth: 1,
                read: { offset, length in
                    guard offset < 20 else { return Data() }
                    return Data(repeating: 0xA5, count: min(Int(length), 10))
                },
                write: { _, _ in }
            )
            XCTFail("expected early EOF")
        } catch let error as SFTPDownloadEngine.Error {
            guard case let .earlyEOF(offset, expectedSize) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expectedSize, 40)
            XCTAssertGreaterThanOrEqual(offset, 20)
            XCTAssertLessThan(offset, 40)
        }
    }

    func testGlobalRequestBudgetLimitsConcurrentPipelines() async throws {
        actor Probe {
            var active = 0
            var peak = 0

            func enter() {
                active += 1
                peak = max(peak, active)
            }

            func leave() { active -= 1 }
            var maximum: Int { peak }
        }

        let budget = SFTPDownloadEngine.TransferBudget(requestLimit: 3, handleLimit: 8)
        let probe = Probe()
        let payload = Data(repeating: 0x4D, count: 64)

        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await SFTPDownloadEngine.copyKnownSize(
                        expectedSize: UInt64(payload.count),
                        chunkSize: 16,
                        initialPipelineDepth: 4,
                        maxPipelineDepth: 4,
                        budget: budget,
                        read: { offset, length in
                            await probe.enter()
                            try await Task.sleep(for: .milliseconds(2))
                            await probe.leave()
                            return payload.subdata(in: Int(offset)..<Int(offset) + Int(length))
                        },
                        write: { _, _ in }
                    )
                }
            }
            while let _ = try await group.next() {}
        }

        let requestPeak = await probe.maximum
        let budgetRequestPeak = await budget.peakRequestCount
        let requestsRemaining = await budget.currentRequestCount
        XCTAssertLessThanOrEqual(requestPeak, 3)
        XCTAssertLessThanOrEqual(budgetRequestPeak, 3)
        XCTAssertEqual(requestsRemaining, 0)
    }

    func testDirectoryScanUsesBoundedConcurrentListings() async throws {
        actor Probe {
            var active = 0
            var peak = 0
            func enter() { active += 1; peak = max(peak, active) }
            func leave() { active -= 1 }
            var maximum: Int { peak }
        }

        let probe = Probe()
        let budget = SFTPDownloadEngine.TransferBudget(requestLimit: 16, handleLimit: 2)
        let tree: [String: [SFTPDownloadEngine.DirectoryEntry]] = [
            "/root": (0..<6).map {
                .init(name: "dir\($0)", kind: .directory)
            },
        ]
        var mutableTree = tree
        for index in 0..<6 {
            mutableTree["/root/dir\(index)"] = [
                .init(name: "file.bin", kind: .file, size: 3),
            ]
        }

        let directoryTree = mutableTree
        let plan = try await SFTPDownloadEngine.makeDirectoryDownloadPlan(
            remoteRoot: "/root",
            budget: budget,
            configuration: .init(maxConcurrentDirectories: 2)
        ) { path in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(2))
            let result = directoryTree[path] ?? []
            await probe.leave()
            return result
        }

        XCTAssertEqual(plan.files.count, 6)
        let listingPeak = await probe.maximum
        let budgetHandlePeak = await budget.peakHandleCount
        let handlesRemaining = await budget.currentHandleCount
        XCTAssertLessThanOrEqual(listingPeak, 2)
        XCTAssertLessThanOrEqual(budgetHandlePeak, 2)
        XCTAssertEqual(handlesRemaining, 0)
    }

    func testRequestBudgetFIFOHandlesCancellationBeforeAndAfterGrant() async throws {
        actor Recorder {
            var labels: [String] = []
            func append(_ label: String) { labels.append(label) }
            var snapshot: [String] { labels }
        }

        let budget = SFTPDownloadEngine.TransferBudget(requestLimit: 1, handleLimit: 1)
        let recorder = Recorder()
        try await budget.acquireRequest() // Keep the first permit occupied while waiters queue.

        let first = Task {
            try await budget.acquireRequest()
            await recorder.append("first")
            await budget.releaseRequest()
        }
        let second = Task {
            try await budget.acquireRequest()
            await recorder.append("second")
            await budget.releaseRequest()
        }

        var queued = false
        for _ in 0..<1_000 {
            if await budget.requestWaiterCount == 2 {
                queued = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(queued, "both FIFO waiters must be observable before releasing the holder")
        first.cancel()

        var firstRemoved = false
        for _ in 0..<1_000 {
            if await budget.requestWaiterCount == 1 {
                firstRemoved = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(firstRemoved, "cancelling a queued waiter must remove it before grant")
        await budget.releaseRequest()

        do {
            _ = try await first.value
            XCTFail("cancelled FIFO waiter should not acquire a permit")
        } catch is CancellationError {
            // expected
        }
        try await second.value
        let labelsAfterQueuedCancel = await recorder.snapshot
        XCTAssertEqual(labelsAfterQueuedCancel, ["second"], "FIFO must skip the cancelled waiter")
        let requestCountAfterQueuedCancel = await budget.currentRequestCount
        XCTAssertEqual(requestCountAfterQueuedCancel, 0)

        // Exercise cancellation after the semaphore has granted the waiter.  The gate stops the
        // resumed waiter exactly before its cancellation check/confirmation, so this does not
        // depend on a scheduler window.
        let grantGate = SFTPDownloadEngine.GrantConfirmationGate()
        await budget.installRequestGrantConfirmationGate(grantGate)
        try await budget.acquireRequest()
        let granted = Task {
            try await budget.acquireRequest()
            await recorder.append("granted")
            await budget.releaseRequest()
        }

        var grantedQueued = false
        for _ in 0..<1_000 {
            if await budget.requestWaiterCount == 1 {
                grantedQueued = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(grantedQueued, "the cancellation candidate must be queued before releasing the holder")
        await budget.releaseRequest()

        await grantGate.waitUntilGrant()
        let labelsBeforeConfirmation = await recorder.snapshot
        XCTAssertFalse(labelsBeforeConfirmation.contains("granted"), "grant must pause before confirmation")

        // Cancel while the granted waiter is stopped before confirmation, then open the barrier
        // so its cancellation path can release the granted permit and unwind.
        granted.cancel()

        await grantGate.release()
        do {
            _ = try await granted.value
            XCTFail("cancelled granted waiter should throw")
        } catch is CancellationError {
            // expected
        }

        let requestCountAfterGrantedCancel = await budget.currentRequestCount
        let waiterCountAfterGrantedCancel = await budget.requestWaiterCount
        XCTAssertEqual(requestCountAfterGrantedCancel, 0)
        XCTAssertEqual(waiterCountAfterGrantedCancel, 0)

        // Successor A now acquires the recovered permit and holds it while successor B queues.
        // Keeping A's permit live makes any extra release observable by the count/ordering
        // assertions below rather than relying on `release()`'s defensive floor at zero.
        actor PermitHoldGate {
            private var didEnter = false
            private var released = false
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiter: CheckedContinuation<Void, Never>?

            func waitUntilEntered() async {
                if didEnter { return }
                await withCheckedContinuation { continuation in
                    if didEnter {
                        continuation.resume()
                    } else {
                        entryWaiters.append(continuation)
                    }
                }
            }

            func enterAndHold() async {
                didEnter = true
                let waiters = entryWaiters
                entryWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
                if released { return }
                await withCheckedContinuation { continuation in
                    if released {
                        continuation.resume()
                    } else {
                        releaseWaiter = continuation
                    }
                }
            }

            func release() {
                released = true
                releaseWaiter?.resume()
                releaseWaiter = nil
            }
        }

        let successorAHold = PermitHoldGate()
        let successorA = Task {
            try await budget.acquireRequest()
            await recorder.append("A")
            await successorAHold.enterAndHold()
            await budget.releaseRequest()
        }
        await successorAHold.waitUntilEntered()

        let requestCountWhileSuccessorAHolds = await budget.currentRequestCount
        XCTAssertEqual(requestCountWhileSuccessorAHolds, 1)

        let successorB = Task {
            try await budget.acquireRequest()
            await recorder.append("B")
            await budget.releaseRequest()
        }
        var successorBQueued = false
        for _ in 0..<1_000 {
            if await budget.requestWaiterCount == 1 {
                successorBQueued = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(successorBQueued, "successor B must wait behind successor A")

        await successorAHold.release()
        try await successorA.value
        try await successorB.value

        let labelsAfterGrantedCancel = await recorder.snapshot
        XCTAssertEqual(labelsAfterGrantedCancel, ["second", "A", "B"], "FIFO must advance through the recovered permit")
        let requestPeakAfterGrantedCancel = await budget.peakRequestCount
        let finalRequestCount = await budget.currentRequestCount
        let finalWaiterCount = await budget.requestWaiterCount
        XCTAssertEqual(finalRequestCount, 0)
        XCTAssertEqual(finalWaiterCount, 0)
        XCTAssertEqual(requestPeakAfterGrantedCancel, 1)
    }

    func testPipelineCancellationDoesNotDispatchAfterTaskGroupDrains() async throws {
        actor Probe {
            var offsets: [UInt64] = []
            func record(_ offset: UInt64) { offsets.append(offset) }
            var count: Int { offsets.count }
        }
        let probe = Probe()
        let task = Task {
            try await SFTPDownloadEngine.copyKnownSize(
                expectedSize: 1024,
                chunkSize: 64,
                initialPipelineDepth: 4,
                maxPipelineDepth: 4,
                read: { offset, length in
                    await probe.record(offset)
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    return Data(repeating: 0, count: Int(length))
                },
                write: { _, _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let dispatched = await probe.count
        XCTAssertLessThanOrEqual(dispatched, 4)
    }

    func testOpenedFileCancellationDrainsReadsBeforeCloseAndReleasesBudgets() async throws {
        struct FakeHandle: Sendable {
            let id = 1
        }
        actor Probe {
            struct ReadWaiter {
                let length: UInt32
                let continuation: CheckedContinuation<Data, Never>
            }

            var events: [String] = []
            var waiters: [ReadWaiter] = []

            func open() -> FakeHandle {
                events.append("open")
                return FakeHandle()
            }

            func snapshot() -> UInt64? {
                events.append("snapshot")
                return 64
            }

            func read(offset: UInt64, length: UInt32) async -> Data {
                events.append("read-start-\(offset)")
                return await withCheckedContinuation { continuation in
                    waiters.append(ReadWaiter(length: length, continuation: continuation))
                }
            }

            func releaseReads() {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending {
                    events.append("read-return")
                    waiter.continuation.resume(returning: Data(repeating: 0, count: Int(waiter.length)))
                }
            }

            func close() {
                events.append("close")
            }

            var readStartCount: Int { events.filter { $0.hasPrefix("read-start-") }.count }
            var closeCount: Int { events.filter { $0 == "close" }.count }
            var eventList: [String] { events }
        }

        let probe = Probe()
        let budget = SFTPDownloadEngine.TransferBudget(requestLimit: 4, handleLimit: 1)
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-download-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }

        let transfer = Task {
            try await SFTPDownloadEngine.downloadOpenedFileLifecycle(
                expectedSize: 64,
                localURL: localURL,
                chunkSize: 32,
                configuration: .init(initialPipelineDepth: 2, maxPipelineDepth: 2),
                budget: budget,
                open: { await probe.open() },
                snapshot: { _ in await probe.snapshot() },
                read: { _, offset, length in await probe.read(offset: offset, length: length) },
                close: { _ in await probe.close() }
            )
        }

        var readsStarted = false
        for _ in 0..<1_000 {
            if await probe.readStartCount == 2 {
                readsStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(readsStarted, "the fake must have two in-flight READs before cancellation")
        transfer.cancel()
        await Task.yield()
        let closeCountBeforeDrain = await probe.closeCount
        let readCountBeforeDrain = await probe.readStartCount
        XCTAssertEqual(closeCountBeforeDrain, 0, "CLOSE must wait for the ignored-cancellation READs")
        XCTAssertEqual(readCountBeforeDrain, 2, "cancellation must stop new READ dispatch")

        await probe.releaseReads()
        do {
            _ = try await transfer.value
            XCTFail("cancelled transfer should throw")
        } catch is CancellationError {
            // expected
        }

        let events = await probe.eventList
        let lastReadReturn = events.lastIndex(of: "read-return")
        let closeIndex = events.lastIndex(of: "close")
        XCTAssertNotNil(lastReadReturn)
        XCTAssertNotNil(closeIndex)
        if let lastReadReturn, let closeIndex {
            XCTAssertLessThan(lastReadReturn, closeIndex, "remote CLOSE must follow drained READs")
        }
        let finalReadCount = await probe.readStartCount
        let finalCloseCount = await probe.closeCount
        let finalRequestCount = await budget.currentRequestCount
        let finalHandleCount = await budget.currentHandleCount
        XCTAssertEqual(finalReadCount, 2)
        XCTAssertEqual(finalCloseCount, 1)
        XCTAssertEqual(finalRequestCount, 0)
        XCTAssertEqual(finalHandleCount, 0)
    }
}
