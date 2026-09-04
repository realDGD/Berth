import XCTest
import NIOCore
import NIOSSH
import Citadel
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

    // MARK: - PTY Lifecycle & Termination State Machine Tests (M-02)

    func testPTYPerformSuccessAndCleanupSuccessYieldsCleanExit() async {
        do {
            try await SSHClient.executeTTYLifecycle(
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
            try await SSHClient.executeTTYLifecycle(
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

    func testPTYPerformThrowsAlreadyClosedPreservesErrorAndYieldsTransportFailure() async {
        var caught: Error?
        do {
            try await SSHClient.executeTTYLifecycle(
                perform: { throw ChannelError.alreadyClosed },
                cleanupClose: { throw ChannelError.alreadyClosed }
            )
            XCTFail("Should have thrown error")
        } catch {
            caught = error
        }

        guard let channelError = caught as? ChannelError, channelError == .alreadyClosed else {
            XCTFail("Expected ChannelError.alreadyClosed, got \(String(describing: caught))")
            return
        }
        let disposition = SessionTerminationClassifier.classify(
            error: channelError,
            everConnected: true,
            userInitiated: false
        )
        guard case .transportFailure = disposition else {
            XCTFail("Expected transportFailure, got \(disposition)")
            return
        }
    }

    func testPTYPerformThrowsTcpShutdownAndCleanupAlreadyClosedPreservesTcpShutdown() async {
        struct MockTCPShutdownError: Error, CustomStringConvertible, Equatable {
            var description: String { "NIOSSHError.tcpShutdown" }
        }

        var caught: Error?
        do {
            try await SSHClient.executeTTYLifecycle(
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
            try await SSHClient.executeTTYLifecycle(
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

    // MARK: - CommandStreamTerminationState Regression Tests (M-02)

    func testInteractiveTerminationStateWithExitStatusYieldsCleanFinish() {
        let stateZero = SSHClient.CommandStreamTerminationState(isInteractive: true, exitCode: 0)
        let resZero = stateZero.resolveTermination(error: nil)
        XCTAssertNoThrow(try resZero.get())

        let stateNonZero = SSHClient.CommandStreamTerminationState(isInteractive: true, exitCode: 1)
        let resNonZero = stateNonZero.resolveTermination(error: nil)
        XCTAssertNoThrow(try resNonZero.get())
    }

    func testInteractiveTerminationStateWithExitSignalYieldsCleanFinish() {
        let stateSignal = SSHClient.CommandStreamTerminationState(isInteractive: true, exitSignal: "TERM")
        let resSignal = stateSignal.resolveTermination(error: nil)
        XCTAssertNoThrow(try resSignal.get())
    }

    func testInteractiveTerminationStateWithoutExitEvidenceYieldsTransportError() {
        // Transport teardown / omitted exit evidence:
        // RFC 4254 §6.10 specifies sending exit-status is RECOMMENDED (SHOULD, not MUST).
        // Berth deliberately adopts a conservative fail-closed policy requiring explicit exit evidence
        // (exit-status or exit-signal) for interactive PTY/TTY sessions to distinguish clean exit from transport teardown.
        let stateTeardown = SSHClient.CommandStreamTerminationState(isInteractive: true, exitCode: nil, exitSignal: nil)
        let resTeardown = stateTeardown.resolveTermination(error: nil)
        switch resTeardown {
        case .success:
            XCTFail("Must not succeed without exit evidence")
        case .failure(let err):
            guard let channelError = err as? ChannelError, channelError == .eof else {
                XCTFail("Expected ChannelError.eof, got \(err)")
                return
            }
            let disposition = SessionTerminationClassifier.classify(
                error: channelError,
                everConnected: true,
                userInitiated: false
            )
            guard case .transportFailure = disposition else {
                XCTFail("Expected transportFailure, got \(disposition)")
                return
            }
        }
    }

    func testInteractiveTerminationStateWithOriginalErrorPreservesError() {
        struct MockNetworkError: Error, Equatable {}
        let state = SSHClient.CommandStreamTerminationState(isInteractive: true, exitCode: 0)
        let res = state.resolveTermination(error: MockNetworkError())
        switch res {
        case .success:
            XCTFail("Must fail when original error is present")
        case .failure(let err):
            XCTAssertTrue(err is MockNetworkError)
        }
    }

    func testNonInteractiveTerminationStateResolutions() {
        let successCommand = SSHClient.CommandStreamTerminationState(isInteractive: false, exitCode: 0)
        XCTAssertNoThrow(try successCommand.resolveTermination(error: nil).get())

        let failedCommand = SSHClient.CommandStreamTerminationState(isInteractive: false, exitCode: 2)
        switch failedCommand.resolveTermination(error: nil) {
        case .success:
            XCTFail("Must fail with non-zero exit code")
        case .failure(let err):
            XCTAssertTrue(err is SSHClient.CommandFailed)
            XCTAssertEqual((err as? SSHClient.CommandFailed)?.exitCode, 2)
        }

        let missingEvidenceCommand = SSHClient.CommandStreamTerminationState(isInteractive: false, exitCode: nil)
        switch missingEvidenceCommand.resolveTermination(error: nil) {
        case .success:
            XCTFail("Must fail without exit code")
        case .failure(let err):
            XCTAssertEqual(err as? ChannelError, .eof)
        }
    }
}
