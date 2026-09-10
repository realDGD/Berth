import Foundation
import Observation

/// 一条聊天消息(用户或 AI)。assistant 消息的正文流式追加,工具调用以卡片形式挂在消息下。
@MainActor
@Observable
final class AIChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var toolCalls: [AIToolCall] = []
    /// 请求失败时的错误说明(展示在消息底部)
    var errorText: String?

    init(role: Role, text: String = "") {
        self.role = role
        self.text = text
    }
}

/// AI 请求执行的一条服务器命令(run_command 工具调用)
@MainActor
@Observable
final class AIToolCall: Identifiable {
    enum Status {
        case awaitingApproval
        case running
        case done
        case denied
    }

    let id: String
    let command: String
    var status: Status
    var output = ""
    var exitCode: Int?
    var isOutputExpanded = false

    init(id: String, command: String, status: Status) {
        self.id = id
        self.command = command
        self.status = status
    }
}

/// 每个终端会话一份的 AI 对话控制器:维护 UI 消息与 API 消息历史,驱动
/// 请求 → 工具调用(经用户确认)→ 回传结果 的循环。命令经会话的 SSH 连接
/// 在独立 exec 通道上执行,不影响终端 PTY。
@MainActor
@Observable
final class AIChatController {
    private(set) var messages: [AIChatMessage] = []
    private(set) var isBusy = false
    /// 当前对话在历史库里的身份;「新对话」换新 id,旧对话留在历史里
    private(set) var conversationID = UUID()
    @ObservationIgnored private var conversationCreatedAt = Date()

    private weak var session: TerminalSession?
    private let spec: HostSpec
    /// API 侧对话历史(原始 content 块,thinking/tool_use 原样回传)
    @ObservationIgnored private var apiMessages: [[String: Any]] = []
    @ObservationIgnored private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 回传给模型的单条命令输出上限(超出截断中段)
    private static let maxToolOutputChars = 12000

    /// 终端当前目录的来源与可信度,三层递进:OSC 7 上报(精确)→ 连接内进程探测
    /// (零配置兜底,可能多候选)→ 未知(提示词里如实说明并让 AI 引导启用命令集成)。
    /// 给模型的信息必须与来源的真实可信度一致 —— 探测值标注"推断",多候选如实列出。
    private enum WorkingDirectoryContext {
        case reported(String)
        case probed([String])
        case unknown
    }
    @ObservationIgnored private var cwdContext: WorkingDirectoryContext = .unknown

    init(session: TerminalSession) {
        self.session = session
        self.spec = session.spec
    }

    // MARK: - 对外操作

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        guard let client = AISettings.makeClient() else { return }

        messages.append(AIChatMessage(role: .user, text: trimmed))
        apiMessages.append(["role": "user", "content": trimmed])
        persist()
        isBusy = true
        task = Task { [weak self] in
            await self?.runLoop(client: client)
            self?.isBusy = false
            self?.persist()
        }
    }

    /// 终端选中的报错/输出:包成一条带上下文的提问发出去
    func askAbout(_ selection: String) {
        let prompt = String(localized: "解释下面这段终端输出,如果是报错请给出原因和修复办法:")
            + "\n\n```\n" + selection + "\n```"
        send(prompt)
    }

    /// 停止当前请求(取消网络流;待确认的命令按拒绝处理)
    func stop() {
        task?.cancel()
        for (id, continuation) in approvals {
            approvals[id] = nil
            continuation.resume(returning: false)
        }
    }

    func clear() {
        stop()
        messages = []
        apiMessages = []
    }

    /// 开新对话:当前对话已在各一致点落盘,留在历史里;这里只换身份并清空
    func startNewConversation() {
        clear()
        conversationID = UUID()
        conversationCreatedAt = Date()
    }

    /// 删除当前对话(含历史文件),并转为一个全新对话
    func discardCurrentConversation() {
        AIChatHistory.delete(id: conversationID)
        startNewConversation()
    }

    /// 从历史加载一个对话接着聊(会停掉进行中的请求)
    func loadConversation(id: UUID) {
        guard let record = AIChatHistory.load(id: id) else { return }
        clear()
        conversationID = id
        conversationCreatedAt = Date(
            timeIntervalSince1970: record["createdAt"] as? Double ?? Date().timeIntervalSince1970)
        messages = (record["messages"] as? [[String: Any]] ?? []).map(Self.restoreMessage)
        var api = record["api"] as? [[String: Any]] ?? []
        // 防御:历史若停在 assistant 的 tool_use 上(异常退出),补中断 tool_result 配平,
        // 否则下一次请求会因悬空 tool_use 被 API 拒收
        if let last = api.last, last["role"] as? String == "assistant",
           let content = last["content"] as? [[String: Any]] {
            let results: [[String: Any]] = content
                .filter { $0["type"] as? String == "tool_use" }
                .compactMap { use in
                    guard let useID = use["id"] as? String else { return nil }
                    return ["type": "tool_result", "tool_use_id": useID,
                            "content": "Interrupted: the app quit before this command finished.",
                            "is_error": true]
                }
            if !results.isEmpty { api.append(["role": "user", "content": results]) }
        }
        apiMessages = api
    }

    // MARK: - 历史持久化

    /// 只在 apiMessages 一致点调用(用户消息后 / 工具结果配平后 / 回合结束)
    private func persist() {
        guard !messages.isEmpty else { return }
        let title = messages.first(where: { $0.role == .user })?.text
            .components(separatedBy: .newlines).first?.prefix(60)
        AIChatHistory.save([
            "id": conversationID.uuidString,
            "hostKey": AIChatHistory.hostKey(for: spec),
            "hostLabel": spec.label,
            "createdAt": conversationCreatedAt.timeIntervalSince1970,
            "updatedAt": Date().timeIntervalSince1970,
            "title": String(title ?? ""),
            "messages": messages.map(Self.messageRecord),
            "api": apiMessages,
        ])
    }

    private static func messageRecord(_ message: AIChatMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": message.role == .user ? "user" : "assistant",
            "text": message.text,
        ]
        if let errorText = message.errorText { dict["error"] = errorText }
        if !message.toolCalls.isEmpty {
            dict["toolCalls"] = message.toolCalls.map { call -> [String: Any] in
                var record: [String: Any] = [
                    "id": call.id,
                    "command": call.command,
                    // 历史文件里不留原始机密;UI 内存里的 call.output 仍是原文
                    "output": SecretRedactor.redact(call.output),
                    // 进行中/待确认的状态没有意义了,落盘时归到最近的终态
                    "denied": call.status == .denied || call.status == .awaitingApproval,
                ]
                if let code = call.exitCode { record["exitCode"] = code }
                return record
            }
        }
        return dict
    }

    private static func restoreMessage(_ dict: [String: Any]) -> AIChatMessage {
        let message = AIChatMessage(
            role: dict["role"] as? String == "user" ? .user : .assistant,
            text: dict["text"] as? String ?? "")
        message.errorText = dict["error"] as? String
        message.toolCalls = (dict["toolCalls"] as? [[String: Any]] ?? []).map { record in
            let call = AIToolCall(
                id: record["id"] as? String ?? UUID().uuidString,
                command: record["command"] as? String ?? "",
                status: record["denied"] as? Bool == true ? .denied : .done)
            call.output = record["output"] as? String ?? ""
            call.exitCode = record["exitCode"] as? Int
            return call
        }
        return message
    }

    func approve(_ call: AIToolCall) { resolveApproval(call, allowed: true) }
    func deny(_ call: AIToolCall) { resolveApproval(call, allowed: false) }

    private func resolveApproval(_ call: AIToolCall, allowed: Bool) {
        guard let continuation = approvals[call.id] else { return }
        approvals[call.id] = nil
        continuation.resume(returning: allowed)
    }

    // MARK: - 请求循环

    private func runLoop(client: AIChatClient) async {
        cwdContext = await resolveWorkingDirectory()
        // 单条用户消息最多允许的 请求→工具 循环轮数(防失控),可在设置里调
        for _ in 0..<AISettings.maxCommandRounds {
            let assistant = AIChatMessage(role: .assistant)
            messages.append(assistant)

            let turn: AIChatTurn
            do {
                turn = try await client.complete(
                    system: systemPrompt(),
                    messages: apiMessages,
                    tools: [Self.runCommandTool],
                    onTextDelta: { delta in
                        Task { @MainActor in assistant.text += delta }
                    }
                )
            } catch is CancellationError {
                assistant.errorText = String(localized: "已停止")
                return
            } catch {
                if Task.isCancelled {
                    assistant.errorText = String(localized: "已停止")
                } else {
                    assistant.errorText = error.localizedDescription
                }
                return
            }

            // 以最终结果为准覆盖流式文本(网络中断时流式文本可能不完整)
            let fullText = turn.content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !fullText.isEmpty { assistant.text = fullText }
            apiMessages.append(["role": "assistant", "content": turn.content])

            let toolUses = turn.content.filter {
                $0["type"] as? String == "tool_use" && $0["name"] as? String == "run_command"
            }

            switch turn.stopReason {
            case "tool_use" where !toolUses.isEmpty:
                var results: [[String: Any]] = []
                for use in toolUses {
                    guard let useID = use["id"] as? String else { continue }
                    let command = ((use["input"] as? [String: Any])?["command"] as? String) ?? ""
                    let result = await executeToolCall(id: useID, command: command, message: assistant)
                    results.append(result)
                }
                // 全部 tool_result 放进同一条 user 消息
                apiMessages.append(["role": "user", "content": results])
                persist() // 一致点:tool_use 已配平,中途退出也能完整恢复
                if Task.isCancelled { return }
                continue
            case "refusal":
                if assistant.text.isEmpty {
                    assistant.errorText = String(localized: "AI 出于安全策略拒绝了这次请求。")
                }
                return
            case "max_tokens":
                assistant.errorText = String(localized: "回复超长被截断,可让 AI 继续。")
                return
            default:
                if assistant.text.isEmpty && assistant.toolCalls.isEmpty {
                    assistant.errorText = String(localized: "AI 没有返回内容。")
                }
                return
            }
        }
        messages.last?.errorText = String(localized: "已达到单次对话的命令轮数上限,请继续对话让 AI 接着做。")
    }

    /// 执行一条 run_command:按需等待用户确认 → SSH exec → 组装 tool_result
    private func executeToolCall(id: String, command: String, message: AIChatMessage) async -> [String: Any] {
        func result(_ text: String, isError: Bool = false) -> [String: Any] {
            ["type": "tool_result", "tool_use_id": id, "content": text, "is_error": isError]
        }

        guard !command.isEmpty else {
            return result("Empty command.", isError: true)
        }

        // 自动执行只放行白名单内的只读诊断命令(AICommandPolicy);生产主机一律确认。
        // 关键词黑名单拦不住提示注入吐出的 curl|sh、写 authorized_keys 之类
        let needsApproval = !AISettings.autoRunCommands
            || !AICommandPolicy.isSafeForAutoRun(command)
            || spec.isProduction
        let call = AIToolCall(id: id, command: command, status: needsApproval ? .awaitingApproval : .running)
        message.toolCalls.append(call)

        if needsApproval {
            let allowed = await withCheckedContinuation { continuation in
                approvals[id] = continuation
            }
            guard allowed else {
                call.status = .denied
                return result("User declined to run this command. Ask before trying an alternative.")
            }
            call.status = .running
        }

        guard let session, let outcome = await session.runAICommand(command, startingDirectory: autoStartDirectory) else {
            call.status = .done
            call.output = String(localized: "会话未连接,无法执行命令。")
            return result("Not connected to the server; the command was not run.", isError: true)
        }

        call.output = outcome.output
        call.exitCode = outcome.exitCode
        call.status = .done

        // 送给模型(以及随 apiMessages 落盘)的输出先脱敏:私钥、token、口令哈希不出这台 Mac
        var text = Self.truncated(SecretRedactor.redact(outcome.output))
        if let code = outcome.exitCode {
            text += "\n[exit code: \(code)]"
        }
        return result(text, isError: (outcome.exitCode ?? 0) != 0)
    }

    /// 超长输出截中段,保留头尾(模型侧;UI 展示完整输出)
    private static func truncated(_ output: String) -> String {
        guard output.count > maxToolOutputChars else { return output }
        let head = output.prefix(maxToolOutputChars * 3 / 4)
        let tail = output.suffix(maxToolOutputChars / 4)
        return head + "\n…[output truncated, \(output.count) chars total]…\n" + tail
    }

    // MARK: - 提示词与工具定义

    private func systemPrompt() -> String {
        var lines: [String] = [
            "You are the built-in server-operations assistant of Berth, a macOS SSH client.",
            "Current SSH session: \(spec.username)@\(spec.hostname):\(spec.port) (labeled \"\(spec.label)\").",
            "Use the run_command tool to run shell commands on that server; it returns merged stdout/stderr and the exit code.",
            "Rules:",
            "- Reply in the user's language, concise and direct.",
            "- Commands must be non-interactive: never use TUIs (top/vim/less/htop); use flags like `top -b -n 1`, `--no-pager`, `-y` instead.",
            "- Prefer read-only inspection first. Before destructive actions (delete, restart services, edit configs), explain the impact.",
            "- Output may be truncated; run narrower follow-up commands when you need more.",
        ]
        if spec.isProduction {
            lines.append("- ⚠️ This host is marked as PRODUCTION. Be extra careful; avoid risky changes unless explicitly asked.")
        }
        if let cwd = session?.currentRemoteDirectory {
            // OSC 7 可能在对话中途才开始上报(比如用户刚 cd),读实时值优先于探测缓存
            lines.append("The user's terminal is currently in \(cwd) (reported by shell integration). run_command starts there automatically.")
        } else {
            switch cwdContext {
            case .probed(let dirs) where dirs.count == 1:
                lines.append("The user's terminal appears to be in \(dirs[0]) — inferred from the remote shell process; usually correct but not authoritative. run_command starts there automatically; verify with pwd before anything destructive.")
            case .probed(let dirs):
                lines.append("Multiple terminals share this connection; the user's working directory is one of: \(dirs.joined(separator: ", ")) (inferred from shell processes). run_command starts in the login directory — cd yourself based on context, or ask the user which one they mean.")
            case .reported, .unknown:
                lines.append("The user's terminal working directory is unknown (shell integration is not enabled on this host and no shell process could be probed). run_command starts in the login directory. If the user refers to their current directory, ask them for the path, and mention that enabling Berth's command integration (one-click install in the server info panel, ⌘I) lets you know it automatically.")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 每条用户消息发出前解析一次当前目录:OSC 7 实时值优先,缺席时做一次连接内探测。
    /// 探测只在这里做(不逐工具轮做),一次 exec 往返,失败静默降级为 unknown。
    private func resolveWorkingDirectory() async -> WorkingDirectoryContext {
        guard let session else { return .unknown }
        if let cwd = session.currentRemoteDirectory { return .reported(cwd) }
        let probed = await session.probeRemoteWorkingDirectories()
        return probed.isEmpty ? .unknown : .probed(probed)
    }

    /// run_command 自动 cd 的目标:OSC 7 实时值,或探测出的唯一候选;多候选/未知时不自动 cd
    private var autoStartDirectory: String? {
        if let cwd = session?.currentRemoteDirectory { return cwd }
        if case .probed(let dirs) = cwdContext, dirs.count == 1 { return dirs[0] }
        return nil
    }

    private static let runCommandTool: [String: Any] = [
        "name": "run_command",
        "description": "Run a non-interactive shell command on the connected SSH server. Returns merged stdout/stderr and the exit code. Commands run via `sh -c` in a fresh exec channel (no state is kept between calls). When the user's working directory is known (see system prompt) each command starts there; otherwise it starts in the login directory — use absolute paths or chain with `cd dir && …` when unsure.",
        "input_schema": [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The shell command to execute.",
                ],
            ],
            "required": ["command"],
        ],
    ]
}

/// 会话 id → 对话控制器:面板关闭再开保留历史,会话关闭时清理
@MainActor
final class AIChatStore {
    static let shared = AIChatStore()
    private var controllers: [UUID: AIChatController] = [:]

    func controller(for session: TerminalSession) -> AIChatController {
        if let existing = controllers[session.id] { return existing }
        let controller = AIChatController(session: session)
        controllers[session.id] = controller
        // 自动接上这台主机最近的历史对话(正被别的会话聊着的除外,免得两边互相覆盖)
        let active = Set(controllers.values.filter { $0 !== controller }.map(\.conversationID))
        if let latest = AIChatHistory.summaries(hostKey: AIChatHistory.hostKey(for: session.spec))
            .first(where: { !active.contains($0.id) }) {
            controller.loadConversation(id: latest.id)
        }
        return controller
    }

    func remove(_ sessionID: UUID) {
        controllers[sessionID]?.stop()
        controllers[sessionID] = nil
    }
}
