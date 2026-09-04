import XCTest
import NIOCore
import NIOSSH
@testable import Berth

final class SessionTerminationClassifierTests: XCTestCase {

    private struct ArbitraryError: Error, CustomStringConvertible {
        var description: String { "Some unknown internal failure" }
    }

    func testUserInitiatedReturnsUserInitiated() {
        let res1 = SessionTerminationClassifier.classify(
            error: nil,
            everConnected: true,
            userInitiated: true
        )
        XCTAssertEqual(res1, .userInitiated)

        let res2 = SessionTerminationClassifier.classify(
            error: ChannelError.alreadyClosed,
            everConnected: true,
            userInitiated: true
        )
        XCTAssertEqual(res2, .userInitiated)
    }

    func testCancellationErrorReturnsUserInitiated() {
        let res = SessionTerminationClassifier.classify(
            error: CancellationError(),
            everConnected: true,
            userInitiated: false
        )
        XCTAssertEqual(res, .userInitiated)
    }

    func testCleanExitReturnsCleanShellExit() {
        let res = SessionTerminationClassifier.classify(
            error: nil,
            everConnected: true,
            userInitiated: false
        )
        XCTAssertEqual(res, .cleanShellExit)
    }

    func testChannelErrorAlreadyClosedIsTransportFailure() {
        let res = SessionTerminationClassifier.classify(
            error: ChannelError.alreadyClosed,
            everConnected: true,
            userInitiated: false,
            hostname: "test.example.com",
            port: 22
        )
        guard case .transportFailure(let msg) = res else {
            XCTFail("Expected transportFailure, got \(res)")
            return
        }
        XCTAssertFalse(msg.isEmpty)
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: ChannelError.alreadyClosed), .channelClosed)
    }

    func testChannelErrorIoOnClosedChannelIsTransportFailure() {
        let res = SessionTerminationClassifier.classify(
            error: ChannelError.ioOnClosedChannel,
            everConnected: true,
            userInitiated: false
        )
        guard case .transportFailure = res else {
            XCTFail("Expected transportFailure, got \(res)")
            return
        }
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: ChannelError.ioOnClosedChannel), .channelClosed)
    }

    func testChannelErrorInputClosedIsTransportFailure() {
        let res = SessionTerminationClassifier.classify(
            error: ChannelError.inputClosed,
            everConnected: true,
            userInitiated: false
        )
        guard case .transportFailure = res else {
            XCTFail("Expected transportFailure, got \(res)")
            return
        }
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: ChannelError.inputClosed), .channelClosed)
    }

    func testNIOSSHErrorTcpShutdownIsTransportFailure() {
        struct MockTCPShutdownError: Error, CustomStringConvertible {
            var description: String { "NIOSSHError.tcpShutdown: TCP connection closed" }
        }
        let tcpShutdown = MockTCPShutdownError()
        let res = SessionTerminationClassifier.classify(
            error: tcpShutdown,
            everConnected: true,
            userInitiated: false,
            hostname: "test.example.com",
            port: 22
        )
        guard case .transportFailure = res else {
            XCTFail("Expected transportFailure, got \(res)")
            return
        }
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: tcpShutdown), .tcpShutdown)
    }

    func testPOSIXErrorsAreTransportFailure() {
        let codes: [(POSIXErrorCode, TransportErrorCategory)] = [
            (.ECONNRESET, .connectionReset),
            (.EHOSTUNREACH, .networkUnreachable),
            (.ENETUNREACH, .networkUnreachable),
            (.ETIMEDOUT, .timedOut),
            (.ECONNREFUSED, .connectionRefused),
        ]
        for (code, expectedCategory) in codes {
            let err = POSIXError(code)
            let res = SessionTerminationClassifier.classify(
                error: err,
                everConnected: true,
                userInitiated: false
            )
            guard case .transportFailure = res else {
                XCTFail("Expected transportFailure for \(code), got \(res)")
                continue
            }
            XCTAssertEqual(SessionTerminationClassifier.categorize(error: err), expectedCategory)
        }
    }

    func testUnknownErrorAfterConnectedIsTransportFailure() {
        // 关键原则：已连接会话遇到未知异常，绝不能因未匹配网络关键词而误判为正常 shell exit！
        let err = ArbitraryError()
        let res = SessionTerminationClassifier.classify(
            error: err,
            everConnected: true,
            userInitiated: false,
            hostname: "10.0.0.1",
            port: 22
        )
        guard case .transportFailure(let msg) = res else {
            XCTFail("Unknown error must be classified as transportFailure, but got \(res)")
            return
        }
        XCTAssertTrue(msg.contains("Some unknown internal failure") || msg.contains("连接失败"))
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: err), .unknown)
    }

    func testLocalShellExitIsTransportFailure() {
        let err = TerminalSession.SessionError.localShellExited(1, "/bin/zsh")
        let res = SessionTerminationClassifier.classify(
            error: err,
            everConnected: true,
            userInitiated: false,
            isLocal: true
        )
        guard case .transportFailure = res else {
            XCTFail("Expected transportFailure, got \(res)")
            return
        }
        XCTAssertEqual(SessionTerminationClassifier.categorize(error: err), .localShellExited)
    }

    // MARK: - PTY Cleanup Error Preservation Tests (P1-2)

    private func simulatePTYExecution(
        perform: () async throws -> Void,
        cleanupClose: () async throws -> Void
    ) async throws {
        do {
            try await perform()
            do {
                try await cleanupClose()
            } catch ChannelError.alreadyClosed, ChannelError.eof {
                // Remote already cleanly closed; benign on clean exit
            }
        } catch {
            try? await cleanupClose()
            throw error
        }
    }

    func testPTYPerformSuccessAndCleanupSuccessYieldsCleanExit() async {
        do {
            try await simulatePTYExecution(
                perform: { /* clean exit */ },
                cleanupClose: { /* channel.close() succeeds */ }
            )
            let disposition = SessionTerminationClassifier.classify(
                error: nil,
                everConnected: true,
                userInitiated: false
            )
            XCTAssertEqual(disposition, .cleanShellExit)
        } catch {
            XCTFail("Expected clean exit, but caught \(error)")
        }
    }

    func testPTYPerformSuccessAndCleanupAlreadyClosedYieldsCleanExit() async {
        do {
            try await simulatePTYExecution(
                perform: { /* clean exit */ },
                cleanupClose: { throw ChannelError.alreadyClosed }
            )
            // ChannelError.alreadyClosed absorbed during cleanup; error is nil
            let disposition = SessionTerminationClassifier.classify(
                error: nil,
                everConnected: true,
                userInitiated: false
            )
            XCTAssertEqual(disposition, .cleanShellExit)
        } catch {
            XCTFail("Expected clean exit, but cleanup alreadyClosed threw: \(error)")
        }
    }

    func testPTYPerformThrowsTcpShutdownAndCleanupAlreadyClosedPreservesTcpShutdown() async {
        struct MockTCPShutdownError: Error, CustomStringConvertible, Equatable {
            var description: String { "NIOSSHError.tcpShutdown" }
        }

        var caught: Error?
        do {
            try await simulatePTYExecution(
                perform: { throw MockTCPShutdownError() },
                cleanupClose: { throw ChannelError.alreadyClosed }
            )
            XCTFail("Should have thrown error")
        } catch {
            caught = error
        }

        XCTAssertTrue(caught is MockTCPShutdownError, "Must preserve original tcpShutdown error and NOT replace with alreadyClosed")
        let disposition = SessionTerminationClassifier.classify(
            error: caught,
            everConnected: true,
            userInitiated: false
        )
        guard case .transportFailure = disposition else {
            XCTFail("Expected transportFailure, got \(disposition)")
            return
        }
    }

    func testPTYPerformThrowsCustomErrorAAndCleanupThrowsErrorBPreservesErrorA() async {
        struct CustomErrorA: Error, Equatable {}
        struct CustomErrorB: Error, Equatable {}

        var caught: Error?
        do {
            try await simulatePTYExecution(
                perform: { throw CustomErrorA() },
                cleanupClose: { throw CustomErrorB() }
            )
            XCTFail("Should have thrown error")
        } catch {
            caught = error
        }

        XCTAssertTrue(caught is CustomErrorA, "Must preserve business error A and ignore cleanup error B")
        let disposition = SessionTerminationClassifier.classify(
            error: caught,
            everConnected: true,
            userInitiated: false
        )
        guard case .transportFailure = disposition else {
            XCTFail("Expected transportFailure, got \(disposition)")
            return
        }
    }
}
