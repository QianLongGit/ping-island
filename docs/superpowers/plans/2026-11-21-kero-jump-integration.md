# Kero 终端跳转集成实施计划（ping-island）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ping-island 面板点击 session 可精确跳转到 kero 终端对应 pane（本地 + SSH 远程），现有功能零回归。

**Architecture:** 不引入协议抽象，沿 ping-island 现有三处平行结构做增量：bridge 侧 KERO_PANE 捕获→bundle 推断（HookPayloadMapper）、app 侧注册表镜像（TerminalAppRegistry/HookSocketServer）、focuser switch 加 kero case 走 `kero://focus` URL scheme（kero 侧零改动，resolveJump 级联 session→tty→cwd，session 级联跨 host）。远程跳转以 session_id 为唯一锚点。

**Tech Stack:** Swift（Xcode 工程 + Prototype SwiftPM 包）、XCTest、构建机远程 xcodebuild。

**Spec:** 本文件 + 研究结论（见 Global Constraints 内嵌关键事实）。无独立 spec 文档。

## Global Constraints

- **最小改动原则**：只动下表文件，禁止顺手重构（用户全局规范）。
- **kero 侧零改动**（定案，勿重新评估）。
- **无 git commit/branch 步骤**：用户全局规则——未经用户主动要求绝不 commit/branch。所有改动留在工作树，构建走 rsync 同步到构建机。
- **KERO_PANE 判定必须排在 TERM_PROGRAM=ghostty 推断之前**（kero 内嵌 libghostty-vt，TERM_PROGRAM 会污染为 ghostty；真 Ghostty 无 KERO_PANE）。
- **tty 参数原样透传（含 `/dev/` 前缀）**：kero `internal/proto/proto.go:222` 注释明确 pane.TTY 即外部跳转命名的设备路径格式（`/dev/ttys012`）；hook env TTY 同格式。禁止复用 IDE extension 分支的剥 `/dev/` 逻辑（focuser L259）。
- **bundle id 双变体**：`sh.kero`（release）+ `sh.kero.dev`（dev 构建），所有匹配点两处都覆盖，漏 dev 构建会静默落 default=false。
- **URL 参数 percent-encode**：session/tty/cwd 均需编码（kero 侧 Go url.Query().Get 自动解码）；cwd 是精确相等匹配非前缀。
- **测试双环路**：`swift test --package-path Prototype` 本机 Linux 直接跑（bridge/mapper/payload 逻辑测试放这里）；PingIslandTests 必须 rsync 到构建机跑 `xcodebuild test -only-testing:PingIslandTests`（本机无 macOS）。
- **AGENTS.md 五处同步规则**：改 hook payload 需同步 IslandBridge/HookSocketServer/SessionEvent/SessionStore/UI 链路；major feature 完成后更新 AGENTS.md 支持矩阵。
- **新增代码注释用中文 + ASCII 分块风格**（用户全局规范，优先于代码库英文现状）。

## 关键研究事实（实现者必读）

- 焦点分发：`PingIsland/Services/Window/TerminalSessionFocuser.swift:26-35` `focusSession(terminalPid:tty:candidateProcessIDs:sessionId:clientInfo:workspacePath:launchURL:remoteHostHint:) async -> Bool`；L36-49 用 `NSRunningApplication(processIdentifier:)` 取实际运行 app 的 bundle id；L109-206 switch 硬编码 4 终端 case，default→false。
- ghostty 污染短路点共 3 处：①`Prototype/Sources/IslandShared/HookPayloadMapper.swift` makeTerminalContext（L727-752）+ inferredTerminalBundleID（L754-784）②`PingIsland/Services/Shared/TerminalAppRegistry.swift` terminalBundleIdentifiersByProgram（L26-42）③`PingIsland/Services/Hooks/HookSocketServer.swift` L1552 附近。
- JS hook 模板 ENV_KEYS 在 `HookInstaller.swift` 有 3 处副本（约 L2099/L2717/L3167），改一处必须同步三处。
- 远程链路：`RemoteModels.swift:347-366` RemoteHookClientInfoPayload（研究时无 terminalBundleIdentifier 字段——Task 5 实现时先验证再补）；`RemoteConnectorManager.swift:820-921` NDJSON→HookEvent(ingress:.remoteBridge)；SessionState.isRemoteSession（Models/SessionState.swift:916-931）。远程 hook 跑在远程 kero daemon 下，**远程 shell 环境同样有 KERO_PANE**（daemon 注入，与 SSH env 转发无关）。
- 远程 UI 点击走 `SessionLauncher.swift` activate()（L26-164）瀑布 → isRemoteSession → activateRemoteCarrierTerminal（L789-878，猎取本地 ssh 载体进程——kero 远程场景不适用，kero 的远程连接是 daemon 内部传输，无本地 ssh 进程可猎）。
- kero `jump.go:41-79` resolveJump：session 全 host 级联 → tty 仅本机精确 → cwd 精确（本机优先 tie-break）；无匹配仅聚焦主窗口不报错；`takePendingJump` 支持窗口未就绪时挂起重试。
- 测试范式：`PingIslandTests/TerminalSessionFocuserTests.swift`（153 行 12 测试）纯字符串断言 + static ForTesting 入口；逻辑测试放 `Prototype/Tests/`。

## Review Focus

1. **真 Ghostty 误判为 kero**（TERM_PROGRAM=ghostty 无 KERO_PANE）→ 必须仍识别为 ghostty——Task 1 测试钉死。
2. **kero 误判为真 Ghostty**（KERO_PANE 在但推断顺序错）→ bundle=sh.kero——Task 1 测试钉死。
3. **cwd 含空格/中文时 URL 断裂**→ percent-encode 后 kero 侧解码还原——Task 3 测试钉死。
4. **远程 session 误传远程 tty/cwd**（远程值与本地 pane 永不匹配，还可能碰巧匹配到错误本机 pane）→ remote 仅传 session——Task 3 测试钉死。
5. **sh.kero.dev 静默落 default=false**（switch 漏 dev 变体）→ 两 case 都有——Task 3 测试钉死。
6. **现有 4 终端回归**（Ghostty/iTerm/Terminal/cmux 路径被波及）→ 既有 TerminalSessionFocuserTests 全绿——Task 3/7 回归步骤钉死。

---

### Task 1: Bridge 侧 kero 识别（KERO_PANE 捕获 + bundle 推断）

**Files:**
- Modify: `Prototype/Sources/IslandShared/HookPayloadMapper.swift`（makeTerminalContext L727-752 与 inferredTerminalBundleID L754-784）
- Test: `Prototype/Tests/IslandSharedTests/`（沿用现有 mapper 测试文件组织，无则新建 `HookPayloadMapperKeroTests.swift`）

**Interfaces:**
- Consumes: `TerminalContext`（Models.swift L45-86 现有 12 字段，不新增字段）。
- Produces: 环境含 `KERO_PANE`（非空）时 `terminalContext.terminalProgram == "kero"`、`terminalBundleID == "sh.kero"`；后续任务依赖此约定。mergedMetadata 镜像（L1069-1106）同步出现 `terminal_program=kero` / `terminal_bundle_id=sh.kero`。

- [ ] **Step 1: 写失败测试**（SwiftPM/XCTest，本机 Linux 可跑）：

```swift
func testKeroPaneOverridesGhosttyProgram() {
    // KERO_PANE 存在 + TERM_PROGRAM=ghostty → 判为 kero，不判为 ghostty
    let ctx = HookPayloadMapper.makeTerminalContext(env: ["KERO_PANE": "pane-123", "TERM_PROGRAM": "ghostty", "TTY": "/dev/ttys012", "__CFBundleIdentifier": "sh.kero"], payload: [:])
    XCTAssertEqual(ctx.terminalProgram, "kero")
    XCTAssertEqual(ctx.terminalBundleID, "sh.kero")
}
func testRealGhosttyWithoutKeroPaneStaysGhostty() {
    let ctx = HookPayloadMapper.makeTerminalContext(env: ["TERM_PROGRAM": "ghostty", "TTY": "/dev/ttys012"], payload: [:])
    XCTAssertEqual(ctx.terminalProgram, "ghostty") // 不变
}
```

（注：makeTerminalContext 若非 static/内部不可直达，参照现有 mapper 测试的调用形态调整调用方式，断言不变。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /home/ql/Development/Project/my-vibeisland/ping-island && swift test --package-path Prototype --filter Kero`
Expected: FAIL（terminalProgram 实际为 "ghostty"）

- [ ] **Step 3: 实现**：makeTerminalContext 开头读 `env["KERO_PANE"]`；非空 → terminalProgram="kero"、bundle 推断短路返回 "sh.kero"（排在一切 TERM_PROGRAM 逻辑之前）；`__CFBundleIdentifier` 已能给出 sh.kero/sh.kero.dev 时保留原值不覆盖（dev 构建保真）。inferredTerminalBundleID 对 program=="kero" 返回 "sh.kero"。同步 mergedMetadata 镜像。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path Prototype --filter Kero`
Expected: PASS（含既有 mapper 测试全绿：`swift test --package-path Prototype`）

### Task 2: App 侧注册表 + SocketServer 镜像

**Files:**
- Modify: `PingIsland/Services/Shared/TerminalAppRegistry.swift`（terminalDisplayNamesByBundleIdentifier L12-24、terminalBundleIdentifiersByProgram L26-42、inferredBundleIdentifier(forTerminalProgram:) L167 附近）
- Modify: `PingIsland/Services/Hooks/HookSocketServer.swift`（L1552 附近的 terminalProgram→bundle 推断镜像点）
- Test: `PingIslandTests/`（沿用 TerminalAppRegistry 相关现有测试文件，无则新建 `TerminalAppRegistryKeroTests.swift`）

**Interfaces:**
- Consumes: Task 1 的 program=="kero" 约定。
- Produces: `terminalDisplayNamesByBundleIdentifier["sh.kero"]=="kero"`、`["sh.kero.dev"]=="kero (dev)"`；program "kero" → `[sh.kero, sh.kero.dev]`；ProcessTreeBuilder/clientInfo 查询侧因此能认出 kero daemon 为终端宿主。

- [ ] **Step 1: 写失败测试**：断言上述三个映射（display name、program→bundles、inferredBundleIdentifier("kero")=="sh.kero"；inferredBundleIdentifier("ghostty") 保持原值不回归）。

- [ ] **Step 2: 同步到构建机确认失败**

Run: `rsync -az --delete --exclude .git --exclude build --exclude DerivedData -e "ssh -p 10024" /home/ql/Development/Project/my-vibeisland/ping-island/ dev@43.133.240.214:Development/ping-island/ && ssh -p 10024 dev@43.133.240.214 'cd ~/Development/ping-island && xcodebuild test -scheme PingIsland -only-testing:PingIslandTests/TerminalAppRegistryKeroTests CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -quiet'`
Expected: FAIL（编译错误：测试引用的 kero 映射不存在）

- [ ] **Step 3: 实现**：三张表加 kero 条目（双 bundle id）；HookSocketServer L1552 镜像点：program=="kero"（或 bundle 已是 sh.kero*）时不再落入 ghostty 推断。注释中文。

- [ ] **Step 4: 构建机跑测试确认通过**（命令同 Step 2）
Expected: PASS

### Task 3: Focuser kero 跳转分支 + URL 构造器

**Files:**
- Modify: `PingIsland/Services/Window/TerminalSessionFocuser.swift`（switch L109-206 加 case；新增 static URL 构造器 + 远程入口方法）
- Test: `PingIslandTests/TerminalSessionFocuserTests.swift`

**Interfaces:**
- Produces（后续任务与测试依赖的精确签名）:
  - `static func keroJumpURL(sessionId: String?, tty: String?, cwd: String?, isRemote: Bool) -> URL?` —— 参数为空/nil 则省略对应 query item；`isRemote==true` 时只保留 session（tty/cwd 是远程值，与本地 pane 不匹配）；全空返回 nil；query values 全部 percent-encode（URLComponents queryItems 自动处理，勿手工拼串）
  - `func focusKeroSession(sessionId: String?) async -> Bool` —— 远程直跳入口：`NSWorkspace.shared.open(keroJumpURL(sessionId:sessionId,tty:nil,cwd:nil,isRemote:true))`，open 成功即 true（kero 收到 URL 自行激活/解析/挂起重试）；沿用 FocusDiagnosticsStore.record 记录（模式参照现有分支）
- Consumes: Task 2 注册表（switch 分支由运行中 app 实际 bundle id 触发，不依赖注册表，但 pid 解析链路依赖）。

- [ ] **Step 1: 写失败测试**（纯字符串/URL 断言，模式对齐文件内 ghosttySelectionScriptLines 测试）：
  - `keroJumpURL(sessionId:"abc-uuid", tty:"/dev/ttys012", cwd:"/Users/x/我的 项目", isRemote:false)` → 绝对字符串断言 `kero://focus?session=abc-uuid&tty=%2Fdev%2Fttys012&cwd=...`（cwd 编码后含 `%20` 与中文编码，具体断言以 URLComponents 实际输出为准写死）
  - isRemote:true 同输入 → 只含 `session=abc-uuid`，不含 tty/cwd
  - 全 nil → 返回 nil
  - `keroIsHandledBundleIdentifier("sh.kero")==true`、`("sh.kero.dev")==true`、`("com.mitchellh.ghostty")==false`（新增 static 判定，switch 与 Task 6 复用）

- [ ] **Step 2: 同步构建机确认失败**（命令同 Task 2 Step 2，filter 换 TerminalSessionFocuserTests）
Expected: FAIL（keroJumpURL 不存在，编译错误）

- [ ] **Step 3: 实现**：
  - switch 加 `case KeroBundleIDs`（用 keroIsHandledBundleIdentifier 收敛双变体，勿写两个 fallthrough 空 case）
  - case 体：构造 `keroJumpURL(sessionId:sessionId, tty:tty, cwd:workspacePath, isRemote: remoteHostHint != nil)`，nil 时退化为仅激活（`NSWorkspace.shared.activate` 参照 ghostty 兜底 L681-747 的 activate 分支）；非 nil 则 `NSWorkspace.shared.open(url)`，记 diagnostics
  - focusKeroSession 远程入口（签名见 Interfaces）
  - 注释中文 + ASCII 分块

- [ ] **Step 4: 构建机跑 TerminalSessionFocuserTests 全文件**（含既有 12 测试回归）
Expected: PASS 全绿

### Task 4: Hook 模板透传 KERO_PANE

**Files:**
- Modify: `PingIsland/Services/Hooks/HookInstaller.swift`（ENV_KEYS 3 处副本：约 L2099/L2717/L3167）
- Test: `PingIslandTests/`（若已有 HookInstaller 模板字符串测试文件则追加；无则在 TerminalAppRegistryKeroTests 所在层新建轻量断言）

**Interfaces:**
- Consumes: 无。
- Produces: 新装/重装的 JS hook 会采集 `KERO_PANE` 并入 hook payload env 传给 bridge（Task 1 的 mapper 才能在真实链路见到它）。

- [ ] **Step 1: 写失败测试**：断言 3 处模板副本的 ENV_KEYS 数组均包含 `"KERO_PANE"`（用 rg 确认的 3 个位置为准提取字符串常量断言，防漏同步）。
- [ ] **Step 2: 构建机确认失败**（同前同步+测试命令）Expected: FAIL
- [ ] **Step 3: 实现**：3 处 ENV_KEYS 加 `"KERO_PANE"`；查 HookInstaller 的 hook 版本号/重装触发机制（rg "version" HookInstaller.swift），若模板内容参与版本指纹则版本号自增使存量安装自动更新——按实际机制处理并在返回报告中说明。
- [ ] **Step 4: 构建机确认通过** Expected: PASS

### Task 5: 远程 payload 携带 kero 标识

**Files:**
- Modify: `Prototype/Sources/IslandShared/RemoteModels.swift`（RemoteHookClientInfoPayload L347-366——**先验证**：rg 确认该 struct 现有字段全集，若已有 terminalBundleIdentifier/terminalProgram 字段则本任务只剩验证+测试，跳过结构改动）
- Modify（按需）: `Prototype/Sources/IslandBridge/` 中组装 RemoteHookEventPayload 的位置、`PingIsland/Services/Hooks/HookSocketServer.swift` clientInfo 重建点（L820-940）
- Test: `Prototype/Tests/`（payload 编解码 roundtrip 测试，Linux 本机跑）

**Interfaces:**
- Consumes: Task 1（bridge 侧 terminalBundleID 已能为 "sh.kero"）。
- Produces: 远程 session 的 `SessionClientInfo.terminalBundleIdentifier == "sh.kero"`（或 "sh.kero.dev"），Task 6 依赖。

- [ ] **Step 1: 验证现状**：rg RemoteHookClientInfoPayload 全部字段与组装/重建两端位置，报告实际缺口。
- [ ] **Step 2: 写失败测试**：roundtrip——远程 hook 事件 JSON（clientInfo 含 terminalBundleIdentifier=sh.kero）→ 解码 → 重建 SessionClientInfo 字段保持。
- [ ] **Step 3: 本机跑确认失败** `swift test --package-path Prototype --filter Remote` Expected: FAIL
- [ ] **Step 4: 实现**：补字段贯穿（RemoteModels → bridge 组装 → HookSocketServer 重建），遵循 AGENTS.md 五处同步规则检查 SessionEvent/SessionStore/UI 是否需要透传（判定标准：UI 点击链路能拿到即可，不渲染则不动 UI）。
- [ ] **Step 5: 本机跑确认通过**（含全量 `swift test --package-path Prototype` 回归）Expected: PASS

### Task 6: SessionLauncher 远程 kero 直跳

**Files:**
- Modify: `PingIsland/Services/Window/SessionLauncher.swift`（activate() 瀑布 L26-164，isRemoteSession 分支 L60-64 处）
- Test: 逻辑薄（一行路由），测试靠 Task 3 的 focusKeroSession/keroIsHandledBundleIdentifier 断言 + Task 8 真机 QA 覆盖；本任务不新增单测（避免为路由行造假 mock）。

**Interfaces:**
- Consumes: Task 3 `focusKeroSession(sessionId:)`、`keroIsHandledBundleIdentifier(_:)`；Task 5 远程 clientInfo.terminalBundleIdentifier。
- Produces: 远程 kero session 点击不再走 activateRemoteCarrierTerminal 的 ssh 载体猎取（kero 远程无本地 ssh 进程，猎取必失败落 fallback）。

- [ ] **Step 1: 实现**：activate() 的 isRemoteSession 分支入口处，`if let bi = session.clientInfo?.terminalBundleIdentifier, TerminalSessionFocuser.keroIsHandledBundleIdentifier(bi), let sid = session.sessionId { return await TerminalSessionFocuser.shared.focusKeroSession(sessionId: sid) }`（字段名以实际 SessionState/SessionClientInfo 为准；session_id 必须无条件透传——研究确认 activateTerminal 调用点已传）。
- [ ] **Step 2: 构建机全量 PingIslandTests 回归** Expected: PASS（无既有测试因路由顺序变化而挂）

### Task 7: 文档 + 全量回归 + 出包

**Files:**
- Modify: `AGENTS.md`（终端支持矩阵加 kero：本地 session/tty/cwd 级联 + 远程 session 级联）

- [ ] **Step 1: AGENTS.md 加 kero 条目**（含 KERO_PANE 判别、双 bundle id、kero://focus 机制一句话）。
- [ ] **Step 2: 本机全量**：`swift test --package-path Prototype` Expected: 全绿
- [ ] **Step 3: rsync → 构建机全量**：`xcodebuild test -only-testing:PingIslandTests` + `./scripts/package-unsigned.sh` Expected: 全绿 + DMG 落盘 `releases/unsigned/`

### Task 8: 真机验收（需用户参与）

- [ ] Step 1: DMG scp 到日常机 192.168.3.95 安装（kero ≥2.3.41 在位）。
- [ ] Step 2: 本地跳转验收：kero 本地 pane 里跑 claude（pi hook 装好）→ 面板点击 → kero 激活且选中对应 pane。
- [ ] Step 3: 远程跳转验收：kero 内连远程机 43.133.240.214:10022 跑 agent → 面板点击远程 session → kero 激活且选中对应远程 pane。
- [ ] Step 4: 回归验收：Ghostty/iTerm/Terminal 任一现有终端点击跳转仍正常。

---

## 增补：终端名单扩展任务（N1-N4，用户 2026-11-21 m00260 拍板"全部都本期实现"）

> 设计依据：`.superpowers/sdd/2026-11-21-kero-jump-integration/port-research-report.md`（file:line 全实读；实现时以该报告为准，本节只锁任务边界与验收）。
> 顺序约束：N1-N4 全部在 **T3 之后**（focuser switch 同区，kero case 先落）；T7 全量回归/出包与 T8 验收范围自动扩展覆盖本节全部产物。

### Task N1: WezTerm + Kaku 跳转（共用逻辑，先行）

**Files:**
- Modify: `PingIsland/Services/Window/TerminalSessionFocuser.swift`（switch 加 `case "com.github.wez.wezterm", "fun.tw93.kaku":`，新方法 `focusWezTermFamilyPane(bundleIdentifier:tty:workspacePath:sessionId:) async -> Bool`）
- Modify: `PingIsland/Services/Shared/TerminalAppRegistry.swift`（Kaku 四表条目；顺手核对 L22 `"dev.warp.warp-stable"` 小写键是否笔误）
- Modify: `Prototype/Sources/IslandShared/HookPayloadMapper.swift`（inferredTerminalBundleID 加 `case "kaku"`）
- Test: `PingIslandTests/TerminalAppRegistryTests.swift` 追加 + focuser ForTesting 断言（CLI 参数数组 `["cli","list","--format","json"]` / `["cli","activate-pane","--pane-id",...]`）

**Interfaces:**
- Produces: WezTerm/Kaku 点击跳转（CLI 路径解析→`cli list`→四级匹配 sessionID>tty>cwd(标准化)>title→`activate-pane`→NSRunningApplication.activate）。无权限、无 env、无包结构改动。
- 风险（真机验证归 T8）：tty 逐字相等、多窗口 activate 带前台。

- [ ] Step 1: RED——registry Kaku 表项断言 + CLI 参数断言失败
- [ ] Step 2: 构建机确认 FAIL（xcodebuild）
- [ ] Step 3: 实现（报告 §1.1/§3.2；CLI 解析候选路径 + `/usr/bin/which` 兜底；失败记 FocusDiagnostics 对齐现有风格）
- [ ] Step 4: 构建机确认 PASS + 全量 PingIslandTests 回归

### Task N2a: Warp 数据层（识别 + pane UUID 解析 + 字段贯穿）

**Files:**
- New: `Prototype/Sources/IslandShared/WarpSQLiteReader.swift`（自 ovi 移植，`import SQLite3`）
- New: `Prototype/Sources/IslandShared/WarpProcessResolver.swift`（**整文件 `#if canImport(Darwin)`**——IslandBridge 有 Linux 构建）
- Modify: `Prototype/Sources/IslandBridge/main.swift`（terminalProgram 含 "warp" 或 WARP_IS_LOCAL_SHELL_SESSION → resolver+reader 填 `warp_pane_uuid` 入 envelope metadata）
- Modify: `PingIsland/Services/Socket/HookSocketServer.swift`（clientInfo 重建区）+ `PingIsland/Models/SessionProvider.swift`（SessionClientInfo 加 `warpPaneIdentifier`）——**AGENTS.md 五处同步规约：HookSocketServer/SessionEvent/SessionStore/UI 同步加字段透传**
- Test: `Prototype/Tests/IslandTests/`（纯函数：cwdLookupCandidates firmlink、glob 串、lookupPaneUUIDByShellPID(_:siblings:)、resolver 注入式爬链）

- [ ] Step 1: RED（Prototype/Tests，构建机 swift test）
- [ ] Step 2: 构建机确认 FAIL
- [ ] Step 3: 实现（报告 §2.1；bridge 独立轻量爬链，不复用 app 侧代码）
- [ ] Step 4: 构建机确认 PASS + `swift test --package-path Prototype` 全量

### Task N2b: Warp 焦点跳转（focuser case + AX Tab 前进）

**Files:**
- Modify: `PingIsland/Services/Window/TerminalSessionFocuser.swift`（`case "dev.warp.Warp-Stable":` → `focusWarpPane(...)`：open -b→frontmost 轮询 1.5s/25ms→fast path→tabCount+2 循环；focusedPaneReader/tabCountReader/keystroker 做成注入点供测试）
- New: `PingIsland/Services/Window/WarpTabAdvancer.swift`（AX 菜单点击 AppleScript，协议注入点）
- Modify: `PingIsland.xcodeproj/project.pbxproj`（XCLocalSwiftPackageReference Prototype + app target 链接 IslandShared，仿 Sparkle 区 pbxproj:841-855）
- Test: `PingIslandTests/`（spy 范式：fast-path 零 keystroke、N 次命中、tabCount+2 封顶；AppleScript 文本断言）

**裁定**：全量实现（非 MVP）；reader/循环失败静默降级为"仅激活 Warp"（ovi 同款降级）。app 侧爬链如需要改用 ProcessTreeBuilder 全量快照。需辅助功能权限（真机首跑弹窗，T8 验收项）。

- [ ] Step 1-4: 同 TDD 环（RED→构建机 FAIL→实现→构建机 PASS + 回归）

### Task N3: TerminalTextSender 服务层（tmux + Ghostty 双通道）

**Files:**
- New: `PingIsland/Services/Window/TerminalTextSender.swift`（`static func canSendText(...) -> Bool` + `static func send(_ text:, ...) async -> Bool`；tmux 通道对齐 `PingIsland/Services/Tmux/ToolApprovalHandler.swift:58-70` 既有 send-keys 模式避免第三份副本；Ghostty AppleScript `input text`/`send key` 从 ovi ghosttySendScript 移植；**门控保留 ovi 语义：仅 completed 相位开放**）
- Modify: `PingIsland/Core/Settings.swift`（`terminalTextSendEnabled` 默认 false）+ `SettingsWindowView.swift` 开关
- 权限：Ghostty 通道走既有 `TerminalAutomationPermissionCoordinator.ensurePermissionIfNeeded`
- Test: `PingIslandTests/`（canSendText 门控矩阵、tmux 参数构造、AppleScript 文本断言）

- [ ] Step 1-4: 同 TDD 环

### Task N4: 发送 UI 挂点（依赖 N3）

**Files:**
- Modify: `PingIsland/UI/Views/SessionHoverPreviewView.swift`（完成态会话加"发送文本到终端"输入行——ovi completionReply 交互的最小移植；开关 Settings.terminalTextSendEnabled 门控）

- [ ] Step 1: 实现（薄 UI 层，逻辑全在 N3，测试以 N3 单测 + T8 真机为准）
- [ ] Step 2: 构建机全量回归

### 范围裁定（ledger 同步）
- ovi 双 Probe（ForegroundTerminalSessionProbe/AttachmentProbe）**不移植**：pi ProcessTreeBuilder 已有等价能力，不重复建设。
- KeystrokeInjector 不独立移植：并入 N2b WarpTabAdvancer。
- T7 AGENTS.md 矩阵与 T8 验收清单自动扩展：WezTerm/Kaku/Warp 本地跳转 + Warp 辅助权限首跑 + TextSender 发送（tmux/Ghostty 各一）。
