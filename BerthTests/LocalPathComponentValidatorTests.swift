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
        let validNames = [
            "file.txt",
            "report-2026-09-03.pdf",
            "My Document (1).docx",
            "Archive_v2.tar.gz",
            "中文文件名.txt",
            ".hiddenfile"
        ]
        for name in validNames {
            XCTAssertNoThrow(try LocalPathComponentValidator.validateComponent(name), "Failed for valid name: \(name)")
        }
    }

    func testBackslashInFilenameIsValid() throws {
        // POSIX / macOS allows backslash as a normal character in filename
        let backslashName = "foo\\bar.txt"
        XCTAssertNoThrow(try LocalPathComponentValidator.validateComponent(backslashName))
        let url = try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, component: backslashName)
        XCTAssertEqual(url.lastPathComponent, backslashName)
    }

    func testEmptyComponentThrows() {
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("")) { error in
            XCTAssertEqual(error as? LocalPathComponentValidator.ValidationError, .emptyComponent)
        }
    }

    func testDotAndDotDotThrow() {
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent(".")) { error in
            XCTAssertEqual(error as? LocalPathComponentValidator.ValidationError, .pathTraversal(component: "."))
        }
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("..")) { error in
            XCTAssertEqual(error as? LocalPathComponentValidator.ValidationError, .pathTraversal(component: ".."))
        }
    }

    func testSlashThrows() {
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("foo/bar"))
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("../passwd"))
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("/absolute/path"))
    }

    func testNullByteAndControlCharactersThrow() {
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("file\0name.txt"))
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("file\u{0001}name.txt"))
        XCTAssertThrowsError(try LocalPathComponentValidator.validateComponent("file\nname.txt"))
    }

    func testSafeURLSingleComponentStrictContainment() throws {
        let safe = try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, component: "valid.txt")
        XCTAssertTrue(LocalPathComponentValidator.isStrictlyContained(candidate: safe, within: tempDirectoryURL))
        XCTAssertEqual(safe.lastPathComponent, "valid.txt")
    }

    func testSafeURLMultipleComponentsStrictContainment() throws {
        let components = ["subdir", "nested", "file.log"]
        let safe = try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, components: components)
        XCTAssertTrue(LocalPathComponentValidator.isStrictlyContained(candidate: safe, within: tempDirectoryURL))
        XCTAssertEqual(safe.pathComponents.suffix(3), components)
    }

    func testStringPrefixCollisionDoesNotFalselyMatchContainment() {
        // Critical test: /root/target vs /root/target2 must NOT be considered contained!
        let root = tempDirectoryURL.appendingPathComponent("target", isDirectory: true)
        let collision = tempDirectoryURL.appendingPathComponent("target2", isDirectory: true)
        let fileInCollision = collision.appendingPathComponent("file.txt")

        XCTAssertFalse(
            LocalPathComponentValidator.isStrictlyContained(candidate: fileInCollision, within: root),
            "Candidate in /root/target2 must NOT be considered contained in /root/target"
        )
    }

    func testEqualPathDoesNotMatchStrictContainment() {
        XCTAssertFalse(
            LocalPathComponentValidator.isStrictlyContained(candidate: tempDirectoryURL, within: tempDirectoryURL),
            "Root itself is not strictly contained within itself"
        )
    }

    func testEscapesRootThrows() {
        XCTAssertThrowsError(try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, component: ".."))
        XCTAssertThrowsError(try LocalPathComponentValidator.safeURL(in: tempDirectoryURL, components: ["..", "escape.txt"]))
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
