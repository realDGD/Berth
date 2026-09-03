import Foundation
import NIOCore
import NIOSSH

/// 会话终止的归类结果:
/// - `userInitiated`: 用户主动点击断开/关闭标签页,或任务被取消
/// - `cleanShellExit`: 远端 shell 正常 exit/logout (withPTY 干净返回无错误)
/// - `transportFailure`: 通道被关闭、TCP 断开、网络超时/不可达、认证失败等异常
enum SessionTerminationDisposition: Equatable, Sendable {
    case userInitiated
    case cleanShellExit
    case transportFailure(message: String)
}

/// 传输层异常的大类,用于结构化诊断日志
enum TransportErrorCategory: String, Sendable, Equatable {
    case channelClosed = "channelClosed"
    case tcpShutdown = "tcpShutdown"
    case networkUnreachable = "networkUnreachable"
    case connectionReset = "connectionReset"
    case connectionRefused = "connectionRefused"
    case timedOut = "timedOut"
    case authentication = "authentication"
    case localShellExited = "localShellExited"
    case unknown = "unknown"
}

/// 集中判定 SSH/本地终端会话终止的原因与处理策略。
/// 核心原则:
/// 1. 只有无错误干净返回(withPTY / 本地进程正常返回)且非用户取消,才判定为 cleanShellExit。
/// 2. 已连接会话遇到任何异常(包括 ChannelError.alreadyClosed、tcpShutdown、未知错误),
///    保守归类为 transportFailure,保留终端 pane 与 scrollback 并允许自动重连,
///    绝不能因为未命中网络关键词而误判为正常退出。
struct SessionTerminationClassifier: Sendable {

    static func classify(
        error: Error?,
        everConnected: Bool,
        userInitiated: Bool,
        isLocal: Bool = false,
        hostname: String = "",
        port: Int = 22,
        authMethod: AuthMethodKind? = nil
    ) -> SessionTerminationDisposition {
        if userInitiated || error is CancellationError {
            return .userInitiated
        }

        guard let error else {
            return userInitiated ? .userInitiated : .cleanShellExit
        }

        let message: String
        if isLocal {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        } else {
            message = SSHErrorMapper.friendlyMessage(
                for: error,
                hostname: hostname,
                port: port,
                authMethod: authMethod
            )
        }

        return .transportFailure(message: message)
    }

    static func categorize(error: Error) -> TransportErrorCategory {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .alreadyClosed, .ioOnClosedChannel, .inputClosed, .outputClosed, .eof:
                return .channelClosed
            default:
                return .channelClosed
            }
        }

        if let niosshError = error as? NIOSSHError {
            if niosshError.type == .tcpShutdown {
                return .tcpShutdown
            }
            return .unknown
        }

        if let posix = error as? POSIXError {
            switch posix.code {
            case .ECONNRESET, .EPIPE, .ENETRESET:
                return .connectionReset
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
                return .networkUnreachable
            case .ETIMEDOUT:
                return .timedOut
            case .ECONNREFUSED:
                return .connectionRefused
            default:
                return .unknown
            }
        }

        if error is TerminalSession.SessionError {
            return .localShellExited
        }

        if error is KeyboardInteractiveAuthError || error is SSHDialer.DialError || error is HostKeyError {
            return .authentication
        }

        let raw = String(describing: error).lowercased()
        if raw.contains("already closed") || raw.contains("channel closed") || raw.contains("closed channel") {
            return .channelClosed
        }
        if raw.contains("tcpshutdown") || raw.contains("tcp shutdown") {
            return .tcpShutdown
        }
        if raw.contains("reset") || raw.contains("broken pipe") {
            return .connectionReset
        }
        if raw.contains("unreachable") || raw.contains("no route") || raw.contains("host is down") || raw.contains("network is down") {
            return .networkUnreachable
        }
        if raw.contains("timed out") || raw.contains("timeout") {
            return .timedOut
        }
        if raw.contains("refused") {
            return .connectionRefused
        }
        if raw.contains("auth") || raw.contains("permission denied") {
            return .authentication
        }

        return .unknown
    }
}
