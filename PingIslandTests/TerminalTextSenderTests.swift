import XCTest
@testable import Ping_Island

// ============================================================
// TerminalTextSenderTests — 终端文本注入服务层单元测试
// ------------------------------------------------------------
// 覆盖四类验收面（全部纯构造函数 / 闭包注入断言，不依赖真实终端）：
//   1. tmux 通道 CLI 参数构造：-l 字面文本与 Enter 分离两步
//   2. Ghostty 通道 AppleScript 构造：三级匹配 + 转义规则
//   3. 换行剥离：防命令注入——Enter 只能走独立的 send-keys / keystroke
//   4. 开关短路：terminalTextSendingEnabled 默认 false，off 时不触碰执行器
// ============================================================

@MainActor
final class TerminalTextSenderTests: XCTestCase {

    // MARK: - 构造助手

    /// 最小可用会话：clientInfo / isInTmux 按用例注入
    private func makeSession(
        isInTmux: Bool = false,
        clientInfo: SessionClientInfo? = nil
    ) -> SessionState {
        SessionState(
            sessionId: "test-session",
            cwd: "/tmp/demo-project",
            clientInfo: clientInfo,
            isInTmux: isInTmux
        )
    }

    /// 命令录制器：捕获 commandRunner 收到的 (path, args) 序列
    private final class CommandRecorder {
        var calls: [(String, [String])] = []
        var stubResult = true

        func runner() -> (String, [String]) async -> Bool {
            { [self] path, args in
                calls.append((path, args))
                return stubResult
            }
        }
    }

    /// AppleScript 录制器：捕获 appleScriptRunner 收到的行序列
    private final class ScriptRecorder {
        var scripts: [[String]] = []
        var stubResult = true

        func runner() -> ([String]) async -> Bool {
            { [self] lines in
                scripts.append(lines)
                return stubResult
            }
        }
    }

    // MARK: - 换行剥离（防注入核心规则）

    func testSanitizedSingleLineKeepsFirstLineOnly() {
        XCTAssertEqual(TerminalTextSender.sanitizedSingleLine("first\nsecond"), "first")
        XCTAssertEqual(TerminalTextSender.sanitizedSingleLine("first\rsecond"), "first")
        XCTAssertEqual(TerminalTextSender.sanitizedSingleLine("plain"), "plain")
    }

    func testSanitizedSingleLineRejectsEmptyAndNewlineOnlyInput() {
        XCTAssertNil(TerminalTextSender.sanitizedSingleLine(""))
        XCTAssertNil(TerminalTextSender.sanitizedSingleLine("\nsecond"))
        XCTAssertNil(TerminalTextSender.sanitizedSingleLine("\n"))
    }

    // MARK: - tmux 通道参数构造

    func testTmuxSendCommandsSeparateLiteralTextAndEnter() {
        // 引号 / 反斜杠按 -l 字面模式原样透传，不做 shell 转义
        let commands = TerminalTextSender.tmuxSendCommands(
            text: "say \"hi\" \\ done",
            targetString: "main:0.1"
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0], ["send-keys", "-t", "main:0.1", "-l", "say \"hi\" \\ done"])
        XCTAssertEqual(commands[1], ["send-keys", "-t", "main:0.1", "Enter"])
    }

    // MARK: - Ghostty 通道 AppleScript 构造

    func testGhosttyScriptMatchesSessionIDFirstThenWorkingDirectoryThenName() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "reply",
            terminalSessionIdentifier: "AAAAAAAA-0000-1111-2222-333333333333",
            workingDirectory: "/tmp/demo-project"
        )
        let script = lines.joined(separator: "\n")

        let idBlock = script.range(of: "first terminal whose id is targetTerminalID")
        let directoryBlock = script.range(of: "every terminal whose working directory is targetPath")
        let nameBlock = script.range(of: "every terminal whose name contains targetName")

        XCTAssertNotNil(idBlock)
        XCTAssertNotNil(directoryBlock)
        XCTAssertNotNil(nameBlock)
        if let idBlock, let directoryBlock, let nameBlock {
            XCTAssertLessThan(idBlock.lowerBound, directoryBlock.lowerBound)
            XCTAssertLessThan(directoryBlock.lowerBound, nameBlock.lowerBound)
        }
    }

    func testGhosttyScriptSendsTextThenEnterKey() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "reply",
            terminalSessionIdentifier: "AAAAAAAA-0000-1111-2222-333333333333",
            workingDirectory: nil
        )
        let script = lines.joined(separator: "\n")

        let inputLine = script.range(of: "input text \"reply\" to targetTerminal")
        let enterLine = script.range(of: "send key \"enter\" to targetTerminal")

        XCTAssertNotNil(inputLine)
        XCTAssertNotNil(enterLine)
        if let inputLine, let enterLine {
            XCTAssertLessThan(inputLine.lowerBound, enterLine.lowerBound)
        }
    }

    func testGhosttyScriptEscapesBackslashAndQuoteOnly() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "say \"hi\" \\ done",
            terminalSessionIdentifier: "AAAAAAAA-0000-1111-2222-333333333333",
            workingDirectory: nil
        )
        let script = lines.joined(separator: "\n")

        // AppleScript 字面量只转义反斜杠与双引号（ovi 实证结论）
        XCTAssertTrue(script.contains("input text \"say \\\"hi\\\" \\\\ done\" to targetTerminal"))
    }

    func testGhosttyScriptSkipsLevelsWithoutKeys() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "reply",
            terminalSessionIdentifier: nil,
            workingDirectory: "/tmp/demo-project"
        )
        let script = lines.joined(separator: "\n")

        // 无 session id：跳过 id 级；有 cwd：走目录级 + 项目名级
        XCTAssertFalse(script.contains("first terminal whose id is targetTerminalID"))
        XCTAssertTrue(script.contains("every terminal whose working directory is targetPath"))
        XCTAssertTrue(script.contains("every terminal whose name contains targetName"))
    }

    func testGhosttyScriptWithoutAnyKeysReturnsErrorOnly() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "reply",
            terminalSessionIdentifier: nil,
            workingDirectory: nil
        )

        // 三级键全空：仅收尾 error，绝不盲发
        XCTAssertEqual(lines.first, "tell application id \"com.mitchellh.ghostty\"")
        XCTAssertTrue(lines.contains("return \"error\""))
        XCTAssertEqual(lines.last, "end tell")
    }

    func testGhosttyScriptUsesCmuxBundleIdentifierWhenProvided() {
        let lines = TerminalTextSender.ghosttySendScriptLines(
            text: "reply",
            terminalSessionIdentifier: nil,
            workingDirectory: nil,
            bundleIdentifier: "com.cmuxterm.app"
        )

        XCTAssertEqual(lines.first, "tell application id \"com.cmuxterm.app\"")
    }

    // MARK: - send 编排：开关短路

    func testSendShortCircuitsWhenDisabled() async {
        let sender = TerminalTextSender()
        let commands = CommandRecorder()
        let scripts = ScriptRecorder()

        let result = await sender.send(
            text: "hello",
            to: makeSession(isInTmux: true),
            enabledReader: { false },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: commands.runner(),
            appleScriptRunner: scripts.runner()
        )

        XCTAssertFalse(result)
        XCTAssertTrue(commands.calls.isEmpty)
        XCTAssertTrue(scripts.scripts.isEmpty)
    }

    // MARK: - send 编排：tmux 通道

    func testSendViaTmuxRunsLiteralThenEnterInOrder() async {
        let sender = TerminalTextSender()
        let commands = CommandRecorder()

        let result = await sender.send(
            text: "hello",
            to: makeSession(isInTmux: true),
            enabledReader: { true },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: commands.runner()
        )

        XCTAssertTrue(result)
        XCTAssertEqual(commands.calls.count, 2)
        XCTAssertEqual(commands.calls[0].0, "/usr/bin/tmux")
        XCTAssertEqual(commands.calls[0].1, ["send-keys", "-t", "main:0.1", "-l", "hello"])
        XCTAssertEqual(commands.calls[1].1, ["send-keys", "-t", "main:0.1", "Enter"])
    }

    func testSendStripsNewlinesBeforeTmuxSend() async {
        let sender = TerminalTextSender()
        let commands = CommandRecorder()

        let result = await sender.send(
            text: "first\nrm -rf /",
            to: makeSession(isInTmux: true),
            enabledReader: { true },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: commands.runner()
        )

        // 换行后内容绝不可达：-l 只收到首行
        XCTAssertTrue(result)
        XCTAssertEqual(commands.calls[0].1, ["send-keys", "-t", "main:0.1", "-l", "first"])
    }

    func testSendViaTmuxFailsWhenTextCommandFails() async {
        let sender = TerminalTextSender()
        let commands = CommandRecorder()
        commands.stubResult = false

        let result = await sender.send(
            text: "hello",
            to: makeSession(isInTmux: true),
            enabledReader: { true },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: commands.runner()
        )

        // 文本步失败即中止，不补发 Enter（半截输入不可提交）
        XCTAssertFalse(result)
        XCTAssertEqual(commands.calls.count, 1)
    }

    func testSendViaTmuxFailsWithoutResolvedTargetOrPath() async {
        let sender = TerminalTextSender()

        // 无 target
        let noTarget = await sender.send(
            text: "hello",
            to: makeSession(isInTmux: true),
            enabledReader: { true },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in nil },
            commandRunner: { _, _ in true }
        )
        XCTAssertFalse(noTarget)

        // 无 tmux 可执行
        let noPath = await sender.send(
            text: "hello",
            to: makeSession(isInTmux: true),
            enabledReader: { true },
            tmuxPathProvider: { nil },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: { _, _ in true }
        )
        XCTAssertFalse(noPath)
    }

    // MARK: - send 编排：Ghostty 通道

    func testSendViaGhosttyRunsScriptWithInputTextAndEnterKey() async {
        let sender = TerminalTextSender()
        let scripts = ScriptRecorder()
        let session = makeSession(clientInfo: SessionClientInfo(
            kind: .claudeCode,
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalSessionIdentifier: "AAAAAAAA-0000-1111-2222-333333333333"
        ))

        let result = await sender.send(
            text: "hello",
            to: session,
            enabledReader: { true },
            commandRunner: { _, _ in false },
            appleScriptRunner: scripts.runner()
        )

        XCTAssertTrue(result)
        XCTAssertEqual(scripts.scripts.count, 1)
        let script = scripts.scripts[0].joined(separator: "\n")
        XCTAssertTrue(script.contains("input text \"hello\" to targetTerminal"))
        XCTAssertTrue(script.contains("send key \"enter\" to targetTerminal"))
    }

    // MARK: - send 编排：不支持通道返回 false

    func testSendReturnsFalseForKeroBundle() async {
        // 本期边界：kero 无外部文本注入接口，URL scheme 只管聚焦
        let sender = TerminalTextSender()
        let commands = CommandRecorder()
        let scripts = ScriptRecorder()
        let session = makeSession(clientInfo: SessionClientInfo(kind: .claudeCode, terminalBundleIdentifier: "sh.kero"))

        let result = await sender.send(
            text: "hello",
            to: session,
            enabledReader: { true },
            commandRunner: commands.runner(),
            appleScriptRunner: scripts.runner()
        )

        XCTAssertFalse(result)
        XCTAssertTrue(commands.calls.isEmpty)
        XCTAssertTrue(scripts.scripts.isEmpty)
    }

    func testSendReturnsFalseForKeroDevBundle() async {
        let sender = TerminalTextSender()
        let session = makeSession(clientInfo: SessionClientInfo(kind: .claudeCode, terminalBundleIdentifier: "sh.kero.dev"))

        let result = await sender.send(
            text: "hello",
            to: session,
            enabledReader: { true },
            commandRunner: { _, _ in true },
            appleScriptRunner: { _ in true }
        )

        XCTAssertFalse(result)
    }

    func testSendReturnsFalseForUnknownTerminal() async {
        let sender = TerminalTextSender()
        let commands = CommandRecorder()
        let session = makeSession(clientInfo: SessionClientInfo(kind: .claudeCode, terminalBundleIdentifier: "com.unknown.terminal"))

        let result = await sender.send(
            text: "hello",
            to: session,
            enabledReader: { true },
            commandRunner: commands.runner(),
            appleScriptRunner: { _ in false }
        )

        XCTAssertFalse(result)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testSendReturnsFalseForRemoteSessions() async {
        // 远程 pane 的 tmux / Ghostty 均在远程主机，本机注入只会错发
        let sender = TerminalTextSender()
        let commands = CommandRecorder()
        let scripts = ScriptRecorder()
        let session = makeSession(
            isInTmux: true,
            clientInfo: SessionClientInfo(kind: .claudeCode, remoteHost: "devbox.local")
        )

        let result = await sender.send(
            text: "hello",
            to: session,
            enabledReader: { true },
            tmuxPathProvider: { "/usr/bin/tmux" },
            tmuxTargetResolver: { _ in TmuxTarget(session: "main", window: "0", pane: "1") },
            commandRunner: commands.runner(),
            appleScriptRunner: scripts.runner()
        )

        XCTAssertFalse(result)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    // MARK: - 设置开关

    func testTerminalTextSendingEnabledDefaultsToFalse() {
        let suiteName = "PingIslandTests.TerminalTextSender.defaults"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertFalse(store.terminalTextSendingEnabled)
    }

    func testTerminalTextSendingEnabledPersistsAfterToggle() {
        let suiteName = "PingIslandTests.TerminalTextSender.persist"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppSettingsStore(defaults: defaults)

        store.terminalTextSendingEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "terminalTextSendingEnabled"))

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.terminalTextSendingEnabled)
    }
}
