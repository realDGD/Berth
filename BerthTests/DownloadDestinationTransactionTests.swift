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

    // MARK: - 6. 目录 final 已存在且非空: 拒绝静默合并, 抛出明确冲突, 保护已有目录

    func testDirectoryFinalAlreadyExistsAndNonEmptyRefusesMerge() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("existing_folder")
        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
        try "IMPORTANT LOCAL FILE".write(to: finalURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: true)
        try "REMOTE NEW FILE".write(to: tx.workingURL.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)

        do {
            try tx.commit()
            XCTFail("Commit must throw when destination directory already exists and is non-empty")
        } catch let error as DownloadDestinationTransaction.TransactionError {
            XCTAssertEqual(error, .destinationDirectoryNotEmpty(finalURL))
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

    // MARK: - 8. 模拟写入失败 (例如 ENOSPC / 网络异常): discard 保留原 final

    func testWriteFailurePreservesOriginalFinalAndCleansWorking() throws {
        let finalURL = tempDirectoryURL.appendingPathComponent("protected_existing.bin")
        let originalBytes = "UNTOUCHED OLD DATA".data(using: .utf8)!
        try originalBytes.write(to: finalURL)

        let tx = try DownloadDestinationTransaction.begin(finalURL: finalURL, isDirectory: false)

        // Write partial before error
        try "partial before error".write(to: tx.workingURL, atomically: true, encoding: .utf8)

        // Simulate error handling block
        let simulatedError = POSIXError(.ENOSPC)
        tx.discard()

        XCTAssertEqual(try Data(contentsOf: finalURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tx.workingURL.path))
        XCTAssertEqual(simulatedError.code, .ENOSPC)
    }
}
