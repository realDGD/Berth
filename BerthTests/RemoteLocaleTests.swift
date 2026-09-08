import XCTest
@testable import Berth

final class RemoteLocaleTests: XCTestCase {
    private func output(charset: String = "ANSI_X3.4-1968", all: String = "", locales: [String]) -> String {
        (["login banner", "__BERTH_LOCALE_BEGIN__", charset, all] + locales + ["__BERTH_LOCALE_END__"]).joined(separator: "\n")
    }

    func testExistingUTF8EnvironmentIsPreserved() {
        for charset in ["UTF-8", "UTF8", "utf-8"] {
            XCTAssertNil(RemoteLocale.characterLocale(from: output(charset: charset, locales: ["C.utf8"])))
        }
    }

    func testExplicitLCAllIsPreservedEvenWhenNotUTF8() {
        XCTAssertNil(RemoteLocale.characterLocale(from: output(all: "C", locales: ["C.utf8"])))
    }

    func testLegacyServerUsesOnlyInstalledLocale() {
        XCTAssertEqual(RemoteLocale.characterLocale(from: output(locales: ["C", "POSIX", "en_US.utf8"])), "en_US.utf8")
        XCTAssertNil(RemoteLocale.characterLocale(from: output(locales: ["C", "POSIX", "en_US"])))
    }

    func testPrefersCUTF8AndPreservesServerSpelling() {
        XCTAssertEqual(RemoteLocale.characterLocale(from: output(locales: ["zh_CN.UTF-8", "en_US.utf8", "C.utf8"])), "C.utf8")
        XCTAssertEqual(RemoteLocale.characterLocale(from: output(locales: ["de_DE.utf8", "en_US.UTF-8"])), "en_US.UTF-8")
        XCTAssertEqual(RemoteLocale.characterLocale(from: output(locales: ["zh_CN.utf8"])), "zh_CN.utf8")
    }

    func testMalformedOrTruncatedProbeDoesNotInjectAnything() {
        for text in ["", "locale: command not found", "__BERTH_LOCALE_BEGIN__\nC\n", "C.utf8"] {
            XCTAssertNil(RemoteLocale.characterLocale(from: text))
        }
        XCTAssertNil(RemoteLocale.characterLocale(from: output(locales: ["x.UTF-8;evil", "x.UTF-8 extra", "UTF-8"])))
    }

    func testFailedProbeFallsBack() async {
        let result = await RemoteLocale.detect { throw CocoaError(.fileReadNoPermission) }
        XCTAssertNil(result)
    }

    func testSuccessfulProbeSelectsLocale() async {
        let text = output(locales: ["en_US.utf8"])
        let result = await RemoteLocale.detect { text }
        XCTAssertEqual(result, "en_US.utf8")
    }

    func testTimeoutDoesNotWaitForUncancellableProbe() async {
        actor Gate {
            var continuation: CheckedContinuation<String, Never>?
            var released = false
            func wait() async -> String {
                if released { return "" }
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() {
                released = true
                continuation?.resume(returning: "")
                continuation = nil
            }
        }
        let gate = Gate()
        // Safety release prevents a regressed implementation from hanging the entire suite.
        let safety = Task {
            try? await Task.sleep(for: .seconds(2))
            await gate.release()
        }
        let start = ContinuousClock.now
        let result = await RemoteLocale.detect(timeout: .milliseconds(20)) { await gate.wait() }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        await gate.release()
        safety.cancel()
    }

    func testProbeScriptWithLegacyLocaleCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locale = root.appendingPathComponent("locale")
        try """
        #!/bin/sh
        case "$1" in
          charmap) printf '%s\\n' ANSI_X3.4-1968 ;;
          -a) printf '%s\\n' C POSIX en_US.utf8 ;;
          *) exit 1 ;;
        esac
        """.write(to: locale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locale.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteLocale.probeScript]
        process.environment = ["PATH": root.path, "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(RemoteLocale.characterLocale(from: String(decoding: data, as: UTF8.self)), "en_US.utf8")
    }
}
