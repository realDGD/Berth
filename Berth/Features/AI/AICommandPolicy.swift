import Foundation

/// AI「自动执行命令」的放行策略:白名单,不是黑名单。
/// 模型看到的上下文里有远端命令输出与用户选中的终端文本,都是攻击者可控的,提示注入
/// 能让它吐出任意命令;关键词黑名单拦不住 `curl … | sh`、写 authorized_keys 之类。
/// 免确认只给一小组只读、无副作用、不带 shell 组合语法、不碰机密路径的诊断命令,
/// 其余照常弹「批准 / 拒绝」。
enum AICommandPolicy {
    /// 任意参数都只读的命令(首个词)
    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "whoami", "id", "hostname", "uname", "uptime", "date", "cal",
        "df", "du", "free", "nproc", "lscpu", "lsblk", "lsmod", "vmstat", "iostat", "mpstat",
        "ps", "pgrep", "lsof", "netstat", "ss", "ifconfig", "route", "arp",
        "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "stat", "file", "readlink", "realpath",
        "which", "type", "echo", "true", "false", "test",
        "journalctl", "dmesg", "last", "lastlog", "w", "who", "getent",
        "dpkg-query", "rpm", "nginx", "apachectl", "httpd", "sshd",
    ]

    /// 只放行指定子命令的工具:首个词 → 允许的第二个词
    private static let readOnlySubcommands: [String: Set<String>] = [
        "systemctl": ["status", "list-units", "list-unit-files", "list-timers", "list-sockets",
                      "is-active", "is-enabled", "is-failed", "show", "cat", "list-dependencies"],
        "service": [],   // service <name> status,见下方特殊处理
        "docker": ["ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port", "diff"],
        "podman": ["ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port", "diff"],
        "kubectl": ["get", "describe", "logs", "version", "cluster-info", "top", "explain", "api-resources"],
        "git": ["status", "log", "diff", "show", "rev-parse", "describe", "branch", "remote", "tag", "stash"],
        "ip": ["addr", "address", "a", "route", "r", "link", "l", "neigh", "n", "-br", "-brief", "-4", "-6", "-s"],
        "dpkg": ["-l", "-L", "-s", "--list", "--status", "--get-selections"],
        "apt": ["list", "show", "policy"],
        "apt-cache": ["policy", "show", "search"],
        "yum": ["list", "info"],
        "dnf": ["list", "info"],
        "brew": ["list", "info", "outdated", "doctor", "config"],
        "pip": ["list", "show", "freeze"],
        "pip3": ["list", "show", "freeze"],
        "npm": ["ls", "list", "outdated", "view"],
        "find": [],      // 允许,但下方拦 -delete/-exec 等
    ]

    /// 子命令工具里带这些词就是写操作(ip link set / git stash pop / kubectl get … 也可能夹 --edit)
    private static let mutatingWords: Set<String> = [
        "add", "del", "delete", "rm", "set", "flush", "replace", "change", "up", "down", "apply",
        "pop", "drop", "push", "--edit", "-e", "--force", "-f", "-d", "-m", "-c", "--delete", "-delete",
        "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls",
    ]

    /// git 里「不带参数是列出、带参数就是创建」的子命令:只放行明确的只读参数
    private static let gitListOnlyArguments: [String: Set<String>] = [
        "branch": ["-a", "-r", "-v", "-vv", "--list", "--all", "--show-current", "--contains", "--merged", "--no-merged"],
        "remote": ["-v", "--verbose", "show"],
        "tag": ["-l", "--list", "-n"],
        "stash": ["list", "show"],
    ]

    /// 命令里出现这些片段就必须确认:即便只是 cat,也是在把机密送给模型和聊天历史
    private static let sensitiveFragments: [String] = [
        ".ssh", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "authorized_keys", "known_hosts",
        "shadow", "gshadow", ".env", ".aws", ".kube", ".docker", ".netrc", ".gnupg", ".gpg",
        ".git-credentials", "credential", "secret", "token", "password", "passwd",
        ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", "/environ", "_history", ".pgpass", ".my.cnf",
        "wallet", "keychain",
    ]

    /// 出现即拒绝免确认:shell 组合/重定向/替换/提权
    private static let shellMetacharacters: [String] = [
        "|", ";", "&", ">", "<", "`", "$(", "${", "\n", "\r", "\\",
    ]

    /// 是否可以在「自动执行」开启时免确认运行
    static func isSafeForAutoRun(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if shellMetacharacters.contains(where: { trimmed.contains($0) }) { return false }

        let lower = trimmed.lowercased()
        if sensitiveFragments.contains(where: { lower.contains($0) }) { return false }

        var words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 允许前置环境变量赋值形式 FOO=bar cmd? 不:VAR= 可以改 PATH/LD_PRELOAD,一律确认
        guard let first = words.first, !first.contains("=") else { return false }
        // 带路径的命令(./x、/usr/bin/x)不放行:白名单按名字比对
        guard !first.contains("/") else { return false }
        let name = first.lowercased()
        if ["sudo", "su", "doas", "env", "printenv", "export", "eval", "exec", "sh", "bash", "zsh", "xargs", "nohup", "watch", "time", "nice"].contains(name) {
            return false
        }
        words.removeFirst()
        let lowerWords = words.map { $0.lowercased() }

        if readOnlyCommands.contains(name) {
            return true
        }
        guard let allowedSubcommands = readOnlySubcommands[name] else { return false }
        if lowerWords.contains(where: { mutatingWords.contains($0) }) { return false }

        switch name {
        case "service":
            // service <name> status
            return lowerWords.count == 2 && lowerWords[1] == "status"
        case "find":
            return true
        case "git":
            guard let sub = lowerWords.first, allowedSubcommands.contains(sub) else { return false }
            if let readOnlyArguments = gitListOnlyArguments[sub] {
                // git branch/tag/remote 不带参数是列出;git stash 不带参数是「存一份」,必须带 list/show
                let arguments = lowerWords.dropFirst()
                if sub == "stash", arguments.isEmpty { return false }
                return arguments.allSatisfy { readOnlyArguments.contains($0) }
            }
            return true
        default:
            guard let sub = lowerWords.first else { return false }
            return allowedSubcommands.contains(sub)
        }
    }
}
