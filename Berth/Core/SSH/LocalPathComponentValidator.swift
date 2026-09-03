import Foundation

/// Validates untrusted SFTP filenames before they are materialized below a local download root.
enum LocalPathComponentValidator {
    enum ValidationError: Error, LocalizedError, Equatable {
        case emptyComponent
        case invalidCharacters(component: String)
        case pathTraversal(component: String)
        case escapesRoot(candidate: String, root: String)

        var errorDescription: String? {
            switch self {
            case .emptyComponent:
                return String(localized: "远端文件名不能为空。")
            case .invalidCharacters:
                return String(localized: "远端文件名包含本地文件系统不支持的字符。")
            case .pathTraversal:
                return String(localized: "远端文件名包含不安全的路径分量。")
            case .escapesRoot:
                return String(localized: "远端文件的目标路径超出下载目录。")
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

    static func safeURL(
        in rootDirectory: URL,
        component: String,
        isDirectory: Bool = false
    ) throws -> URL {
        try validateComponent(component)
        let candidate = rootDirectory.appendingPathComponent(component, isDirectory: isDirectory)
        guard isStrictlyContained(candidate: candidate, within: rootDirectory) else {
            throw ValidationError.escapesRoot(candidate: candidate.path, root: rootDirectory.path)
        }
        return candidate
    }

    static func safeURL(
        in rootDirectory: URL,
        components: [String],
        isDirectory: Bool = false
    ) throws -> URL {
        guard !components.isEmpty else {
            throw ValidationError.emptyComponent
        }
        var current = rootDirectory.standardizedFileURL
        for (index, component) in components.enumerated() {
            try validateComponent(component)
            current = current.appendingPathComponent(
                component,
                isDirectory: index < components.count - 1 || isDirectory
            )
        }
        guard isStrictlyContained(candidate: current, within: rootDirectory) else {
            throw ValidationError.escapesRoot(candidate: current.path, root: rootDirectory.path)
        }
        return current
    }

    static func isStrictlyContained(candidate: URL, within root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
