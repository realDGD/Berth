import XCTest
@testable import Berth

final class DownloadDestinationTransactionTests: XCTestCase {

    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Berth-TransactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    // MARK: - 1. 单文件 final 不存在: 取消后 final 不存在, working 不存在

    func testSingleFileFinalDoesNotExistAndCancelDiscardsWorking() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("target_file.bin")
        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        // Working URL must be hidden, unique, and strictly contained in parent
        XCTAssertTrue(tx.workingURL.lastPathComponent.hasPrefix(".target_file.bin.berth-part-"))
        XCTAssertEqual(tx.workingURL.deletingLastPathComponent().path, tempDirectoryURL.path)

        // Simulate partial write
        try "partial chunk".write(to: tx.workingURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tx.workingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))

        // Cancel -> discard
        tx.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path), "Final must not exist after cancellation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path), "Working must be removed after cancellation")
    }

    // MARK: - 2. 单文件 final 已存在: 取消后 final 保持原内容, working 不存在

    func testSingleFileFinalAlreadyExistsAndCancelPreservesOriginalData() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("precious_data.bin")
        let originalData = "ORIGINAL CRITICAL DATA".data(using: .utf8)!
        try originalData.write(to: finalURL)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        // Write partial new data to working
        let partialData = "NEW PARTIAL DATA".data(using: .utf8)!
        try partialData.write(to: tx.workingURL)

        // Verify final has NOT been touched or truncated
        let readBeforeDiscard = try Data(contentsOf: finalURL)
        XCTAssertEqual(readBeforeDiscard, originalData, "Final must not be truncated during download")

        // Cancel -> discard
        tx.discard()

        // Verify final still contains original data intact
        let readAfterDiscard = try Data(contentsOf: finalURL)
        XCTAssertEqual(readAfterDiscard, originalData, "Final must remain 100% intact after cancellation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    // MARK: - 3. 单文件成功: commit 后 working 不存在, final 包含完整新内容

    func testSingleFileSuccessCommitsAtomically() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("final_output.bin")
        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        let completedData = "FULL COMPLETED CONTENT 12345".data(using: .utf8)!
        try completedData.write(to: tx.workingURL)

        try tx.commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path), "Working file must be consumed on commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let resultData = try Data(contentsOf: finalURL)
        XCTAssertEqual(resultData, completedData)
    }

    // MARK: - 4. 单文件覆盖成功: final 原本存在, commit 后原子替换为新内容

    func testSingleFileAtomicReplaceWhenFinalExists() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("replace_target.bin")
        try "OLD DATA V1".write(to: finalURL, atomically: true, encoding: .utf8)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)
        try "NEW COMPLETED DATA V2".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        try tx.commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
        let result = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertEqual(result, "NEW COMPLETED DATA V2")
    }

    // MARK: - 5. 目录 final 不存在: 递归完整内容成功 commit 为 final

    func testDirectoryFinalDoesNotExistCommitsAtomically() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("my_project")
        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tx.workingURL.path))

        // Create nested files in working
        let subDir = tx.workingURL.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "file1".write(to: subDir.appendingPathComponent("1.txt"), atomically: true, encoding: .utf8)

        try tx.commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.appendingPathComponent("sub/1.txt").path))
    }

    // MARK: - 6. 目录 final 已存在 (空目录与非空目录): 均严格拒绝替换并保护原有目录

    func testExistingEmptyDirectoryRefusesCommitAndPreservesFinal() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("empty_existing_dir")
        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)
        try "REMOTE CONTENT".write(to: tx.workingURL.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)

        do {
            try tx.commit()
            XCTFail("Commit must throw when destination directory already exists")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            XCTAssertEqual(error, .destinationDirectoryAlreadyExists(finalURL))
        }

        // Clean up transaction
        tx.discard()

        // Existing empty directory must NOT have been removed or merged
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: finalURL.path)
        XCTAssertTrue(remaining.isEmpty, "Empty directory must remain empty and untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    func testExistingNonEmptyDirectoryRefusesCommitAndPreservesFinal() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("existing_folder")
        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
        try "IMPORTANT LOCAL FILE".write(to: finalURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)
        try "REMOTE NEW FILE".write(to: tx.workingURL.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)

        do {
            try tx.commit()
            XCTFail("Commit must throw when destination directory already exists and is non-empty")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            XCTAssertEqual(error, .destinationDirectoryAlreadyExists(finalURL))
        }

        // Clean up transaction
        tx.discard()

        // Existing folder must remain completely intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.appendingPathComponent("local.txt").path))
        let content = try String(contentsOf: finalURL.appendingPathComponent("local.txt"), encoding: .utf8)
        XCTAssertEqual(content, "IMPORTANT LOCAL FILE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    // MARK: - 7. 目录下载取消: working 树被完全删除, final 不存在

    func testDirectoryCancellationCleansWorkingTree() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("cancelled_tree")
        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)

        let subDir = tx.workingURL.appendingPathComponent("deep/dir", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "data".write(to: subDir.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)

        tx.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    // MARK: - 8. fail-closed: missing working item 必须 throw

    func testMissingWorkingFileFailsClosedAndPreservesFinal() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("existing_safe.bin")
        let originalBytes = "PRECIOUS PRE-EXISTING DATA".data(using: .utf8)!
        try originalBytes.write(to: finalURL)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        // Do NOT create working file
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))

        do {
            try tx.commit()
            XCTFail("Commit must throw when working file was never created")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            XCTAssertEqual(error, .workingItemMissing(tx.workingURL))
        }

        XCTAssertEqual(try Data(contentsOf: finalURL), originalBytes, "Original file must be completely untouched")
    }

    func testMissingWorkingDirectoryFailsClosed() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("target_dir")
        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)

        // Remove the pre-created working directory to simulate missing payload
        try FileManager.default.removeItem(at: tx.workingURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))

        do {
            try tx.commit()
            XCTFail("Commit must throw when working directory is missing")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            XCTAssertEqual(error, .workingItemMissing(tx.workingURL))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    // MARK: - 9. 真实文件系统 commit 失败: 保护已有 final 不被破坏

    func testCommitFailurePreservesOriginalFinal() throws {
        let subFolder = tempDirectoryURL.appendingPathComponent("readonly_test_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let finalURL = subFolder.appendingPathComponent("target.bin")
        let originalContent = "ORIGINAL UNTOUCHED CONTENT"
        try originalContent.write(to: finalURL, atomically: true, encoding: .utf8)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)
        try "NEW CONTENT".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        // Make parent directory read-only to provoke a real filesystem failure during replaceItemAt
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: subFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subFolder.path)
        }

        var commitError: Error?
        do {
            try tx.commit()
            XCTFail("Commit should fail in read-only directory")
        } catch {
            commitError = error
        }

        XCTAssertNotNil(commitError)

        // Restore permissions and discard working
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subFolder.path)
        tx.discard()

        // Original final file must be 100% intact
        let finalRead = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertEqual(finalRead, originalContent, "Commit failure must leave finalURL completely intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    // MARK: - 10. 模拟写入失败 (ENOSPC-equivalent failure cleanup regression): discard 保留原 final

    func testWriteFailurePreservesOriginalFinalAndCleansWorking() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("protected_existing.bin")
        let originalBytes = "UNTOUCHED OLD DATA".data(using: .utf8)!
        try originalBytes.write(to: finalURL)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        // Write partial before simulated failure
        try "partial before error".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        // Simulate error handling block
        let simulatedError = POSIXError(.ENOSPC)
        tx.discard()

        XCTAssertEqual(try Data(contentsOf: finalURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
        XCTAssertEqual(simulatedError.code, .ENOSPC)
    }

    // MARK: - 11. Replacement 失败恢复回归测试 (M-03 Recovery Hardening)

    func testReplaceFailsBeforeOriginalMovedPreservesFinalAndPropagatesError() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("replace_fail_early.bin")
        let originalContent = "ORIGINAL CRITICAL DATA EARLY"
        try originalContent.write(to: finalURL, atomically: true, encoding: .utf8)

        struct SimulatedEarlyError: Error, Equatable {}

        let tx = try DownloadDestinationTransaction.begin(
            finalURL: finalURL,
            isDirectory: false,
            itemReplacer: { _, _ in
                // Fail before touching finalURL
                throw SimulatedEarlyError()
            }
        )
        try "NEW CONTENT".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        var caughtError: Error?
        do {
            try tx.commit()
            XCTFail("Commit must throw when replacement fails early")
        } catch {
            caughtError = error
        }

        XCTAssertTrue(caughtError is SimulatedEarlyError)
        tx.discard()

        // finalURL remains in place with original content
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let finalData = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertEqual(finalData, originalContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    func testReplaceFailsAfterOriginalMovedRecoversFinalFromLocationKeyAndPropagatesError() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("replace_fail_relocated.bin")
        let originalContent = "ORIGINAL CRITICAL DATA RELOCATED"
        try originalContent.write(to: finalURL, atomically: true, encoding: .utf8)

        let recoveryURL = tempDirectoryURL.appendingPathComponent("foundation_recovery_staging.bin")
        let simulatedReplaceError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [DownloadDestinationTransaction.originalItemLocationKey: recoveryURL]
        )

        let tx = try DownloadDestinationTransaction.begin(
            finalURL: finalURL,
            isDirectory: false,
            itemReplacer: { final, _ in
                // Simulate Foundation moving original to recoveryURL, removing finalURL, then failing
                try FileManager.default.moveItem(at: final, to: recoveryURL)
                throw simulatedReplaceError
            }
        )
        try "NEW CONTENT".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        var caughtError: Error?
        do {
            try tx.commit()
            XCTFail("Commit must throw when replacement fails after relocation")
        } catch {
            caughtError = error
        }

        // Original replace error must be propagated to caller
        XCTAssertEqual((caughtError as? NSError)?.domain, NSCocoaErrorDomain)
        XCTAssertEqual((caughtError as? NSError)?.code, CocoaError.fileWriteUnknown.rawValue)

        tx.discard()

        // finalURL must have been successfully recovered from recoveryURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path), "Recovery staging must have been moved back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let finalData = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertEqual(finalData, originalContent, "Original content must be fully restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    func testReplaceFailsAndRecoveryFailsThrowsRecoveryFailedError() throws {
        let subFolder = tempDirectoryURL.appendingPathComponent("recovery_fail_sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let finalURL = subFolder.appendingPathComponent("replace_fail_recovery_fails.bin")
        let originalContent = "ORIGINAL DATA STUCK IN RECOVERY"
        try originalContent.write(to: finalURL, atomically: true, encoding: .utf8)

        let recoveryURL = tempDirectoryURL.appendingPathComponent("foundation_recovery_stuck.bin")
        let simulatedReplaceError = NSError(
            domain: "CustomReplacementErrorDomain",
            code: 42,
            userInfo: [DownloadDestinationTransaction.originalItemLocationKey: recoveryURL]
        )

        let tx = try DownloadDestinationTransaction.begin(
            finalURL: finalURL,
            isDirectory: false,
            itemReplacer: { final, _ in
                // Move original to recoveryURL
                try FileManager.default.moveItem(at: final, to: recoveryURL)
                // Make parent directory read-only so restoration moveItem fails with permission denied
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: subFolder.path)
                throw simulatedReplaceError
            }
        )
        try "NEW CONTENT".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subFolder.path)
        }

        do {
            try tx.commit()
            XCTFail("Commit must throw recoveryFailed when recovery cannot be completed")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            switch error {
            case .recoveryFailed(let originalError, let recoveryError, let recURL, let finURL):
                XCTAssertEqual(originalError.domain, "CustomReplacementErrorDomain")
                XCTAssertEqual(originalError.code, 42)
                XCTAssertEqual(recURL.path, recoveryURL.path)
                XCTAssertEqual(finURL.path, finalURL.path)
                XCTAssertNotNil(recoveryError)
            default:
                XCTFail("Expected recoveryFailed error, got \(error)")
            }
        } catch {
            XCTFail("Expected TransactionError, got \(error)")
        }

        // Original file must still be present at recoveryURL for user data preservation
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        let stuckData = try String(contentsOf: recoveryURL, encoding: .utf8)
        XCTAssertEqual(stuckData, originalContent)

        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subFolder.path)
        tx.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }

    func testReplaceFailsAndOriginalMissingWithoutRecoveryLocationKeyThrowsRecoveryFailedError() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("replace_fail_no_key.bin")
        try "ORIGINAL DATA".write(to: finalURL, atomically: true, encoding: .utf8)

        let simulatedReplaceError = NSError(
            domain: "CustomReplacementErrorDomain",
            code: 99,
            userInfo: [:] // Missing recovery key
        )

        let tx = try DownloadDestinationTransaction.begin(
            finalURL: finalURL,
            isDirectory: false,
            itemReplacer: { final, _ in
                // Remove final without leaving recovery key
                try FileManager.default.removeItem(at: final)
                throw simulatedReplaceError
            }
        )
        try "NEW CONTENT".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        do {
            try tx.commit()
            XCTFail("Commit must throw recoveryFailed when final is missing and no recovery key is provided")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            switch error {
            case .recoveryFailed(let originalError, let recoveryError, let recURL, let finURL):
                XCTAssertEqual(originalError.domain, "CustomReplacementErrorDomain")
                XCTAssertEqual(originalError.code, 99)
                XCTAssertEqual(recURL.path, finalURL.path)
                XCTAssertEqual(finURL.path, finalURL.path)
                XCTAssertEqual(recoveryError.domain, NSCocoaErrorDomain)
            default:
                XCTFail("Expected recoveryFailed error, got \(error)")
            }
        } catch {
            XCTFail("Expected TransactionError, got \(error)")
        }

        tx.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
    }
}
