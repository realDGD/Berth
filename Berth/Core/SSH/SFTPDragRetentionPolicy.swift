import Foundation

/// 统一的 Finder 拖拽下载 staging 保留期策略 (Heuristic Grace Period)。
/// 注意: 由于 NSItemProvider 无法感知 Finder 等消费方何时真正完成对 staging 文件的读取与复制,
/// 此处计算的保留期仅为根据载荷大小推断的预估消费窗口 (Estimated Consumption Window),
/// 绝不代表消费方必定已复制完成。
public struct SFTPDragRetentionPolicy: Sendable, Equatable {
    public static let minimumGracePeriod: TimeInterval = 30 * 60 // 30 分钟基线
    public static let estimatedBytesPerSecond: Double = 2 * 1024 * 1024 // 假定慢速目标至少 2 MiB/s

    /// 计算指定 payloadBytes 的预估消费保留窗口。
    /// 无论单文件还是文件夹，均采用统一的单一计算源。
    public static func retentionInterval(payloadBytes: UInt64?) -> TimeInterval {
        guard let payloadBytes, payloadBytes > 0 else {
            return minimumGracePeriod
        }
        let estimatedSeconds = Double(payloadBytes) / estimatedBytesPerSecond
        return max(minimumGracePeriod, estimatedSeconds)
    }
}
