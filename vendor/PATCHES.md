# Vendored packages & patches

`vendor/Citadel` 与 `vendor/swift-nio-ssh` 是本地 vendor 的依赖,`project.yml` 通过本地
路径引用(不再走 SPM 远程)。基线:

- **Citadel** 0.12.0(github.com/orlandos-nl/Citadel @ 0.12.0)
- **swift-nio-ssh** 0.3.4(github.com/Joannis/swift-nio-ssh @ b93961a,Citadel 用的 fork)

vendor 后各自删除了 `.git`,`Citadel/Package.swift` 的 nio-ssh 依赖改为 `.package(path: "../swift-nio-ssh")`。

## 补丁:RSA 用 rsa-sha2-512 签名(替代 SHA-1 ssh-rsa)

**动机**:Citadel 原生只用 SHA-1(`ssh-rsa`)给 RSA 密钥签名,OpenSSH 8.8+ 默认拒收,
导致 RSA 密钥连不上现代服务器(报「服务器拒绝了认证」)。RFC 8332 的 `rsa-sha2-256/512`
是替代方案:**密钥 blob 类型仍是 `ssh-rsa`,但签名算法名与签名哈希换成 SHA-2**。

难点:nio-ssh 把「user-auth 广播的签名算法名」和「密钥 blob 类型」共用同一个
`publicKeyPrefix`,无法只改 Citadel。故补丁分布在两个包,均以 `[Berth patch]` 注释标记。

### swift-nio-ssh
- `Keys And Signatures/CustomKeys.swift`:给 `NIOSSHPublicKeyProtocol` 加
  `static var userAuthPrefix`,默认 `= publicKeyPrefix`(对所有现有密钥无影响)。
- `Keys And Signatures/NIOSSHPublicKey.swift`:给 wrapper 加 `userAuthPrefix` 计算属性,
  仅 `.custom` 密钥返回自定义值,其余等于 `keyPrefix`。
- `SSHMessages.swift` `writeUserAuthRequestMessage`:算法名字段改用 `key.userAuthPrefix`。
- `User Authentication/UserAuthSignablePayload.swift`:待签 payload 的算法名改用
  `publicKey.userAuthPrefix`(RFC 8332 §3.3,签名数据里的算法名须与广播一致)。

### Citadel
- `Algorithms/RSA.swift`:
  - `PublicKey.userAuthPrefix = "rsa-sha2-512"`(`publicKeyPrefix` 保持 `"ssh-rsa"`)。
  - `Signature.signaturePrefix = "rsa-sha2-512"`。
  - `PrivateKey.signature(for:)`:`SHA512` + `NID_sha512`(原为 SHA-1 + `NID_sha1`)。

### 影响面与已知边界
- ed25519 / ECDSA / 密码认证:不受影响(`userAuthPrefix` 默认等于原 `keyPrefix`)。
- ~~RSA **验签**(`PublicKey.isValidSignature`)仍是 SHA-1~~ 已由下方「RSA host key +
  KEX 兼容」补丁补齐:验签按签名到达时的算法名选哈希(SHA-512/256/1)。
- 验证:对 OpenSSH 9.2 真机(192.168.1.111 / .222)用 RSA 密钥连通 OK;ed25519 / 密码 /
  known_hosts 全回归通过;35 项单测通过。

## 补丁:connect(on:settings:) 在 event loop 上加 handler

`Sources/Citadel/ClientSession.swift` 的 `SSHClientSession.addHandlers` 原来直接调
`channel.pipeline.syncOperations.addHandlers(...)`,而 syncOperations 要求在 channel 自身的
event loop 上执行。`SSHClient.connect(on:settings:)`(经代理自建 channel 时用)从任意异步
上下文调用它,触发 `assertInEventLoop` 崩溃。补丁把 addHandlers 包进 `channel.eventLoop.submit { … }`,
使其在正确的 event loop 上运行。标记 `[Berth patch]`。

## 补丁:DataToBufferCodec 设为 public

`Sources/Citadel/DirectTCPIP/Client/DirectTCPIP+Client.swift` 的 `DataToBufferCodec`
(SSHChannelData ↔ ByteBuffer)原为 `internal`。远程端口转发的 forwarded-tcpip 入通道
**不会**自动安装此 codec(direct-tcpip 会),导致包成 `NIOAsyncChannel<ByteBuffer>` 后收不到
数据。补丁把类与其协议方法、init 设为 `public`,Berth 在 `withRemotePortForward` 的
`configure` 闭包里手动 `addHandler(DataToBufferCodec())`。标记 `[Berth patch]`。

## 补丁:握手/认证失败时关闭底层 channel

Citadel 三条连接路径(`SSHClientSession.connect(settings:)` 直连、`SSHClient.connect(on:settings:)`
代理、`SSHClient.jump(to:)` 跳板)在 `handshakeHandler.authenticated` 失败时都**不关闭 channel**,
每次失败连接会留下一条半开 TCP,直到服务器 LoginGraceTime(默认 2 分钟)回收。半开连接
占用 sshd 的 MaxStartups 名额,并助长 OpenSSH 9.8+ PerSourcePenalties 的源 IP 封禁
(表现为后续连接在版本交换前即被服务器关闭)。补丁在三处失败路径统一 `channel.close(promise: nil)`:
- `ClientSession.swift` `connect(settings:)`:future 链尾加 `flatMapError`。
- `Client.swift` `connect(on:settings:)` 与 `jump(to:)`:`authenticated` 外包 do/catch。

均标记 `[Berth patch]`。

## 补丁:keyboard-interactive 认证(RFC 4256,堡垒机 MFA)

**动机**(issue #12):阿里云堡垒机等「密码 + MFA 动态码」登录走 keyboard-interactive,
nio-ssh 完全没有实现该方法,这类服务器无法连接。

### swift-nio-ssh
- `SSHMessages.swift`:新增 `UserAuthInfoRequestMessage`(60)/`UserAuthInfoResponseMessage`(61)
  及其编解码。**报文号 60 与 PK_OK 复用**(RFC 4252/4256 历史遗留),解码按内容判别:先按
  PK_OK 解(首字段必为已知密钥算法名),失败回退按 INFO_REQUEST 解。客户端只要不发
  「无签名 publickey 试探」(Citadel 从不发)就无歧义。`UserAuthRequestMessage.Method`
  增加 `.keyboardInteractive(submethods:)` 及读写。
- `UserAuthenticationMethod.swift`:`NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`
  (解析/广播 "keyboard-interactive");offer 增加 `.keyboardInteractive`;公开
  `NIOSSHKeyboardInteractiveChallenge`(name/instruction/prompts)。
- `ClientUserAuthenticationDelegate.swift`:协议新增 `keyboardInteractiveChallenge(_:responsePromise:)`,
  带默认实现(直接失败),现有 delegate 不受影响。
- `UserAuthenticationStateMachine.swift`:客户端 `awaitingResponses` 状态下收 INFO_REQUEST →
  调 delegate 应答(异步,等 UI 输 MFA 码),状态不变;`sendUserAuthInfoResponse` 记账;
  服务端收到 kbd-int 请求一律按失败应答(Berth 只做客户端)。
- `SSHConnectionStateMachine.swift` + `Operations/AcceptsUserAuthMessages.swift` +
  `Operations/SendsUserAuthMessages.swift`:userAuthentication 状态下 INFO_REQUEST 入站
  分发与 INFO_RESPONSE 出站序列化。

### Citadel
- `SSHAuthenticationMethod.swift`:
  - 记录在途 implementation,`keyboardInteractiveChallenge` 转发给当前 `.custom` 实现
    (否则新协议方法落在默认实现上直接失败)。
  - **多轮认证修复**:`.custom` 在途时后续 `nextAuthenticationType` 回调持续转发给它,
    由它自管耗尽。原逻辑每轮弹出一个 implementation,单个 custom delegate 第二轮就被
    误判「全部用尽」——password 失败转 kbd-int 永远走不通。
  - offer 校验 switch 补 `.keyboardInteractive` 分支。

### Berth 侧配套(非 vendor)
- `Core/SSH/KeyboardInteractiveAuth.swift`:认证 delegate(password 先行,失败转 kbd-int;
  首个不回显提示自动用存储密码作答,MFA 码冒泡 UI)+ 质询呈现模型。
- `TerminalSession`:`keyboardInteractivePrompt` + sheet(`KeyboardInteractivePromptSheet`),
  `.password` 认证统一走该 delegate。
- 验收:`docker/test-sshd/up-kbdint.sh`(2223,仅 kbd-int)+ `BERTH_KBDINT_AUTOTEST=1`
  (存储密码自动应答、无密码 UI 质询两条路径)。

## 补丁:RSA host key + 老式算法 KEX 兼容(issue #12 续,堡垒机协商失败)

**动机**:阿里云堡垒机升级 v1.6.0 后报 `keyExchangeNegotiationFailure`。抓包定位:此类
堡垒机只提供 `diffie-hellman-group14-*` KEX 与 RSA host key(常配 `aes-ctr` 加密),而
nio-ssh 内置只有 curve25519/ECDH KEX、AES-GCM、ed25519/ECDSA host key,三项全无交集。
Citadel 自带 `DiffieHellmanGroup14Sha1/Sha256` 与 `AES128CTR` 实现(Berth 侧经
`SSHAlgorithms` 追加启用,见 `Core/SSH/SSHCompatAlgorithms.swift`),但 RSA 作 host key
的验签/协商链路缺失,需 vendor 补丁:

### swift-nio-ssh
- `Keys And Signatures/CustomKeys.swift`:
  - `NIOSSHPublicKeyProtocol` 增加 `static var hostKeyAlgorithmNames: [String]`
    (默认 `[publicKeyPrefix]`):一个密钥类型可对外服务多个 host key 算法名(RFC 8332)。
  - `NIOSSHSignatureProtocol` 增加 `static var signatureAlgorithmNames: [String]`(默认
    `[signaturePrefix]`)与 `read(from:algorithm:)`(默认转发 `read(from:)`):签名按
    到达时的线上算法名解析,让实现记住签名用的哈希。
- `Key Exchange/SSHKeyExchangeStateMachine.swift`:
  - `supportedServerHostKeyAlgorithms`:自定义密钥从单个 `publicKeyPrefix` 改为
    `hostKeyAlgorithmNames` 全量广播(RSA → rsa-sha2-512/256 + ssh-rsa)。
  - host key 一致性检查:`keyPrefix == 协商名` 改为 `canServe(hostKeyAlgorithm:)`
    (rsa-sha2-512 由 blob 类型仍为 ssh-rsa 的密钥服务)。
  - 协商失败(KEX/host key、加密、MAC 三处)带 diagnostics:双方算法列表进错误文本,
    用户报错即可定位(此前只有裸 `keyExchangeNegotiationFailure`)。
- `Keys And Signatures/NIOSSHPublicKey.swift`:`canServe(hostKeyAlgorithm:)`(自定义密钥
  查 `hostKeyAlgorithmNames`,内置密钥仍按前缀相等)。
- `Keys And Signatures/NIOSSHSignature.swift`:`readSSHSignature` 自定义分支按
  `signatureAlgorithmNames` 多名匹配并传入算法名。
- `NIOSSHError.swift`:`keyExchangeNegotiationFailure(diagnostics:)` 工厂。

### Citadel
- `Algorithms/RSA.swift`:
  - `PublicKey.hostKeyAlgorithmNames = ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]`。
  - `Signature` 增加 `hash`(sha1/sha256/sha512,本地签名固定 sha512)与
    `signatureAlgorithmNames`、`read(from:algorithm:)`(按线上名记哈希)。
  - `PublicKey.isValidSignature`:验签哈希按 `signature.hash` 选(原硬编码 SHA-1)。

### Berth 侧配套(非 vendor)
- `Core/SSH/SSHCompatAlgorithms.swift`:`SSHAlgorithms.berthCompatibility`(追加 DH
  group14 sha256/sha1、AES128CTR、RSA host key;`.add` 保证现代算法优先)。
  Mac `TerminalSession` 与 iOS `IOSTerminalSession` 的 settings 均启用。
- `Core/SSH/SSHErrorMapper.swift`:协商失败人话化并透出诊断列表。
- 验收:`docker/test-sshd/up-legacy.sh`(2224)四组合全过 —— group14-sha256+rsa-sha2-512、
  group14-sha1+ssh-rsa(SHA-1)、curve25519+仅 RSA host key(内置 ECDH 路径验签)、
  现代 sshd 回归;单测 120 项;`BERTH_M1_AUTOTEST` 对 2224 全流程 ALL_DONE。

## 升级 Citadel/nio-ssh 时
本地 vendor 已脱离 SPM 版本管理。若要升级,需重新 vendor 对应版本并重放上述 `[Berth patch]`
改动(`grep -rn "\[Berth patch\]" vendor/` 可列出全部补丁点)。

## 补丁: SFTP listDirectory 关闭 OPENDIR handle

`SFTPClient.listDirectory(atPath:)` 原先在读取完目录后直接返回,没有发送
`SSH_FXP_CLOSE`。递归下载/删除大量目录时会因此泄漏远端目录 handle,最终触发服务器的
`max-open-handles` 限制。现已在成功、READDIR 失败和取消路径统一结构化等待 CLOSE；标记
`[Berth patch]`，位置为 `Sources/Citadel/SFTP/Client/SFTPClient.swift`。

## 补丁:SFTPFile 使用 FSTAT 并允许受控并发读取

`SFTPFile.readAttributes()` 原先按路径发送 `STAT`，打开文件后若路径被替换会读到另一份
文件的大小。现改为按已打开 handle 发送 `FSTAT`，供下载器在 READ 调度前取得该时点的
size snapshot；移除不再使用的 path 字段，避免误导调用方继续走路径属性；同时以
`NIOLockedValueBox` 保护 `isActive`，并标记 `SFTPFile` 为 `@unchecked Sendable`，使同一
handle 的并发 READ 与结构化 CLOSE 具备明确的生命周期。关闭操作先在锁内原子地 claim
handle，再发送一次 CLOSE，避免并发清理重复发送。上述每个 vendor 修改点均在源码带有
`[Berth patch]` 标记，位置为 `Sources/Citadel/SFTP/Client/SFTPFile.swift` 及
`Sources/Citadel/SFTP/Client/SFTPClient.swift` 的构造调用。
