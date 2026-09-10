import Foundation

/// issue #29:私钥门禁(Touch ID)不再每次拨号都弹。同一主机 + 同一套认证材料在本次运行内
/// 过一次门禁就登记授权,之后的断线重连、自动重连、右键「新建独立连接」直接放行。
/// 授权空闲 15 分钟失效 —— 空闲指既没有存活会话在用它,也没再过门禁;有会话连着就一直有效,
/// 断开那一刻重新起算。换密钥文件/密钥库条目/跳板机/用户名等认证材料变了要重新验证。
/// 只存内存,退出 Berth 即清空。仪表盘后台监控的授权(`ServerMonitor.authorizeKeyUse`)独立于此。
@MainActor
final class KeyUseGrants {
    static let shared = KeyUseGrants()

    /// 空闲多久后需要重新验证
    static let idleTimeout: TimeInterval = 15 * 60

    private struct Grant {
        var lastUsed: Date
        /// 正在用这份授权的存活会话数;>0 时授权不会因空闲失效
        var liveSessions = 0
    }

    private var grants: [String: Grant] = [:]
    private let now: @MainActor () -> Date
    private let isGateEnabled: @MainActor () -> Bool

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        isGateEnabled: @escaping @MainActor () -> Bool = {
            UserDefaults.standard.object(forKey: SettingsKeys.requireTouchIDForKeys) as? Bool ?? true
        }
    ) {
        self.now = now
        self.isGateEnabled = isGateEnabled
    }

    /// 拨号前调用:有效授权直接放行并续期;否则跑一次 `gate`(Touch ID),成功后登记。
    /// 门禁设置关着时既不弹也不登记 —— 之后打开设置,下一次连接就得验证。
    func authorize(_ spec: HostSpec, gate: () async throws -> Void) async throws {
        guard isGateEnabled() else { return }
        let key = Self.key(for: spec)
        if var grant = grants[key],
           grant.liveSessions > 0 || now().timeIntervalSince(grant.lastUsed) < Self.idleTimeout {
            grant.lastUsed = now()
            grants[key] = grant
            DebugLog.append("key-use grant reused host=\(spec.hostname):\(spec.port) live=\(grant.liveSessions)")
            return
        }
        try await gate()
        grants[key] = Grant(lastUsed: now(), liveSessions: grants[key]?.liveSessions ?? 0)
        DebugLog.append("key-use grant recorded host=\(spec.hostname):\(spec.port)")
    }

    /// 会话连上了:存活期间授权不失效。返回 false 表示这台主机没有授权记录
    /// (密码主机、或连接时门禁关着),调用方不必再报断开。
    @discardableResult
    func sessionConnected(_ spec: HostSpec) -> Bool {
        let key = Self.key(for: spec)
        guard var grant = grants[key] else { return false }
        grant.liveSessions += 1
        grant.lastUsed = now()
        grants[key] = grant
        return true
    }

    /// 会话断开:从这一刻起算空闲
    func sessionDisconnected(_ spec: HostSpec) {
        let key = Self.key(for: spec)
        guard var grant = grants[key] else { return }
        grant.liveSessions = max(0, grant.liveSessions - 1)
        grant.lastUsed = now()
        grants[key] = grant
    }

    /// 授权键:主机 + 链路上每一跳的认证材料
    static func key(for spec: HostSpec) -> String {
        ([spec] + spec.jump).map { hop in
            [
                hop.hostID.uuidString, hop.username, hop.hostname, String(hop.port),
                hop.authMethod.rawValue, hop.privateKeyPath ?? "", hop.keyID?.uuidString ?? "",
            ].joined(separator: "|")
        }.joined(separator: ">")
    }
}
