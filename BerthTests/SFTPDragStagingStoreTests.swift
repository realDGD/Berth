import XCTest
@testable import Berth

final class SFTPDragStagingStoreTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var store: SFTPDragStagingStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Berth-StagingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        store = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            deliveredGracePeriod: 1800,  // 30 mins
            interruptedGracePeriod: 3600, // 1 hour
            absoluteCeiling: 86400       // 24 hours
        )
    }

    override func tearDown() async throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    func testCreateWritesMarkerAndTracksActiveLease() async throws {
        let lease = try await store.create(named: "bundle.tar.gz", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.rootURL.path))
        XCTAssertEqual(lease.payloadURL.lastPathComponent, "bundle.tar.gz")

        let markerURL = lease.rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)
        XCTAssertEqual(metadata.id, lease.id)
        XCTAssertEqual(metadata.payloadName, "bundle.tar.gz")
        XCTAssertNil(metadata.deliveredAt)
    }

    func testDiscardImmediatelyRemovesStagingRoot() async throws {
        let lease = try await store.create(named: "test_folder", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.rootURL.path))

        await store.discard(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.rootURL.path))

        // Idempotent: repeated discard does not throw or fail
        await store.discard(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    func testMarkDeliveredUpdatesMarkerAndRetainsPayload() async throws {
        let lease = try await store.create(named: "output.log", isDirectory: false)
        try "hello staging".write(to: lease.payloadURL, atomically: true, encoding: .utf8)

        let deliveryTime = Date()
        await store.markDelivered(lease, now: deliveryTime)

        // Payload must still exist after delivery
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.payloadURL.path))

        let markerURL = lease.rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)
        XCTAssertNotNil(metadata.deliveredAt)
    }

    func testActiveLeaseIsNeverSweptEvenIfOld() async throws {
        let past = Date().addingTimeInterval(-7200) // 2 hours ago
        let lease = try await store.create(named: "active_huge.bin", isDirectory: false, now: past)

        // Sweep running right now
        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    func testDeliveredLeaseRetainedWithinGracePeriod() async throws {
        let t0 = Date()
        let lease = try await store.create(named: "delivered_recent.bin", isDirectory: false, now: t0)
        await store.markDelivered(lease, now: t0)

        // 10 minutes later (well within 30 min grace period)
        let sweepResult = try await store.sweepStale(now: t0.addingTimeInterval(600))
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    func testStaleDeliveredLeaseIsSweptAndReclaimed() async throws {
        let t0 = Date()
        let lease = try await store.create(named: "delivered_old.bin", isDirectory: false, now: t0)
        let payloadData = Data(repeating: 0x41, count: 4096)
        try payloadData.write(to: lease.payloadURL)

        await store.markDelivered(lease, now: t0)

        // 35 minutes later (exceeds 30 min grace period)
        let sweepTime = t0.addingTimeInterval(2100)
        let sweepResult = try await store.sweepStale(now: sweepTime)
        XCTAssertEqual(sweepResult.reclaimedCount, 1)
        XCTAssertGreaterThanOrEqual(sweepResult.reclaimedBytes, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    func testCrashInterruptedLeaseFromDeadPIDIsSwept() async throws {
        // Simulate a lease created by a process that crashed/died (pid 999999)
        let deadLeaseID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(deadLeaseID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: deadLeaseID,
            pid: 999999, // Dead PID
            createdAt: Date().addingTimeInterval(-120),
            deliveredAt: nil,
            payloadName: "crashed_payload",
            isDirectory: true
        )
        let markerURL = rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL)

        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testDirectoryWithoutMarkerIsNeverSwept() async throws {
        // Even if directory matches prefix Berth-Drag-*, without valid marker it must NOT be touched!
        let fakeUUID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(fakeUUID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payloadURL = rootURL.appendingPathComponent("user_important.txt")
        try "critical data".write(to: payloadURL, atomically: true, encoding: .utf8)

        let sweepResult = try await store.sweepStale(now: Date().addingTimeInterval(100000))
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    func testSymlinkOutsideBaseIsNeverSweptOrFollowed() async throws {
        // Create an outside target directory
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Berth-OutsideTarget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("keep_me.txt")
        try "keep me".write(to: outsideFile, atomically: true, encoding: .utf8)

        // Create symlink inside base pointing to outside
        let symlinkRoot = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: outsideDir)

        let sweepResult = try await store.sweepStale(now: Date().addingTimeInterval(100000))
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
