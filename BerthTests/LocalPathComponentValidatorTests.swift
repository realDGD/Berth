import XCTest
@testable import Berth

final class LocalPathComponentValidatorTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    func testValidComponentPasses() throws {
        let names = ["file.txt", "My Document (1).docx", "中文文件名.txt", ".hiddenfile"]
        for name in names {
            XCTAssertNoThrow(try LocalPathComponentValidator.validateComponent(name))
        }
    }

    func testBackslashInFilenameIsValid() throws {
        let name = "foo\\bar.txt"
        XCTAssertNoThrow(try LocalPathComponentValidator.validateComponent(name))
        XCTAssertEqual(
            try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, component: name).lastPathComponent,
            name
        )
    }

    func testRejectsEmptyDotSlashNullAndControls() {
        for name in ["", ".", "..", "foo/bar", "../passwd", "/absolute", "file\0name", "file\nname"] {
            XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent(name), name)
        }
    }

    func testSafeURLStaysStrictlyBelowRoot() throws {
        let safe = try LocalPathComponentValidator.safeURL(
            in: tempDirectoryURL,
            components: ["subdir", "nested", "file.log"]
        )
        XCTAssertTrue(LocalPathComponentValidator.isStrictlyContained(candidate: safe, within: tempDirectoryURL))
    }

    func testPrefixCollisionAndEqualPathAreNotContained() {
        let root = tempDirectoryURL.appendingPathComponent("target", isDirectory: true)
        let collision = tempDirectoryURL.appendingPathComponent("target2/file.txt")
        XCTAssertFalse(LocalPathComponentValidator.isStrictlyContained(candidate: collision, within: root))
        XCTAssertFalse(LocalPathComponentValidator.isStrictlyContained(candidate: root, within: root))
    }

    // MARK: - Log Sanitization Tests

    func testLogSanitizerEscapesNewlinesAndControls() {
        let malicious = "evil\n2026-09-03 ERROR fake injected log\r\tline"
        let sanitized = LogSanitizer.sanitize(malicious)
        XCTAssertFalse(sanitized.contains("\n"), "Must not contain raw newlines")
        XCTAssertFalse(sanitized.contains("\r"), "Must not contain raw carriage returns")
        XCTAssertTrue(sanitized.contains("\\n"), "Must escape newlines as \\n")
        XCTAssertTrue(sanitized.contains("\\r"), "Must escape carriage returns as \\r")
        XCTAssertTrue(sanitized.contains("\\t"), "Must escape tabs as \\t")

        let filenameMalicious = "/some/remote/path/evil\nfile.txt"
        let safeName = LogSanitizer.safeFilename(filenameMalicious)
        XCTAssertFalse(safeName.contains("\n"))
        XCTAssertFalse(safeName.contains("/some/remote/path"))
        XCTAssertTrue(safeName.contains("evil\\nfile.txt"))
    }
}
