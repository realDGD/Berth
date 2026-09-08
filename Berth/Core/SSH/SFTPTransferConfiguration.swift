import Foundation

/// 统一的 SFTP 传输并发与管线配置单一数据源。
/// 既控制单个文件的 READ pipeline 深度与并发文件数，
/// 也直接决定全局 TransferBudget 的 requestLimit 与 handleLimit。
public struct SFTPTransferConfiguration: Sendable, Equatable {
    /// 初始单文件 pipeline 深度。低延迟/保守服务器在热身阶段避免并发过载。
    public var initialPipelineDepth: Int
    /// 单文件 pipeline 深度上限。
    public var maxPipelineDepth: Int
    /// 同时并发下载的文件数。
    public var maxConcurrentFiles: Int
    /// 目录扫描时并发列举目录数。
    public var maxConcurrentDirectories: Int
    /// 全局未完成请求硬上限 (对应 TransferBudget.requests limit)。
    public var requestLimit: Int
    /// 全局同时打开句柄硬上限 (对应 TransferBudget.handles limit)。
    public var handleLimit: Int
    /// SFTP v3 块大小回落 (字节)。默认 32 KiB。
    public var fallbackChunkSize: Int

    /// 兼容旧属性名
    public var maxOutstandingRequests: Int {
        get { requestLimit }
        set { requestLimit = newValue }
    }
    public var maxOpenHandles: Int {
        get { handleLimit }
        set { handleLimit = newValue }
    }

    public init(
        initialPipelineDepth: Int = 2,
        maxPipelineDepth: Int = 8,
        maxConcurrentFiles: Int = 8,
        maxConcurrentDirectories: Int = 4,
        requestLimit: Int = 64,
        handleLimit: Int = 16,
        fallbackChunkSize: Int = 32 * 1024
    ) {
        // 允许通过环境变量对生产与验收环境做 A/B 调优与快速降载
        let env = ProcessInfo.processInfo.environment
        let envFiles = env["BERTH_SFTP_MAX_CONCURRENT_FILES"].flatMap(Int.init)
        let envInitPipe = env["BERTH_SFTP_INITIAL_PIPELINE_DEPTH"].flatMap(Int.init)
        let envMaxPipe = env["BERTH_SFTP_MAX_PIPELINE_DEPTH"].flatMap(Int.init)
        let envReqLimit = env["BERTH_SFTP_REQUEST_LIMIT"].flatMap(Int.init)
        let envHandleLimit = env["BERTH_SFTP_HANDLE_LIMIT"].flatMap(Int.init)

        self.initialPipelineDepth = envInitPipe ?? initialPipelineDepth
        self.maxPipelineDepth = envMaxPipe ?? maxPipelineDepth
        self.maxConcurrentFiles = envFiles ?? maxConcurrentFiles
        self.maxConcurrentDirectories = maxConcurrentDirectories
        self.requestLimit = envReqLimit ?? requestLimit
        self.handleLimit = envHandleLimit ?? handleLimit
        self.fallbackChunkSize = fallbackChunkSize
    }

    public var normalized: Self {
        var value = self
        value.initialPipelineDepth = max(1, value.initialPipelineDepth)
        value.maxPipelineDepth = max(value.initialPipelineDepth, value.maxPipelineDepth)
        value.maxConcurrentFiles = max(1, value.maxConcurrentFiles)
        value.maxConcurrentDirectories = max(1, value.maxConcurrentDirectories)
        value.requestLimit = max(1, value.requestLimit)
        value.handleLimit = max(1, value.handleLimit)
        value.fallbackChunkSize = min(Int.max, max(1, value.fallbackChunkSize))
        return value
    }
}
