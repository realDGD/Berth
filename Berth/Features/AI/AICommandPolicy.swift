import Foundation

/// AI「自动执行命令」的放行策略:白名单,不是黑名单。
/// 模型看到的上下文里有远端命令输出与用户选中的终端文本,都是攻击者可控的,提示注入
/// 能让它吐出任意命令;关键词黑名单拦不住 `curl … | sh`、写 authorized_keys 之类。
/// 免确认只给一小组只读、无副作用、不带 shell 组合语法、不碰机密路径的诊断命令,
/// 其余照常弹「批准 / 拒绝」。
enum AICommandPolicy {
    /// 任意参数都只读的命令(首个词)
    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "whoami", "id", "uname", "uptime", "cal",
        "df", "du", "free", "nproc", "lscpu", "lsblk", "lsmod", "vmstat", "iostat", "mpstat",
        "ps", "pgrep", "lsof", "netstat",
        "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "stat", "file", "readlink", "realpath",
        "which", "type", "echo", "true", "false", "test",
        "last", "w", "who", "getent",
        "dpkg-query",
    ]

    /// 本身是诊断命令,但带特定参数就会改系统状态(hostname foo、date -s、route add、
    /// nginx -s stop、rpm -e …):按原始大小写逐个参数判定。规则全是锚定比对:长参数整词
    /// (连 `--opt=value` 一起认),短参数簇逐字母核对,不做 hasPrefix 之类的子串判断,
    /// 否则 `--file=x`、`-s2020`、`-da` 这类写法就绕过去了
    private static let argumentRules: [String: ([String]) -> Bool] = [
        // hostname <name> / -F file / -b 改主机名;只放行读取参数
        "hostname": { args in
            args.allSatisfy {
                ["-f", "--fqdn", "--long", "-i", "--ip-address", "-I", "--all-ip-addresses", "-s", "--short",
                 "-d", "--domain", "-a", "--alias", "-A", "--all-fqdns", "-y", "--yp", "--nis", "-V", "--version"].contains($0)
            }
        },
        // date <MMDDhhmm> / -s / --set 设系统时间(BSD 的 -f 也会);只放行 +格式串 与读取参数
        "date": { args in
            args.allSatisfy { arg in
                arg.hasPrefix("+")
                    || ["-u", "--utc", "--universal", "-R", "--rfc-email", "--rfc-2822", "-I", "--iso-8601",
                        "--rfc-3339", "-j", "-n", "--version"].contains(arg)
                    || longOption(arg, in: ["--iso-8601", "--rfc-3339", "--date"])
                    || (arg.hasPrefix("-I") && arg.count > 2 && arg.dropFirst(2).allSatisfy(\.isLetter))
            }
        },
        // ifconfig eth0 down / ifconfig eth0 10.0.0.2:只放行无参、单个选项或单个接口名
        "ifconfig": { args in args.count <= 1 && !["up", "down"].contains(args.first?.lowercased() ?? "") },
        // route add/del/flush 的动词不带 - 前缀;只放行 -n/-e/-v/-F/-C/-4/-6/-q/-t 这些查看选项
        "route": { args in args.allSatisfy { shortFlags($0, in: "nevFC46qt") } },
        // arp -d/-s/-f 改 ARP 表
        "arp": { args in
            args.allSatisfy { shortFlags($0, in: "anvelx") || ["--all", "--numeric", "--verbose", "--extended"].contains($0) }
        },
        // ss -K/--kill 杀 socket,-D/--diag 往文件写
        "ss": { args in !args.contains { shortFlagsContain($0, any: "KD") || longOption($0, in: ["--kill", "--diag"]) } },
        // journalctl --vacuum-*/--rotate/--flush/--update-catalog 删日志、动日志文件
        "journalctl": { args in
            !args.contains {
                longOption($0, in: ["--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate", "--flush", "--sync",
                                    "--relinquish-var", "--smart-relinquish-var", "--setup-keys", "--update-catalog"])
            }
        },
        // dmesg -c/-C 清内核缓冲,-n/-D/-E 改控制台级别
        "dmesg": { args in
            !args.contains {
                shortFlagsContain($0, any: "cCnDE")
                    || longOption($0, in: ["--clear", "--read-clear", "--console-level", "--console-off", "--console-on"])
            }
        },
        // lastlog -C/--clear、-S/--set 改登录记录
        "lastlog": { args in !args.contains { shortFlagsContain($0, any: "CS") || longOption($0, in: ["--clear", "--set"]) } },
        // file -C/--compile 会在当前目录写 magic.mgc
        "file": { args in !args.contains { shortFlagsContain($0, any: "C") || $0 == "--compile" } },
        // 服务程序只放行配置检查/版本:nginx -s reload、apachectl restart、裸 sshd(起守护进程)都要确认
        "nginx": { args in !args.isEmpty && args.allSatisfy { ["-t", "-T", "-v", "-V"].contains($0) } },
        "apachectl": { args in
            !args.isEmpty && args.allSatisfy { ["configtest", "status", "fullstatus", "-t", "-v", "-V", "-S", "-M", "-l", "-L"].contains($0) }
        },
        "httpd": { args in !args.isEmpty && args.allSatisfy { ["-t", "-v", "-V", "-S", "-M", "-l", "-L"].contains($0) } },
        "sshd": { args in !args.isEmpty && args.allSatisfy { ["-t", "-T"].contains($0) } },
        // rpm -e 卸载、-i/-U/-F 安装;--pipe/--eval/--define/--load 能借宏展开跑 shell。
        // 只放行查询(-q 簇 / --query)与校验(-V / --verify)模式,其余参数逐个排除写操作
        "rpm": { args in
            guard let first = args.first,
                  ["--query", "-V", "--verify"].contains(first)
                    || (first.hasPrefix("-q") && first.dropFirst(2).allSatisfy { "acdfgilpsvRL".contains($0) })
            else { return false }
            return !args.contains {
                ["-e", "-i", "-U", "-F"].contains($0)
                    || longOption($0, in: ["--erase", "--install", "--upgrade", "--freshen", "--import", "--rebuilddb",
                                           "--initdb", "--restore", "--setperms", "--setugids", "--setcaps",
                                           "--pipe", "--define", "--eval", "--load", "--macros", "--rcfile"])
            }
        },
    ]

    /// 长参数整词比对,连带 `--opt=value` 形式
    private static func longOption(_ arg: String, in options: [String]) -> Bool {
        options.contains { arg == $0 || arg.hasPrefix($0 + "=") }
    }

    /// 短参数簇(-abc)每个字母都在放行集合里
    private static func shortFlags(_ arg: String, in letters: String) -> Bool {
        arg.count > 1 && arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.dropFirst().allSatisfy { letters.contains($0) }
    }

    /// 短参数簇里含任一给定字母(-tK、-Tc 这种合写也算)
    private static func shortFlagsContain(_ arg: String, any letters: String) -> Bool {
        arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.dropFirst().contains { letters.contains($0) }
    }

    /// ip:选项 → 对象 → 动词 三段都按白名单。`ip netns exec …`、`ip route append …`、
    /// `-b file` 批处理、`-n ns` 这些不在名单里的一律确认
    private static func isReadOnlyIPCommand(_ words: [String]) -> Bool {
        let options: Set<String> = ["-4", "-6", "-0", "-br", "-brief", "-s", "-stats", "-statistics", "-h", "-human",
                                    "-human-readable", "-o", "-oneline", "-j", "-json", "-p", "-pretty", "-r", "-resolve",
                                    "-a", "-all", "-t", "-timestamp", "-ts", "-tshort"]
        let objects: Set<String> = ["addr", "address", "a", "route", "r", "link", "l", "neigh", "neighbour", "neighbor", "n",
                                    "rule", "ru", "maddr", "maddress", "m", "tunnel", "tunl", "t"]
        let verbs: Set<String> = ["show", "list", "ls", "sh", "lst", "get", "help", "showdump"]
        var rest = words[...]
        while let first = rest.first, first.hasPrefix("-") {
            guard options.contains(first) else { return false }
            rest = rest.dropFirst()
        }
        guard let object = rest.first, objects.contains(object) else { return false }
        rest = rest.dropFirst()
        guard let verb = rest.first else { return true }
        return verbs.contains(verb)
    }

    /// 只放行指定子命令的工具:首个词 → 允许的第二个词
    private static let readOnlySubcommands: [String: Set<String>] = [
        "systemctl": ["status", "list-units", "list-unit-files", "list-timers", "list-sockets",
                      "is-active", "is-enabled", "is-failed", "show", "cat", "list-dependencies"],
        "service": [],   // service <name> status,见下方特殊处理
        "docker": ["ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port", "diff"],
        "podman": ["ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port", "diff"],
        "kubectl": ["get", "describe", "logs", "version", "cluster-info", "top", "explain", "api-resources"],
        "git": ["status", "log", "diff", "show", "rev-parse", "describe", "branch", "remote", "tag", "stash"],
        "ip": [],        // 见 isReadOnlyIPCommand:选项/对象/动词三段白名单
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

        if let rule = argumentRules[name] {
            return rule(words)
        }
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
        case "ip":
            return isReadOnlyIPCommand(lowerWords)
        case "git":
            guard let sub = lowerWords.first, allowedSubcommands.contains(sub) else { return false }
            // git log/diff/show --output=<file> 会往任意路径写文件
            if lowerWords.contains(where: { longOption($0, in: ["--output"]) }) { return false }
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
