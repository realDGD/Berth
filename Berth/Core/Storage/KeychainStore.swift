import Foundation
import Security

/// Keychain 封装:密码与 passphrase 只存 Keychain(数据库不落明文,按约定命名引用)。
///
/// 跨设备直连的关键三要素:
/// 1. **共享访问组** `<TeamID>.com.berthssh.shared`:Mac(com.berthssh.app)与 iOS
///    (com.berthssh.ios)bundle id 不同,默认访问组也不同,互相读不到对方写的项。
///    两端 entitlement 都声明同一个 keychain-access-group,才能共享。
/// 2. **数据保护钥匙串** `kSecUseDataProtectionKeychain`:macOS 默认用老式文件钥匙串,
///    不进 iCloud 同步也不支持访问组;显式切到 iOS 同款数据保护钥匙串。
/// 3. **可同步** `kSecAttrSynchronizable`:经 iCloud 钥匙串端到端加密同步。Berth 无自有服务器。
enum KeychainStore {
    static let service = "com.berthssh.app"
    /// 与 project.yml 里两端 entitlement 的 `$(AppIdentifierPrefix)com.berthssh.shared` 一致
    static let accessGroup = "99LYH6FNPS.com.berthssh.shared"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(errSecAuthFailed):
                return String(localized: "无法读取钥匙串中保存的密码(应用签名与保存时不一致,常见于开发构建更新后)。")
                    + String(localized: "请编辑该主机并重新输入密码,保存后即可恢复。")
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return String(localized: "Keychain 操作失败:\(detail)")
            }
        }
    }

    // MARK: 账户命名约定

    static func passwordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).password" }
    static func passphraseAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).passphrase" }
    static func proxyPasswordAccount(for hostID: UUID) -> String { "host.\(hostID.uuidString).proxyPassword" }

    // MARK: 基本操作

    /// 共享组 + 数据保护 + 可同步的基础查询;`sync` 传 SynchronizableAny 供读/删跨同步态匹配
    private static func baseQuery(account: String, syncAny: Bool = false) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: syncAny ? kSecAttrSynchronizableAny : true,
        ]
    }

    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecAuthFailed || status == errSecItemNotFound {
            // 覆盖历史遗留(本机-only 旧项,或 ACL 绑定在别的构建上的项):删掉重建
            SecItemDelete(baseQuery(account: account, syncAny: true) as CFDictionary)
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func read(account: String) throws -> String? {
        var query = baseQuery(account: account, syncAny: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return adoptLegacyItem(account: account)
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account, syncAny: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: 旧位置的机密:按需迁移

    /// 共享组里没有这一条 → 到旧位置找,找到就顺手搬进来。
    ///
    /// 早先是启动时全量扫描搬迁。问题是旧项的 ACL 绑在老签名上,每读一条系统就弹一次
    /// 钥匙串授权 —— 几十条凭据就是几十个弹窗糊在启动画面上,且用户根本不知道在干嘛。
    /// 改成按需之后,只有真的要用某个主机的凭据时才可能弹一次,而且上下文清楚
    /// (正在连这台机器)。选「始终允许」后不再出现。
    private static func adoptLegacyItem(account: String) -> String? {
        guard let secret = readLegacyItem(account: account) else { return nil }
        try? save(secret, account: account)
        return secret
    }

    /// 旧位置 = 同 service 名下的「非共享组 / 老式文件钥匙串」项
    private static func readLegacyItem(account: String) -> String? {
        #if os(macOS)
        let dataProtectionVariants = [false, true]
        #else
        let dataProtectionVariants = [true]
        #endif

        for dataProtection in dataProtectionVariants {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            query[kSecUseDataProtectionKeychain as String] = dataProtection
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8)
            else { continue }
            return secret
        }
        return nil
    }

    /// 删除主机相关的全部凭据(删除主机时调用)
    static func deleteSecrets(for hostID: UUID) {
        try? delete(account: passwordAccount(for: hostID))
        try? delete(account: passphraseAccount(for: hostID))
        try? delete(account: proxyPasswordAccount(for: hostID))
    }
}
