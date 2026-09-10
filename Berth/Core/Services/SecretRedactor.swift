import Foundation

/// 把命令输出里像机密的片段打码,再落盘/喂给模型。远端输出既是攻击者可控的,
/// 也经常无意带出私钥与 token(cat ~/.ssh/id_rsa、env、kubectl get secret -o yaml …)。
/// 终端与 UI 里仍显示原文,只有持久化的聊天历史与送往 AI 端点的 tool_result 被脱敏。
enum SecretRedactor {
    static let placeholder = "[REDACTED]"

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = [
        // PEM 私钥/证书私钥块
        rule("-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----"),
        // OpenSSH 公钥行不算机密,但 authorized_keys/known_hosts 的私钥不会出现在这里
        // 云厂商 / 平台 token
        rule("\\bAKIA[0-9A-Z]{16}\\b"),
        rule("\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\\b"),
        rule("\\bgithub_pat_[A-Za-z0-9_]{22,}\\b"),
        rule("\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        rule("\\bAIza[0-9A-Za-z_-]{35}\\b"),
        rule("\\bsk-ant-[A-Za-z0-9_-]{20,}\\b"),
        rule("\\bsk-[A-Za-z0-9_-]{32,}\\b"),
        rule("\\bglpat-[A-Za-z0-9_-]{20,}\\b"),
        // JWT
        rule("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"),
        // Authorization 头
        rule("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=-]{16,}", template: "$1 " + placeholder),
        // crypt(3) 口令哈希(/etc/shadow、htpasswd)
        rule("\\$(?:1|2[aby]?|5|6|y|argon2id?)\\$[^\\s:]{8,}"),
        // key=value / key: value 形式,只打码值,保留键名方便模型理解结构
        rule("(?i)\\b([A-Z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|client[_-]?secret)[A-Z0-9_.-]*)(\\s*[=:]\\s*)[\"']?[^\\s\"',;]{4,}[\"']?",
             template: "$1$2" + placeholder),
        // 数据库/URL 里内嵌的口令 scheme://user:pass@host
        rule("(?i)\\b([a-z][a-z0-9+.-]*://[^\\s:/@]+:)[^\\s@/]{3,}@", template: "$1" + placeholder + "@"),
    ]

    private static func rule(_ pattern: String, template: String = placeholder) -> Rule {
        // 模式是常量,编译失败属于编程错误
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
    }

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }
}
