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
}
