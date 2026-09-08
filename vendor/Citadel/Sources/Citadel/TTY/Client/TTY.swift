import Foundation
import Logging
import NIO
@preconcurrency import NIOSSH
import NIOConcurrencyHelpers

/// Represents an error that occurred while processing TTY standard error output
public struct TTYSTDError: Error {
    /// The error message as a raw byte buffer
    public let message: ByteBuffer
}

/// A pair of streams representing the stdout and stderr output of an executed command
public struct ExecCommandStream {
    /// An async stream of bytes representing the standard output
    public let stdout: AsyncThrowingStream<ByteBuffer, Error>
    /// An async stream of bytes representing the standard error
    public let stderr: AsyncThrowingStream<ByteBuffer, Error>
    
    struct Continuation {
        let stdout: AsyncThrowingStream<ByteBuffer, Error>.Continuation
        let stderr: AsyncThrowingStream<ByteBuffer, Error>.Continuation
        
        func onOutput(_ output: ExecCommandHandler.Output) {
            switch output {
            case .stdout(let buffer):
                stdout.yield(buffer)
            case .stderr(let buffer):
                stderr.yield(buffer)
            case .eof(let error):
                stdout.finish(throwing: error)
                stderr.finish(throwing: error)
            case .channelSuccess:
                ()
            case .exit(0):
                stdout.finish()
                stderr.finish()
            case .exit(let status):
                stdout.finish(throwing: SSHClient.CommandFailed(exitCode: status))
                stderr.finish(throwing: SSHClient.CommandFailed(exitCode: status))
            // [Berth patch] Preserve RFC 4254 exit-signal as explicit termination evidence.
            case .exitSignal:
                stdout.finish(throwing: SSHClient.CommandFailed(exitCode: 128))
                stderr.finish(throwing: SSHClient.CommandFailed(exitCode: 128))
            }
        }
    }
}

/// Represents the output from an executed command, either stdout or stderr data
public enum ExecCommandOutput {
    /// Standard output data as a byte buffer
    case stdout(ByteBuffer)
    /// Standard error data as a byte buffer 
    case stderr(ByteBuffer)
}

/// An async sequence that provides TTY output data
@available(macOS 15.0, *)
public struct TTYOutput: AsyncSequence {
    internal let sequence: AsyncThrowingStream<ExecCommandOutput, Error>
    public typealias Element = ExecCommandOutput

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = ExecCommandOutput
        var iterator: AsyncThrowingStream<ExecCommandOutput, Error>.AsyncIterator

        public mutating func next() async throws -> ExecCommandOutput? {
            try await iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: sequence.makeAsyncIterator())
    }
}

/// Allows writing data to a TTY's standard input and controlling terminal properties
public struct TTYStdinWriter {
    internal let channel: Channel

    /// Write raw bytes to the TTY's standard input
    /// - Parameter buffer: The bytes to write
    public func write(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    public func changeSize(cols: Int, rows: Int, pixelWidth:Int, pixelHeight:Int) async throws {
        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: pixelWidth,
                terminalPixelHeight: pixelHeight
            )
        )
    }
}

final class ExecCommandHandler: ChannelDuplexHandler, Sendable {
    enum Output {
        case channelSuccess
        case stdout(ByteBuffer)
        case stderr(ByteBuffer)
        case eof(Error?)
        case exit(Int)
        // [Berth patch] Forward exit-signal instead of discarding it as an unknown event.
        case exitSignal(String)
    }
    
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let logger: Logger
    let onOutput: @Sendable (Channel, Output) -> Void

    init(
        logger: Logger,
        onOutput: @escaping @Sendable (Channel, Output) -> Void
    ) {
        self.logger = logger
        self.onOutput = onOutput
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            self.logger.debug("Failed to set allowRemoteHalfClosure: \(error)")
            context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIOSSH.ChannelSuccessEvent:
            onOutput(context.channel, .channelSuccess)
        case is NIOSSH.ChannelFailureEvent:
            onOutput(context.channel, .eof(CitadelError.channelFailure))
        case let status as SSHChannelRequestEvent.ExitStatus:
            onOutput(context.channel, .exit(status.exitStatus))
        // [Berth patch] Capture RFC 4254 exit-signal for conservative termination classification.
        case let signal as SSHChannelRequestEvent.ExitSignal:
            onOutput(context.channel, .exitSignal(signal.signalName))
        default:
            self.logger.debug("Received unknown channel event in command handler: \(event)")
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        onOutput(context.channel, .eof(nil))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = data.data else {
            logger.error("Unable to process channelData for executed command. Data was not a ByteBuffer")
            return onOutput(context.channel, .eof(SSHExecError.invalidData))
        }
        
        switch data.type {
        case .channel:
            onOutput(context.channel, .stdout(buffer))
        case .stdErr:
            onOutput(context.channel, .stderr(buffer))
        default:
            self.logger.debug("Received channel data not known by Citadel")
            // We don't know this std channel
            ()
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onOutput(context.channel, .eof(error))
    }
}

extension SSHClient {
    /// Error thrown when a command exits with a non-zero status code
    public struct CommandFailed: Error {
        /// The exit code returned by the command
        public let exitCode: Int
    }

    /// Executes a command on the remote server and returns its output as a single buffer
    /// - Parameters:
    ///   - command: The command to execute on the remote server
    ///   - maxResponseSize: Maximum allowed size of the combined output in bytes. Defaults to Int.max
    ///   - mergeStreams: Whether to include stderr output in the result. Defaults to false
    ///   - inShell: Whether to execute the command within a shell context. Defaults to false
    /// - Returns: A ByteBuffer containing the command's output
    /// - Throws: CitadelError.commandOutputTooLarge if output exceeds maxResponseSize
    ///          CommandFailed if the command exits with non-zero status
    /// 
    /// ## Example
    /// ```swift
    /// // Simple command execution
    /// let output = try await client.executeCommand("ls -la")
    /// print(String(buffer: output))
    /// 
    /// // Execute with merged stderr and limited output size
    /// let result = try await client.executeCommand(
    ///     "find /",
    ///     maxResponseSize: 1024 * 1024, // 1MB max
    ///     mergeStreams: true
    /// )
    /// ```
    public func executeCommand(
        _ command: String,
        maxResponseSize: Int = .max,
        mergeStreams: Bool = false,
        inShell: Bool = false
    ) async throws -> ByteBuffer {
        var result = ByteBuffer()
        let stream = try await executeCommandStream(command, inShell: inShell)

        for try await chunk in stream {
            switch chunk {
            case .stderr(let chunk):
                guard mergeStreams else {
                    logger.debug("Error data received, but ignored because `mergeStreams` is disabled")
                    continue
                }

                fallthrough
            case .stdout(let chunk):
                let newResponseSize = chunk.readableBytes + result.readableBytes

                if newResponseSize > maxResponseSize {
                    throw CitadelError.commandOutputTooLarge
                }

                result.writeImmutableBuffer(chunk)
            }
        }

        return result
    }

    /// Executes a command on the remote server and returns a stream of its output
    /// - Parameters:
    ///   - command: The command to execute on the remote server
    ///   - environment: Array of environment variables to set for the command. This requires `PermitUserEnvironment` to be enabled in your OpenSSH server's configuration.
    ///   - inShell: Whether to execute the command within a shell context. Defaults to false
    /// - Returns: An async stream that yields command output as it becomes available
    /// - Throws: CommandFailed if the command exits with non-zero status
    /// 
    /// ## Example
    /// ```swift
    /// // Stream command output as it arrives
    /// let stream = try await client.executeCommandStream("tail -f /var/log/system.log")
    /// for try await output in stream {
    ///     switch output {
    ///     case .stdout(let buffer):
    ///         print("stdout:", String(buffer: buffer))
    ///     case .stderr(let buffer):
    ///         print("stderr:", String(buffer: buffer))
    ///     }
    /// }
    /// ```
    public func executeCommandStream(
        _ command: String,
        environment: [SSHChannelRequestEvent.EnvironmentRequest] = [],
        inShell: Bool = false
    ) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        try await _executeCommandStream(
            environment: environment,
            mode: inShell ? .tty(command: command) : .command(command)
        ).output
    }

    /// [Berth patch] 跟踪命令或会话流的终止状态。
    /// RFC 4254 §6.10 规定发送 exit-status 属于 RECOMMENDED (SHOULD) 而非 MUST。
    /// 为避免底层连接断开或静默拆除被误判为 cleanShellExit 导致终端 tab 被误关，
    /// Berth 刻意采用保守的 fail-closed 策略：交互式 PTY/TTY 会话必须收到明确退出证据（exit-status 或 exit-signal），
    /// EOF 才能以 clean finish 正常结束；缺少证据时产生 transport error (ChannelError.eof)。
    public struct CommandStreamTerminationState: Sendable, Equatable {
        public let isInteractive: Bool
        public var exitCode: Int?
        public var exitSignal: String?

        public init(isInteractive: Bool, exitCode: Int? = nil, exitSignal: String? = nil) {
            self.isInteractive = isInteractive
            self.exitCode = exitCode
            self.exitSignal = exitSignal
        }

        public var hasExitEvidence: Bool {
            exitCode != nil || exitSignal != nil
        }

        public func resolveTermination(error: Error?) -> Result<Void, Error> {
            if let error {
                return .failure(error)
            }
            if isInteractive {
                if hasExitEvidence {
                    return .success(())
                } else {
                    // 交互式 PTY/TTY 在未收到任何退出证据（exit-status 或 exit-signal）的情况下收到 EOF。
                    // 依据 Berth 保守的 fail-closed 策略（防范静默传输拆除误关终端），
                    // 将其判定为 transport error (ChannelError.eof)，确保上层归类为 transportFailure 并保留终端 tab。
                    return .failure(ChannelError.eof)
                }
            } else {
                if let exitCode {
                    if exitCode != 0 {
                        return .failure(SSHClient.CommandFailed(exitCode: exitCode))
                    } else {
                        return .success(())
                    }
                } else if exitSignal != nil {
                    return .failure(SSHClient.CommandFailed(exitCode: 128))
                } else {
                    return .failure(ChannelError.eof)
                }
            }
        }
    }

    enum CommandMode {
        case pty(SSHChannelRequestEvent.PseudoTerminalRequest), tty(command: String?), command(String)
    }

    internal func _executeCommandStream(
        environment: [SSHChannelRequestEvent.EnvironmentRequest] = [],
        mode: CommandMode
    ) async throws -> (channel: Channel, output: AsyncThrowingStream<ExecCommandOutput, Error>) {
        let (stream, streamContinuation) = AsyncThrowingStream<ExecCommandOutput, Error>.makeStream()

        let hasReceivedChannelSuccess = NIOLockedValueBox<Bool>(false)
        let exitCode = NIOLockedValueBox<Int?>(nil)
        let exitSignal = NIOLockedValueBox<String?>(nil)

        let isInteractive: Bool
        switch mode {
        case .pty, .tty(command: nil):
            isInteractive = true
        case .tty(command: .some), .command:
            isInteractive = false
        }

        let handler = ExecCommandHandler(logger: logger) { channel, output in
            switch output {
            case .stdout(let stdout):
                streamContinuation.yield(.stdout(stdout))
            case .stderr(let stderr):
                streamContinuation.yield(.stderr(stderr))
            case .eof(let error):
                self.logger.debug("EOF triggered, ending the command stream.")
                let state = CommandStreamTerminationState(
                    isInteractive: isInteractive,
                    exitCode: exitCode.withLockedValue({ $0 }),
                    exitSignal: exitSignal.withLockedValue({ $0 })
                )
                switch state.resolveTermination(error: error) {
                case .success:
                    streamContinuation.finish()
                case .failure(let failureError):
                    streamContinuation.finish(throwing: failureError)
                }
            case .channelSuccess:
                if case .tty(.some(let command)) = mode, !hasReceivedChannelSuccess.withLockedValue({ $0 }) {
                    let commandData = SSHChannelData(
                        type: .channel,
                        data: .byteBuffer(ByteBuffer(string: command + ";exit\n"))
                    )
                    channel.writeAndFlush(commandData, promise: nil)
                    hasReceivedChannelSuccess.withLockedValue({ $0 = true })
                }
            case .exit(let status):
                self.logger.debug("Process exited with status code \(status). Will await on EOF for correct exit")
                exitCode.withLockedValue({ $0 = status })
            case .exitSignal(let signal):
                self.logger.debug("Process exited with signal \(signal). Will await on EOF for correct exit")
                exitSignal.withLockedValue({ $0 = signal })
            }
        }

        let channel = try await eventLoop.flatSubmit { [eventLoop, sshHandler = session.sshHandler] in
            let createChannel = eventLoop.makePromise(of: Channel.self)
            sshHandler.value.createChannel(createChannel) { channel, _ in
                channel.pipeline.addHandlers(handler)
            }

            eventLoop.scheduleTask(in: .seconds(15)) {
                createChannel.fail(CitadelError.channelCreationFailed)
            }

            return createChannel.futureResult
        }.get()

        for env in environment {
            try await channel.triggerUserOutboundEvent(env)
        }

        switch mode {
        case .pty(let request):
            try await channel.triggerUserOutboundEvent(request)
            fallthrough
        case .tty:
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(
                wantReply: true
            ))
        case .command(let command):
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                command: command,
                wantReply: true
            ))
        }
        
        return (channel, stream)
    }

    /// [Berth patch] 统一的 PTY/TTY 执行与清理生命周期。
    /// 确保：
    /// 1. perform 业务异常绝对优先，cleanup 失败绝不覆盖原始业务异常。
    /// 2. 远端先行 clean close 导致的 alreadyClosed / eof 清理错误在正常退出时不抛出。
    public static func executeTTYLifecycle(
        perform: () async throws -> Void,
        cleanupClose: () async throws -> Void
    ) async throws {
        do {
            try await perform()
            do {
                try await cleanupClose()
            } catch ChannelError.alreadyClosed, ChannelError.eof {
                // [Berth patch] Remote already cleanly closed the channel; benign on clean exit
            }
        } catch {
            // [Berth patch] Cleanup is best effort; do not let cleanup error override original error
            try? await cleanupClose()
            throw error
        }
    }

    @available(macOS 15.0, *)
    internal func runTTYSession(
        channel: Channel,
        output: AsyncThrowingStream<ExecCommandOutput, Error>,
        perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void
    ) async throws {
        let inbound = TTYOutput(sequence: output)
        let outbound = TTYStdinWriter(channel: channel)
        try await SSHClient.executeTTYLifecycle(
            perform: {
                try await perform(inbound, outbound)
            },
            cleanupClose: {
                try await channel.close()
            }
        )
    }

    /// Creates a pseudo-terminal (PTY) session and executes the provided closure with input/output streams
    /// - Parameters:
    ///   - request: PTY configuration parameters
    ///   - environment: Array of environment variables to set for the PTY session. This requires `PermitUserEnvironment` to be enabled in your OpenSSH server's configuration.
    ///   - perform: Closure that receives TTY input/output streams and performs terminal operations
    /// - Throws: Any errors that occur during PTY setup or operation
    @available(macOS 15.0, *)
    public func withPTY(
        _ request: SSHChannelRequestEvent.PseudoTerminalRequest,
        environment: [SSHChannelRequestEvent.EnvironmentRequest] = [],
        perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void
    ) async throws {
        let (channel, output) = try await _executeCommandStream(
            environment: environment,
            mode: .pty(request)
        )
        try await runTTYSession(channel: channel, output: output, perform: perform)
    }

    /// Creates a TTY session and executes the provided closure with input/output streams
    /// 
    /// - Parameters:
    ///   - environment: Array of environment variables to set for the TTY session
    ///   - perform: Closure that receives TTY input/output streams and performs terminal operations
    /// - Throws: Any errors that occur during TTY setup or operation
    /// 
    /// ## Example
    /// ```swift
    /// // Create an interactive shell session
    /// try await client.withTTY { inbound, outbound in
    ///     // Send commands
    ///     try await outbound.write(ByteBuffer(string: "echo $PATH\n"))
    ///     
    ///     // Process output
    ///     for try await output in inbound {
    ///         switch output {
    ///         case .stdout(let buffer):
    ///             print(String(buffer: buffer))
    ///         case .stderr(let buffer):
    ///             print("Error:", String(buffer: buffer))
    ///         }
    ///     }
    /// }
    /// ```
    @available(macOS 15.0, *)
    public func withTTY(
        environment: [SSHChannelRequestEvent.EnvironmentRequest] = [],
        perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void
    ) async throws {
        let (channel, output) = try await _executeCommandStream(
            environment: environment,
            mode: .tty(command: nil)
        )
        try await runTTYSession(channel: channel, output: output, perform: perform)
    }

    /// Executes a command and returns separate stdout and stderr streams
    /// 
    /// Example:
    /// ```swift
    /// let client = try await SSHClient(/* ... */)
    /// 
    /// // Execute a command with separate stdout/stderr handling
    /// let streams = try await client.executeCommandPair("make")
    /// 
    /// // Handle stdout
    /// Task {
    ///     for try await output in streams.stdout {
    ///         print("stdout:", String(buffer: output))
    ///     }
    /// }
    /// 
    /// // Handle stderr
    /// Task {
    ///     for try await error in streams.stderr {
    ///         print("stderr:", String(buffer: error))
    ///     }
    /// }
    /// ```
    /// - Parameters:
    ///   - command: The command to execute on the remote server
    ///   - inShell: Whether to execute the command within a shell context. Defaults to false
    /// - Returns: An ExecCommandStream containing separate stdout and stderr streams
    /// - Throws: CommandFailed if the command exits with non-zero status
    public func executeCommandPair(_ command: String, inShell: Bool = false) async throws -> ExecCommandStream {
        var stdoutContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation!
        var stderrContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation!
        let stdout = AsyncThrowingStream<ByteBuffer, Error>(bufferingPolicy: .unbounded) { continuation in
            stdoutContinuation = continuation
        }
        
        let stderr = AsyncThrowingStream<ByteBuffer, Error>(bufferingPolicy: .unbounded) { continuation in
            stderrContinuation = continuation
        }
        
        let handler = ExecCommandStream.Continuation(
            stdout: stdoutContinuation,
            stderr: stderrContinuation
        )
        
        Task {
            do {
                let stream = try await executeCommandStream(command, inShell: inShell)
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer):
                        handler.stdout.yield(buffer)
                    case .stderr(let buffer):
                        handler.stderr.yield(buffer)
                    }
                }
                
                handler.stdout.finish()
                handler.stderr.finish()
            } catch {
                handler.stdout.finish(throwing: error)
                handler.stderr.finish(throwing: error)
            }
        }
        
        return ExecCommandStream(stdout: stdout, stderr: stderr)
    }
}
