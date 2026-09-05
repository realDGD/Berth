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
            interruptedGracePeriod: 3600, // 1 hour
            legacyGracePeriod: 86400,    // 24 hours
            minimumSweepInterval: 60     // 60 seconds
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

    func testCreateWithMaliciousNameThrowsAndDoesNotEscape() async throws {
        do {
            _ = try await store.create(named: "../../etc/passwd", isDirectory: false)
            XCTFail("Should not allow path traversal in staging name")
        } catch {
            // Expected
        }
    }

    func testCreateRemovesRootWhenInitialMarkerWriteFails() async throws {
        let failingStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            markerWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        do {
            _ = try await failingStore.create(named: "marker-failure.txt", isDirectory: false)
            XCTFail("create must throw when the initial marker write fails")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDirectoryURL.path), [])
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
        try await store.markDelivered(lease, payloadBytes: 13, now: deliveryTime)

        // Payload must still exist after delivery
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.payloadURL.path))

        let markerURL = lease.rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)
        XCTAssertNotNil(metadata.deliveredAt)
        XCTAssertEqual(metadata.payloadBytes, 13)
    }

    func testMarkDeliveredAtomicWriteFailureKeepsActive() async throws {
        final class MockWriter: @unchecked Sendable {
            var fail = false
        }
        let mock = MockWriter()
        let failingStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            markerWriter: { data, url in
                if mock.fail {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let lease = try await failingStore.create(named: "fail_marker.txt", isDirectory: false)
        mock.fail = true

        do {
            try await failingStore.markDelivered(lease, payloadBytes: 1024)
            XCTFail("markDelivered must throw when marker write fails")
        } catch {
            // Expected
        }

        // Active lease must NOT be swept while failing/active
        let sweepResult = try await failingStore.sweepStale(now: Date().addingTimeInterval(7200))
        XCTAssertEqual(sweepResult.reclaimedCount, 0, "Active lease must remain protected")
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
        try await store.markDelivered(lease, payloadBytes: 1024, now: t0)

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

        try await store.markDelivered(lease, payloadBytes: 4096, now: t0)

        // 35 minutes later (exceeds 30 min grace period)
        let sweepTime = t0.addingTimeInterval(2100)
        let sweepResult = try await store.sweepStale(now: sweepTime)
        XCTAssertEqual(sweepResult.reclaimedCount, 1)
        XCTAssertGreaterThanOrEqual(sweepResult.reclaimedBytes, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    // MARK: - Large Directory Retention Tests (P1)

    func testLargeDirectoryRetentionScalesWithCopiedBytes() async throws {
        // 100 GiB payload size
        let hundredGiB: UInt64 = 100 * 1024 * 1024 * 1024
        let expectedRetention = SFTPDragRetentionPolicy.retentionInterval(payloadBytes: hundredGiB)
        // 100 GiB / 2 MiB/s = 51,200 seconds (~14.2 hours)
        XCTAssertEqual(expectedRetention, 51200, accuracy: 1.0)

        let t0 = Date()
        let lease = try await store.create(named: "large_dir", isDirectory: true, now: t0)
        try await store.markDelivered(lease, payloadBytes: hundredGiB, now: t0)

        // 1 hour later: MUST NOT be swept
        let oneHourLater = try await store.sweepStale(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(oneHourLater.reclaimedCount, 0, "100 GiB folder must not be swept after 1 hour")

        // 10 hours later (36,000s): MUST NOT be swept
        let tenHoursLater = try await store.sweepStale(now: t0.addingTimeInterval(36000))
        XCTAssertEqual(tenHoursLater.reclaimedCount, 0, "100 GiB folder must not be swept after 10 hours")

        // 15 hours later (54,000s > 51,200s): MUST be swept
        let fifteenHoursLater = try await store.sweepStale(now: t0.addingTimeInterval(54000))
        XCTAssertEqual(fifteenHoursLater.reclaimedCount, 1, "100 GiB folder should be swept after retention window expires")
    }

    func testActualCopiedBytesPersistedToMarker() async throws {
        // Simulate directory with initial entry size 1 MiB but actual downloaded copiedBytes = 10 GiB
        let tenGiB: UInt64 = 10 * 1024 * 1024 * 1024
        let lease = try await store.create(named: "downloaded_tree", isDirectory: true)

        try await store.markDelivered(lease, payloadBytes: tenGiB)

        let markerURL = lease.rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(StagingMarkerMetadata.self, from: data)

        XCTAssertEqual(metadata.payloadBytes, tenGiB, "Marker must accurately persist the actual downloaded copiedBytes")
    }

    func testDeliveredLeaseWithDeadPIDIsRetainedUntilRetentionExpires() async throws {
        // Simulate a crash after delivery of a 100 GiB directory:
        // DeliveredAt is recent, PID belongs to a dead process.
        let customStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            processLivenessChecker: { _ in false } // dead process
        )

        let hundredGiB: UInt64 = 100 * 1024 * 1024 * 1024
        let leaseID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(leaseID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let t0 = Date()
        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: leaseID,
            pid: 999999, // dead PID
            createdAt: t0,
            deliveredAt: t0,
            payloadName: "crashed_after_delivery",
            isDirectory: true,
            payloadBytes: hundredGiB
        )
        let markerURL = rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL)

        // 2 hours after crash: Finder may still be copying to slow NAS. Dead PID must NOT trigger immediate deletion!
        let sweepResult = try await customStore.sweepStale(now: t0.addingTimeInterval(7200))
        XCTAssertEqual(sweepResult.reclaimedCount, 0, "Delivered staging must be retained within retention window even if owner PID is dead")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))

        // 15 hours later: Retention expired. Must now be swept.
        let expiredSweep = try await customStore.sweepStale(now: t0.addingTimeInterval(54000))
        XCTAssertEqual(expiredSweep.reclaimedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testDeliveredLargeDirectoryRetainedAcrossRestart() async throws {
        let hundredGiB: UInt64 = 100 * 1024 * 1024 * 1024
        let t0 = Date()
        let lease = try await store.create(named: "restart_test_dir", isDirectory: true, now: t0)
        try await store.markDelivered(lease, payloadBytes: hundredGiB, now: t0)

        // Simulate app restart by initializing a brand new SFTPDragStagingStore instance
        let restartedStore = SFTPDragStagingStore(baseDirectory: tempDirectoryURL)

        // Sweep 2 hours after restart: should retain
        let sweepResult = try await restartedStore.sweepStale(now: t0.addingTimeInterval(7200))
        XCTAssertEqual(sweepResult.reclaimedCount, 0, "Restarted store must recover retention from marker and retain delivered directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.rootURL.path))
    }

    func testCrashInterruptedLeaseFromDeadPIDIsSwept() async throws {
        // Lease created by a dead process (mocked via false in custom checker)
        let customStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            interruptedGracePeriod: 3600,
            processLivenessChecker: { _ in false } // simulate dead process
        )

        let deadLeaseID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(deadLeaseID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let t0 = Date()
        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: deadLeaseID,
            pid: 999999,
            createdAt: t0.addingTimeInterval(-7200),
            deliveredAt: nil,
            payloadName: "crashed_payload",
            isDirectory: true
        )
        let markerURL = rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL)

        // First sweep: dead owner detected -> writes orphanedAt, MUST NOT delete immediately
        let firstSweep = try await customStore.sweepStale(now: t0)
        XCTAssertEqual(firstSweep.reclaimedCount, 0, "First sweep upon discovering dead owner must record orphanedAt and keep staging")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))

        // Read back marker to verify orphanedAt was recorded
        let updatedData = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let updatedMetadata = try decoder.decode(StagingMarkerMetadata.self, from: updatedData)
        XCTAssertNotNil(updatedMetadata.orphanedAt)

        // 30 mins after orphanedAt (grace is 60m): still kept
        let intermediateSweep = try await customStore.sweepStale(now: t0.addingTimeInterval(1800))
        XCTAssertEqual(intermediateSweep.reclaimedCount, 0, "Within grace period after dead owner detection, staging must be kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))

        // 65 mins after orphanedAt: grace passed -> swept
        let expiredSweep = try await customStore.sweepStale(now: t0.addingTimeInterval(3900))
        XCTAssertEqual(expiredSweep.reclaimedCount, 1, "After grace period from orphanedAt, dead lease must be reclaimed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testForeignOwnerAliveKeptAt30Min2HoursAnd48Hours() async throws {
        let customStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            interruptedGracePeriod: 3600,   // 1 hour
            processLivenessChecker: { _ in true } // foreign owner process is STILL ALIVE
        )

        let leaseID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(leaseID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let t0 = Date()
        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: leaseID,
            pid: 777777,
            createdAt: t0,
            deliveredAt: nil,
            payloadName: "large_active_download",
            isDirectory: true
        )
        let markerURL = rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL)

        // 30 mins later: owner alive -> KEEP
        let sweep30m = try await customStore.sweepStale(now: t0.addingTimeInterval(1800))
        XCTAssertEqual(sweep30m.reclaimedCount, 0, "Foreign active lease with live owner must be kept at 30 min")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))

        // 2 hours later (exceeds interruptedGracePeriod 1h): owner alive -> KEEP
        let sweep2h = try await customStore.sweepStale(now: t0.addingTimeInterval(7200))
        XCTAssertEqual(sweep2h.reclaimedCount, 0, "Foreign active lease with live owner must be kept at 2 hours")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))

        // 48 hours later: owner alive -> KEEP
        let sweep48h = try await customStore.sweepStale(now: t0.addingTimeInterval(48 * 3600))
        XCTAssertEqual(sweep48h.reclaimedCount, 0, "Foreign active lease with live owner must be kept even at 48 hours")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testInterruptedLeaseFromAlivePIDIsProtected() async throws {
        // Lease created by a process that is STILL ALIVE (mocked via true in custom checker)
        let customStore = SFTPDragStagingStore(
            baseDirectory: tempDirectoryURL,
            interruptedGracePeriod: 3600,
            processLivenessChecker: { _ in true } // simulate live process
        )

        let liveLeaseID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(liveLeaseID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let metadata = StagingMarkerMetadata(
            schemaVersion: 1,
            id: liveLeaseID,
            pid: 888888,
            createdAt: Date().addingTimeInterval(-120), // 2 mins old, well within 1 hour
            deliveredAt: nil,
            payloadName: "active_other_process",
            isDirectory: true
        )
        let markerURL = rootURL.appendingPathComponent(SFTPDragStagingStore.markerFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL)

        let sweepResult = try await customStore.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testProcessLivenessCheckerBehavior() {
        // Current process is alive
        let currentPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(SFTPDragStagingStore.defaultProcessLivenessChecker(currentPID))

        // Non-existent PID
        XCTAssertFalse(SFTPDragStagingStore.defaultProcessLivenessChecker(9999999))

        // Invalid PID
        XCTAssertFalse(SFTPDragStagingStore.defaultProcessLivenessChecker(-1))
        XCTAssertFalse(SFTPDragStagingStore.defaultProcessLivenessChecker(0))
    }

    // MARK: - Legacy markerless staging tests (P1-1)

    func testLegacyMarkerlessOldDirectoryIsSwept() async throws {
        let legacyUUID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(legacyUUID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payloadURL = rootURL.appendingPathComponent("legacy_file.txt")
        try "legacy data".write(to: payloadURL, atomically: true, encoding: .utf8)

        // Set modification date to 48 hours ago
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: rootURL.path)

        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedLegacyCount, 1)
        XCTAssertEqual(sweepResult.reclaimedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testLegacyMarkerlessRecentDirectoryIsNOTSwept() async throws {
        let legacyUUID = UUID()
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)\(legacyUUID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payloadURL = rootURL.appendingPathComponent("recent_file.txt")
        try "recent data".write(to: payloadURL, atomically: true, encoding: .utf8)

        // Set modification date to only 1 hour ago (legacy TTL is 24h)
        let recentDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: rootURL.path)

        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedLegacyCount, 0)
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testLegacyMarkerlessInvalidUUIDNameIsNOTSwept() async throws {
        // Name has prefix but does NOT end in a valid UUID
        let rootURL = tempDirectoryURL.appendingPathComponent("\(SFTPDragStagingStore.prefix)foo", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payloadURL = rootURL.appendingPathComponent("important.txt")
        try "do not touch".write(to: payloadURL, atomically: true, encoding: .utf8)

        let oldDate = Date().addingTimeInterval(-100 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: rootURL.path)

        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testUnrelatedDirectoryIsNOTSwept() async throws {
        let rootURL = tempDirectoryURL.appendingPathComponent("SomeOtherAppDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payloadURL = rootURL.appendingPathComponent("doc.txt")
        try "user data".write(to: payloadURL, atomically: true, encoding: .utf8)

        let oldDate = Date().addingTimeInterval(-100 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: rootURL.path)

        let sweepResult = try await store.sweepStale(now: Date())
        XCTAssertEqual(sweepResult.reclaimedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testSymlinkOutsideBaseIsNeverSweptOrFollowed() async throws {
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

    // MARK: - Sweep Throttling Tests (P3-2)

    func testSweepThrottlingSkipsExecutionWhenIntervalNotMet() async throws {
        let now = Date()
        // First sweep records lastSweepDate
        _ = try await store.sweepStale(now: now, force: true)

        // Create a stale lease
        let lease = try await store.create(named: "throttled.bin", isDirectory: false, now: now.addingTimeInterval(-7200))
        try await store.markDelivered(lease, payloadBytes: 100, now: now.addingTimeInterval(-7200))

        // Sweep 10 seconds later with force: false (minimumSweepInterval is 60s)
        let throttledResult = try await store.sweepStale(now: now.addingTimeInterval(10), force: false)
        XCTAssertEqual(throttledResult.examinedCount, 0, "Throttled sweep must skip examination")

        // Sweep 70 seconds later with force: false (exceeds interval)
        let activeResult = try await store.sweepStale(now: now.addingTimeInterval(70), force: false)
        XCTAssertEqual(activeResult.reclaimedCount, 1, "Sweep should execute once interval has elapsed")
    }
}
