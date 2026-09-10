import Citadel
import Foundation
import NIOCore
import Observation

/// 仪表盘的采集引擎:对每台主机维持一条轻量连接,按周期跑采集脚本,存最近若干次样本供走势图。
///
/// 连接策略(优先级从高到低):
/// 1. 该主机已有连上的终端会话 → 直接借它的 SSH 连接开 exec 通道,零额外 TCP;
/// 2. 否则自己拨一条**不开 PTY**的常驻连接,后续每轮复用;
/// 3. 拨号失败按指数退避重试,连接断了下一轮自动重拨。
///
/// 后台采集绝不弹窗:需要人参与的主机(未确认的主机密钥、MFA、Touch ID 门禁)一律
/// 标成对应状态摆在卡片上,由用户决定要不要处理 —— 打开个仪表盘就弹十几个 sheet 是灾难。
@MainActor
@Observable
final class ServerMonitor {
    static let shared = ServerMonitor()

    /// 单台主机的监控状态
    enum Status: Equatable {
        case idle
        case connecting
        case online
        /// 连不上/采集失败,附人话原因
        case offline(String)
        /// 用密钥认证但「使用密钥前要求 Touch ID」开着,需用户在仪表盘显式授权一次
        case needsAuthorization
        /// 需要人参与(主机密钥未确认、MFA 动态码等)
        case needsInteraction(String)

        var isBusy: Bool { self == .connecting }
    }

    /// 走势图数据点(只留上屏要用的几条曲线,不做通用时序库)
    struct HistoryPoint: Equatable, Sendable {
        let at: Date
        let cpu: Double?
        let memory: Double?
        let netRx: Double?
        let netTx: Double?
    }

    struct HostState: Identifiable {
        let id: UUID
        var label: String
        var address: String
        var osName: String
        var isProduction: Bool
        var status: Status = .idle
        var reading: ServerMetricsReading?
        var history: [HistoryPoint] = []
        var lastSuccessAt: Date?
        /// 一次采集的往返耗时(粗略反映链路延迟)
        var latency: TimeInterval?
        /// 数据来自已打开的终端会话连接(而非仪表盘自建连接)
        var borrowsSession = false

        var isLive: Bool { status == .online }
    }

    /// 采集目标(从 Host 拍成快照,不持有 SwiftData 模型 —— 模型可能被 config 同步等外部删除)
    private struct Target {
        let id: UUID
        let spec: HostSpec
        let label: String
        let address: String
        let isProduction: Bool
    }

    /// 最多保留的历史点数(5s 间隔 ≈ 7 分钟走势)
    static let historyLimit = 90
    /// 同时拨号的上限:打开仪表盘时几十台主机一起拨会触发服务器的连接频率限制
    private static let maxConcurrentDials = 4
    /// 单轮采集的超时
    private static let collectionTimeout: Duration = .seconds(20)

    private(set) var states: [UUID: HostState] = [:]
    /// 目标顺序(UI 按它排版,保持与侧栏一致)
    private(set) var order: [UUID] = []
    private(set) var isRunning = false
    /// 用户已在本次运行中授权后台使用密钥(过了一次 Touch ID)
    private(set) var keyUseAuthorized = false

    private var targets: [UUID: Target] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    /// 仪表盘自建的连接(区别于借用终端会话的)
    private var ownedConnections: [UUID: SSHConnection] = [:]
    /// 上一轮样本,用于求 CPU 占用与网络速率
    private var previousSamples: [UUID: ServerMetricsSample] = [:]
    private var dialSlotsInUse = 0
    private var dialWaiters: [CheckedContinuation<Void, Never>] = []
    /// 当前挂着仪表盘的视图数(主窗口内嵌 / 独立窗口)
    private var viewers = 0

    var interval: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: SettingsKeys.dashboardInterval) as? Double ?? 5
        return min(max(stored, 2), 300)
    }

    // MARK: - 生命周期

    /// 设置采集目标。本地 Shell 不是服务器,直接跳过。
    func setTargets(_ hosts: [Host]) {
        let incoming = hosts.filter { !$0.hostname.isEmpty }
        order = incoming.map(\.id)

        var next: [UUID: Target] = [:]
        for host in incoming {
            next[host.id] = Target(
                id: host.id,
                spec: HostSpec.resolve(host, in: hosts),
                label: host.label,
                address: host.address,
                isProduction: host.isProduction
            )
        }

        // 已移除的主机:停采集、断连接、清状态
        for id in targets.keys where next[id] == nil {
            stopRunner(id)
            states[id] = nil
            previousSamples[id] = nil
        }

        for (id, target) in next {
            let existing = states[id]
            states[id] = HostState(
                id: id,
                label: target.label,
                address: target.address,
                osName: hosts.first { $0.id == id }?.osName ?? "",
                isProduction: target.isProduction,
                status: existing?.status ?? .idle,
                reading: existing?.reading,
                history: existing?.history ?? [],
                lastSuccessAt: existing?.lastSuccessAt,
                latency: existing?.latency,
                borrowsSession: existing?.borrowsSession ?? false
            )
            // 主机配置改了(换端口/换认证)→ 旧连接作废,下一轮按新配置重拨
            if let old = targets[id], old.spec != target.spec {
                dropOwnedConnection(id)
                stopRunner(id)
            }
        }
        targets = next

        if isRunning { startRunners() }
    }

    /// 仪表盘上屏:开始采集。主窗口内嵌与独立窗口可能同时开着,按观察者计数启停,
    /// 关掉其中一个不该把另一个的数据也停掉。
    func start() {
        viewers += 1
        guard !isRunning else { return }
        isRunning = true
        startRunners()
    }

    /// 仪表盘下屏:最后一个观察者走了才停采集并释放自建连接(借用的会话连接不受影响)
    func stop() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0, isRunning else { return }
        isRunning = false
        for id in runners.keys { runners[id]?.cancel() }
        runners.removeAll()
        for id in ownedConnections.keys { dropOwnedConnection(id) }
        for id in states.keys where states[id]?.status != .needsAuthorization {
            states[id]?.status = .idle
        }
    }

    /// 立刻重采一轮(工具条的刷新按钮):重启 runner 即可,不必等当前 sleep 结束
    func refreshAll() {
        guard isRunning else { return }
        for id in order { stopRunner(id) }
        startRunners()
    }

    /// 用户显式授权后台使用密钥:过一次 Touch ID,之后本次运行内密钥主机都能自动监控
    func authorizeKeyUse() async {
        do {
            try await SSHDialer.touchIDGate(reason: String(localized: "在仪表盘后台使用私钥监控服务器"))
            keyUseAuthorized = true
            for id in order where states[id]?.status == .needsAuthorization {
                states[id]?.status = .idle
                stopRunner(id)
            }
            if isRunning { startRunners() }
        } catch {
            // 用户取消:保持原样,不改状态
        }
    }

    // MARK: - 采集循环

    private func startRunners() {
        for id in order where runners[id] == nil {
            guard let target = targets[id] else { continue }
            runners[id] = Task { [weak self] in
                await self?.runLoop(target)
            }
        }
    }

    private func stopRunner(_ id: UUID) {
        runners[id]?.cancel()
        runners[id] = nil
    }

    private func runLoop(_ target: Target) async {
        var failures = 0
        while !Task.isCancelled {
            var wait = interval
            switch await collectOnce(target) {
            case .collected:
                failures = 0
            case .haltUntilRefresh:
                // 凭据被拒:再试只会累积失败登录直到被封。停掉这台的 runner,
                // 等用户改主机配置(setTargets 重启)或点刷新(refreshAll)再拨
                dropOwnedConnection(target.id)
                runners[target.id] = nil
                return
            case .failed(let needsHuman):
                dropOwnedConnection(target.id)
                failures += 1
                // 需要人参与的(指纹未确认、MFA)慢速重试就行:用户在终端里处理完之后,
                // 一分钟内这张卡片会自己活过来,不用手动刷新
                wait = needsHuman
                    ? 60
                    // 指数退避封顶 2 分钟:某台机器长时间不在,别让它的重连变成噪声
                    : min(interval * pow(2, Double(min(failures, 5))), 120)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private enum CollectOutcome {
        case collected
        /// needsHuman = true 表示重试也没用,得用户去终端里处理一次
        case failed(needsHuman: Bool)
        /// 服务器拒绝了当前凭据:不再自动重试,直到主机配置变化或用户手动刷新
        case haltUntilRefresh
    }

    private func collectOnce(_ target: Target) async -> CollectOutcome {
        let startedAt = Date()
        let client: SSHClient
        let borrowed: Bool

        if let live = liveSessionClient(for: target.id) {
            client = live
            borrowed = true
            // 用户自己把这台主机连起来了 → 自建的那条监控连接没必要再占着
            dropOwnedConnection(target.id)
        } else if let owned = ownedConnections[target.id], owned.isAlive {
            client = owned.client
            borrowed = false
        } else {
            if states[target.id]?.status != .online { states[target.id]?.status = .connecting }
            do {
                client = try await dial(target)
                borrowed = false
            } catch {
                guard !Task.isCancelled else { return .failed(needsHuman: true) }
                let status = Self.status(for: error, target: target)
                states[target.id]?.status = status
                states[target.id]?.reading = nil
                if Self.isCredentialRejection(error) { return .haltUntilRefresh }
                if case .offline = status { return .failed(needsHuman: false) }
                return .failed(needsHuman: true)
            }
        }

        do {
            // 采集卡死时(服务器 I/O 挂起等)必须能超时退出,否则这台主机的 runner 停在这一轮不动
            let command = "sh -c \(Self.shellQuote(ServerMetrics.collectionScript))"
            let buffer = try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
                group.addTask {
                    try await client.executeCommand(command, maxResponseSize: 1 << 18, mergeStreams: true)
                }
                group.addTask {
                    try await Task.sleep(for: Self.collectionTimeout)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled else { return .failed(needsHuman: true) }
            let sample = ServerMetricsSample(parsing: String(buffer: buffer))
            guard sample.isUsable else {
                states[target.id]?.status = .offline(String(localized: "无法读取资源信息:服务器上缺少 /proc、df 等基础工具。"))
                return .failed(needsHuman: false)
            }
            apply(sample, to: target, borrowed: borrowed, latency: Date().timeIntervalSince(startedAt))
            return .collected
        } catch {
            guard !Task.isCancelled else { return .failed(needsHuman: true) }
            states[target.id]?.status = .offline(error is CancellationError
                ? String(localized: "采集超时:服务器没有在 20 秒内返回资源信息。")
                : SSHErrorMapper.friendlyMessage(
                    for: error,
                    hostname: target.spec.hostname,
                    port: target.spec.port,
                    authMethod: target.spec.authMethod
                ))
            return .failed(needsHuman: false)
        }
    }

    private func apply(_ sample: ServerMetricsSample, to target: Target, borrowed: Bool, latency: TimeInterval) {
        let reading = ServerMetricsReading(sample: sample, previous: previousSamples[target.id])
        previousSamples[target.id] = sample

        guard var state = states[target.id] else { return }
        state.status = .online
        state.reading = reading
        state.lastSuccessAt = sample.takenAt
        state.latency = latency
        state.borrowsSession = borrowed
        if state.osName.isEmpty { state.osName = reading.os }
        // 首轮没有速率/占用(要两次采样求差),不入图,免得曲线起头一个假的 0
        if reading.cpuFraction != nil || reading.memFraction != nil {
            state.history.append(HistoryPoint(
                at: sample.takenAt,
                cpu: reading.cpuFraction,
                memory: reading.memFraction,
                netRx: reading.netRxRate,
                netTx: reading.netTxRate
            ))
            if state.history.count > Self.historyLimit {
                state.history.removeFirst(state.history.count - Self.historyLimit)
            }
        }
        states[target.id] = state

        // 顺手把探测到的系统名回写主机(与终端连接同一口径,驱动侧栏徽章)
        if !reading.os.isEmpty {
            SessionManager.shared.recordServerOS(hostID: target.id, os: reading.os)
        }
    }

    /// 已连上的终端会话 → 借它的连接(零额外 TCP)
    private func liveSessionClient(for hostID: UUID) -> SSHClient? {
        SessionManager.shared.sessions
            .first { $0.spec.hostID == hostID && $0.liveConnection != nil }?
            .liveConnection?
            .client
    }

    private func dial(_ target: Target) async throws -> SSHClient {
        await acquireDialSlot()
        defer { releaseDialSlot() }
        // 排队期间这台主机可能已经被用户在终端里连上了,直接改用那条连接
        if let live = liveSessionClient(for: target.id) { return live }

        let dialer = SSHDialer.nonInteractive(spec: target.spec, allowKeyUse: keyUseAuthorized)
        let outcome = try await dialer.dial()
        let connection = SSHConnection(client: outcome.client, jumpClients: outcome.jumpClients)
        connection.retain()
        ownedConnections[target.id] = connection
        return outcome.client
    }

    private func dropOwnedConnection(_ id: UUID) {
        ownedConnections[id]?.release()
        ownedConnections[id] = nil
    }

    // MARK: - 错误归类

    private static func status(for error: Error, target: Target) -> Status {
        if let dialError = error as? SSHDialer.DialError {
            switch dialError {
            case .needsInteraction:
                return .needsAuthorization
            default:
                return .offline(dialError.errorDescription ?? String(describing: dialError))
            }
        }
        if isCredentialRejection(error) {
            return .needsInteraction(String(localized: "认证失败:服务器拒绝了当前密码或密钥。请在终端连接一次核对凭据,或修改主机配置后点刷新;仪表盘不再自动重试,以免触发登录封禁。"))
        }
        if error is HostKeyError {
            return .needsInteraction(String(localized: "主机密钥未确认。请先在终端连接一次并确认指纹,之后仪表盘才会自动监控。"))
        }
        if error is KeyboardInteractiveAuthError {
            return .needsInteraction(String(localized: "该主机需要交互式认证(如 MFA 动态码),请在终端里连接。"))
        }
        return .offline(SSHErrorMapper.friendlyMessage(
            for: error,
            hostname: target.spec.hostname,
            port: target.spec.port,
            authMethod: target.spec.authMethod
        ))
    }

    /// 凭据被服务器拒绝(密码/密钥错、交互式认证用尽):与「需要人处理一次」的
    /// 指纹未确认/MFA 不同,这类失败每重试一次就多一条失败登录记录。
    private static func isCredentialRejection(_ error: Error) -> Bool {
        if let kbd = error as? KeyboardInteractiveAuthError, case .exhausted = kbd { return true }
        if error is HostKeyError || error is KeyboardInteractiveAuthError || error is SSHDialer.DialError { return false }
        return SessionTerminationClassifier.categorize(error: error) == .authentication
    }

    // MARK: - 拨号并发闸门

    private func acquireDialSlot() async {
        guard dialSlotsInUse >= Self.maxConcurrentDials else {
            dialSlotsInUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            dialWaiters.append(continuation)
        }
        dialSlotsInUse += 1
    }

    private func releaseDialSlot() {
        dialSlotsInUse -= 1
        guard !dialWaiters.isEmpty else { return }
        dialWaiters.removeFirst().resume()
    }

    // MARK: - 工具

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
