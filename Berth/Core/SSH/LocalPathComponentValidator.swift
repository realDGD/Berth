import Foundation

/// 统一校验远端 SFTP 路径分量, 防范目录遍历与恶意文件名逃逸。
/// 远端 SFTP 服务器的数据为不可信输入, 必须拒绝路径遍历字符与非法字符,
/// 并且必须通过标准化的 pathComponents 严格验证目标路径位于基目录内部。
enum LocalPathComponentValidator {

    enum ValidationError: Error, LocalizedError, Equatable {
        case emptyComponent
        case invalidCharacters(component: String)
        case pathTraversal(component: String)
        case escapesRoot(candidate: String, root: String)

        var errorDescription: String? {
            switch self {
            case .emptyComponent:
                return "Path component cannot be empty"
            case .invalidCharacters(let component):
                return "Path component contains invalid characters: \(component)"
            case .pathTraversal(let component):
                return "Path component contains traversal sequences: \(component)"
            case .escapesRoot(let candidate, let root):
                return "Path \(candidate) escapes root \(root)"
            }
        }
    }

    /// 验证单个路径分量 (例如 entry.name)。
    /// 拒绝:
    /// - 空字符串
    /// - "." 或 ".."
    /// - 包含 "/" (路径分隔符)
    /// - 包含 NUL ("\0")
    /// - 包含 ASCII 控制字符
    /// 提示: 在 Linux / Unix 与 macOS 本地文件系统中, "\" (反斜杠) 为合法文件名字符而非路径分隔符, 予以保留。
    static func validateComponent(_ component: String) throws {
        guard !component.isEmpty else {
            throw ValidationError.emptyComponent
        }
        if component == "." || component == ".." {
            throw ValidationError.pathTraversal(component: component)
        }
        if component.contains("/") || component.contains("\0") {
            throw ValidationError.invalidCharacters(component: component)
        }
        if component.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) {
            throw ValidationError.invalidCharacters(component: component)
        }
    }

    /// 验证并拼接单个子分量到 root 目录, 确保标准化后严格位于 root 目录之内。
    static func safeURL(in rootDirectory: URL, component: String, isDirectory: Bool = false) throws -> URL {
        try validateComponent(component)
        let candidate = rootDirectory.appendingPathComponent(component, isDirectory: isDirectory)
        guard isStrictlyContained(candidate: candidate, within: rootDirectory) else {
            throw ValidationError.escapesRoot(
                candidate: candidate.path,
                root: rootDirectory.path
            )
        }
        return candidate
    }

    /// 验证并按顺序拼接多级相对分量到 root 目录, 确保标准化后严格位于 root 目录之内。
    static func safeURL(in rootDirectory: URL, components: [String], isDirectory: Bool = false) throws -> URL {
        guard !components.isEmpty else {
            throw ValidationError.emptyComponent
        }
        var current = rootDirectory.standardizedFileURL
        for (index, component) in components.enumerated() {
            try validateComponent(component)
            let isDir = index < components.count - 1 || isDirectory
            current = current.appendingPathComponent(component, isDirectory: isDir)
        }
        guard isStrictlyContained(candidate: current, within: rootDirectory) else {
            throw ValidationError.escapesRoot(
                candidate: current.path,
                root: rootDirectory.path
            )
        }
        return current
    }

    /// 严格判断 candidate 是否位于 root 目录之内。
    /// 不使用脆弱的字符串前缀匹配 (避免 /foo/bar 错误匹配 /foo/bar2),
    /// 而是对比 standardizedFileURL 的 pathComponents。
    static func isStrictlyContained(candidate: URL, within root: URL) -> Bool {
        let rootStandard = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidateStandard = candidate.standardizedFileURL.resolvingSymlinksInPath()

        let rootComponents = rootStandard.pathComponents
        let candidateComponents = candidateStandard.pathComponents

        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
