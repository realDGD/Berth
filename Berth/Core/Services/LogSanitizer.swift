import Foundation

/// 对不可信字符串 (如远端 SFTP 文件名、路径) 进行日志转义, 防止换行符伪造日志行或控制字符污染终端。
public enum LogSanitizer {
    /// 对字符串进行安全转义, 将 \n, \r, \t 及控制字符转义, 截断超长字符串。
    public static func sanitize(_ text: String, maxLength: Int = 128) -> String {
        var result = ""
        result.reserveCapacity(min(text.count * 2, maxLength))
        for scalar in text.unicodeScalars {
            if result.count >= maxLength {
                result.append("…")
                break
            }
            switch scalar.value {
            case 0x0A:
                result.append("\\n")
            case 0x0D:
                result.append("\\r")
            case 0x09:
                result.append("\\t")
            case 0x00...0x1F, 0x7F...0x9F:
                result.append(String(format: "\\x%02X", scalar.value))
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// 对远端文件名或路径进行安全转义, 仅提取 basename 并转义控制字符。
    public static func safeFilename(_ name: String) -> String {
        let basename = (name as NSString).lastPathComponent
        let target = basename.isEmpty ? name : basename
        return sanitize(target)
    }
}
