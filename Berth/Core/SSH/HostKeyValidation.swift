import Foundation
import NIOCore
import NIOSSH

/// 等待用户决策的主机密钥信息(UI 弹窗数据)
struct HostKeyPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        /// known_hosts 里没有这台主机
        case firstConnection
        /// 同类型密钥与记录不一致
        case keyChanged
        /// 主机已知,但出示了未记录过的密钥类型(中间人可能只提供另一种类型来绕过比对)
        case newKeyType
    }

    let id = UUID()
    let kind: Kind
    let hostname: String
    let port: Int
    let keyType: String
    let fingerprint: String
    /// 已记录的指纹:keyChanged 为同类型旧指纹;newKeyType 为其它类型指纹;首次连接为空
    let knownFingerprints: [String]

    /// 非首次连接:按变更级别警告,必须显式确认
    var isKeyChange: Bool { kind != .firstConnection }
}

struct HostKeyError: LocalizedError, Equatable {
    enum Kind {
        case rejectedByUser
        case changedRejected
        case certificateNotSupported
    }

    let kind: Kind

    var errorDescription: String? {
        switch kind {
        case .rejectedByUser:
            return String(localized: "已取消连接:你没有信任该服务器的主机密钥。")
        case .changedRejected:
            return String(localized: "已中止连接:服务器主机密钥与 known_hosts 记录不一致,可能存在中间人攻击。确认服务器确实更换过密钥后,可在连接时选择更新。")
        case .certificateNotSupported:
            return String(localized: "已中止连接:服务器出示了证书形式的主机密钥,Berth 未启用证书认证,无法核验其真实性。")
        }
    }
}

/// known_hosts 校验:一致放行;未知/变更 → 通过 decisionHandler 请求 UI 决策。
/// 首次信任写入 known_hosts;变更且显式确认后替换旧条目。
final class InteractiveHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let hostname: String
    private let port: Int
    private let store: KnownHostsStore
    private let decisionHandler: @Sendable (HostKeyPrompt) async -> Bool
    /// 首次连接(未知主机密钥)是否静默信任并记住,不弹确认。默认关闭,Mac/iOS 都要核对指纹;
    /// 只对「未知主机」生效,已知主机换密钥或换密钥类型永远强制确认。
    private let autoTrustUnknown: Bool

    init(
        hostname: String,
        port: Int,
        store: KnownHostsStore = KnownHostsStore(),
        autoTrustUnknown: Bool = false,
        decisionHandler: @escaping @Sendable (HostKeyPrompt) async -> Bool
    ) {
        self.hostname = hostname
        self.port = port
        self.store = store
        self.autoTrustUnknown = autoTrustUnknown
        self.decisionHandler = decisionHandler
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Berth 从不协商 *-cert-v01@openssh.com 主机密钥算法;服务器却送来证书 blob 时,
        // nio-ssh 会按其基础类型放行签名校验,而 known_hosts 无法比对证书,一律拒绝。
        let presentedType = KnownHostsStore.keyType(of: hostKey)
        guard !presentedType.hasSuffix("-cert-v01@openssh.com") else {
            validationCompletePromise.fail(HostKeyError(kind: .certificateNotSupported))
            return
        }

        let evaluation = store.evaluate(hostname: hostname, port: port, presentedKey: hostKey)

        switch evaluation {
        case .trusted:
            validationCompletePromise.succeed(())

        case .unknown:
            if autoTrustUnknown {
                // 首次连接静默信任:记住密钥,不打扰。写入失败不阻断本次连接。
                try? store.append(hostname: hostname, port: port, key: hostKey)
                validationCompletePromise.succeed(())
                return
            }
            let prompt = HostKeyPrompt(
                kind: .firstConnection,
                hostname: hostname,
                port: port,
                keyType: presentedType,
                fingerprint: KnownHostsStore.fingerprint(of: hostKey),
                knownFingerprints: []
            )
            resolve(prompt, hostKey: hostKey, promise: validationCompletePromise, rejection: HostKeyError(kind: .rejectedByUser))

        case .mismatch(let knownFingerprints):
            let prompt = HostKeyPrompt(
                kind: .keyChanged,
                hostname: hostname,
                port: port,
                keyType: presentedType,
                fingerprint: KnownHostsStore.fingerprint(of: hostKey),
                knownFingerprints: knownFingerprints
            )
            resolve(prompt, hostKey: hostKey, promise: validationCompletePromise, rejection: HostKeyError(kind: .changedRejected))

        case .newKeyType(let knownFingerprints):
            // 已知主机换了密钥类型:不受 autoTrustUnknown 影响,与密钥变更同级处理
            let prompt = HostKeyPrompt(
                kind: .newKeyType,
                hostname: hostname,
                port: port,
                keyType: presentedType,
                fingerprint: KnownHostsStore.fingerprint(of: hostKey),
                knownFingerprints: knownFingerprints
            )
            resolve(prompt, hostKey: hostKey, promise: validationCompletePromise, rejection: HostKeyError(kind: .changedRejected))
        }
    }

    private func resolve(
        _ prompt: HostKeyPrompt,
        hostKey: NIOSSHPublicKey,
        promise: EventLoopPromise<Void>,
        rejection: HostKeyError
    ) {
        let store = store
        let hostname = hostname
        let port = port
        let handler = decisionHandler
        Task {
            if await handler(prompt) {
                do {
                    if prompt.isKeyChange {
                        try store.replace(hostname: hostname, port: port, key: hostKey)
                    } else {
                        try store.append(hostname: hostname, port: port, key: hostKey)
                    }
                } catch {
                    // 写入失败不阻断本次连接,下次仍会再询问
                }
                promise.succeed(())
            } else {
                promise.fail(rejection)
            }
        }
    }
}
