import XCTest
@testable import Berth

@MainActor
final class KeyUseGrantsTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var gateEnabled = true

    private func makeGrants() -> KeyUseGrants {
        KeyUseGrants(now: { [unowned self] in self.clock }, isGateEnabled: { [unowned self] in self.gateEnabled })
    }

    private func spec(
        hostID: UUID = UUID(),
        username: String = "dev",
        keyPath: String? = "~/.ssh/id_ed25519",
        jump: [HostSpec] = []
    ) -> HostSpec {
        HostSpec(
            hostID: hostID, label: "a", hostname: "a.example", port: 22, username: username,
            authMethod: .privateKeyFile, privateKeyPath: keyPath, jump: jump
        )
    }

    struct GateDenied: Error {}

    /// 跑一次 authorize,返回 gate(Touch ID)被调用的次数
    private func gateCalls(_ grants: KeyUseGrants, _ spec: HostSpec, deny: Bool = false) async throws -> Int {
        var calls = 0
        try await grants.authorize(spec) {
            calls += 1
            if deny { throw GateDenied() }
        }
        return calls
    }

    func testReconnectWithinTimeoutSkipsGate() async throws {
        let grants = makeGrants()
        let host = spec()
        let first = try await gateCalls(grants, host)
        XCTAssertEqual(first, 1)
        clock += 14 * 60
        let second = try await gateCalls(grants, host)
        XCTAssertEqual(second, 0)
    }

    func testIdleTimeoutRequiresGateAgain() async throws {
        let grants = makeGrants()
        let host = spec()
        _ = try await gateCalls(grants, host)
        clock += KeyUseGrants.idleTimeout + 1
        let again = try await gateCalls(grants, host)
        XCTAssertEqual(again, 1)
    }

    func testEachUseRefreshesIdleClock() async throws {
        let grants = makeGrants()
        let host = spec()
        _ = try await gateCalls(grants, host)
        for _ in 0..<3 {
            clock += 10 * 60
            let calls = try await gateCalls(grants, host)
            XCTAssertEqual(calls, 0, "use within the timeout must keep the grant alive")
        }
    }

    func testLiveSessionKeepsGrantAliveAndDisconnectRestartsIdle() async throws {
        let grants = makeGrants()
        let host = spec()
        _ = try await gateCalls(grants, host)
        XCTAssertTrue(grants.sessionConnected(host))

        // 会话连着 2 小时:右键新建独立连接不弹
        clock += 2 * 60 * 60
        let whileLive = try await gateCalls(grants, host)
        XCTAssertEqual(whileLive, 0)

        // 服务器重启把会话掐断:14 分钟内重连不弹(这次放行也会续期),之后再闲满 15 分钟才弹
        grants.sessionDisconnected(host)
        clock += 14 * 60
        let soonAfter = try await gateCalls(grants, host)
        XCTAssertEqual(soonAfter, 0)
        clock += KeyUseGrants.idleTimeout + 1
        let muchLater = try await gateCalls(grants, host)
        XCTAssertEqual(muchLater, 1)
    }

    func testChangedCredentialMaterialPromptsAgain() async throws {
        let grants = makeGrants()
        let id = UUID()
        _ = try await gateCalls(grants, spec(hostID: id))

        let otherKey = try await gateCalls(grants, spec(hostID: id, keyPath: "~/.ssh/id_rsa"))
        XCTAssertEqual(otherKey, 1, "different IdentityFile must re-verify")
        let viaJump = try await gateCalls(grants, spec(hostID: id, jump: [spec()]))
        XCTAssertEqual(viaJump, 1, "added jump host must re-verify")
        let otherUser = try await gateCalls(grants, spec(hostID: id, username: "root"))
        XCTAssertEqual(otherUser, 1, "different user must re-verify")
        let otherHost = try await gateCalls(grants, spec())
        XCTAssertEqual(otherHost, 1, "another host must re-verify")

        // 原来那套材料的授权仍然有效
        let original = try await gateCalls(grants, spec(hostID: id))
        XCTAssertEqual(original, 0)
    }

    func testFailedGateLeavesNoGrant() async throws {
        let grants = makeGrants()
        let host = spec()
        do {
            _ = try await gateCalls(grants, host, deny: true)
            XCTFail("denied gate must throw")
        } catch is GateDenied {}
        let retry = try await gateCalls(grants, host)
        XCTAssertEqual(retry, 1)
    }

    func testDisabledGateNeitherPromptsNorRecords() async throws {
        let grants = makeGrants()
        let host = spec()
        gateEnabled = false
        let off = try await gateCalls(grants, host)
        XCTAssertEqual(off, 0)
        XCTAssertFalse(grants.sessionConnected(host), "no grant is recorded while the gate is off")
        gateEnabled = true
        let on = try await gateCalls(grants, host)
        XCTAssertEqual(on, 1, "turning the gate on must verify on the next connection")
    }
}
