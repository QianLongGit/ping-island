//
//  TerminalTextSender.swift
//  PingIsland
//
//  终端文本注入服务层：把用户输入的回复文本送进宿主终端
//

import Foundation
import AppKit
import os.log

// ============================================================
// TerminalTextSender — 按宿主终端分流的文本注入服务
// ------------------------------------------------------------
// 通道矩阵（本期）：
//   - tmux   ：send-keys -l 字面文本 + send-keys Enter 分离两步
//   - Ghostty：AppleScript input text / send key（cmux 同构复用）
//   - kero   ：本期不做——kero 无外部文本注入接口，
//              URL scheme 只管聚焦（见 TerminalSessionFocuser）
//   - 其他   ：返回 false，绝不猜测目标
//
// 安全红线（防命令注入）：
//   1. 换行禁止随文本注入——发送前剥离至首行，Enter 只能由
//      独立的 send-keys / keystroke 步骤显式触发；
//   2. 远程会话不注入——远程 pane 的 tmux / Ghostty 均在远程
//      主机，本机注入只会错发；
//   3. 总开关 terminalTextSendingEnabled 默认 false，off 时
//      在触碰任何执行器之前短路。
//
// IO 注入范式与 TerminalSessionFocuser.focusWarpTerminal 一致：
// 可选闭包参数，默认绑生产实现，测试整体可替换。
// ============================================================

actor TerminalTextSender {
    static let shared = TerminalTextSender()

    /// 日志（nonisolated static 供跨上下文访问，ToolApprovalHandler 同款）
    nonisolated static let logger = Logger(
        subsystem: "com.wudanwu.pingisland",
        category: "TextSender"
    )

    // ============================================================
    // MARK: - 对外入口
    // ============================================================

    /// 把 `text` 连同一次回车送进 `session` 的宿主终端。
    ///
    /// 返回 `true` 表示两步（文本 + Enter）全部投递成功；
    /// 开关关闭 / 远程会话 / 文本为空 / 通道不支持均返回 `false`。
    @discardableResult
    func send(
        text: String,
        to session: SessionState,
        enabledReader: (() async -> Bool)? = nil,
        tmuxPathProvider: (() async -> String?)? = nil,
        tmuxTargetResolver: ((SessionState) async -> TmuxTarget?)? = nil,
        commandRunner: ((String, [String]) async -> Bool)? = nil,
        appleScriptRunner: (([String]) async -> Bool)? = nil
    ) async -> Bool {
        // ---- 0. 总开关（默认 false；off 时不触碰任何执行器）----
        let isEnabled = await (enabledReader ?? Self.readEnabledSetting)()
        guard isEnabled else {
            await Self.record("TextSend skip-disabled session=\(session.sessionId)")
            return false
        }

        // ---- 1. 远程会话：本机注入只会错发，直接拒绝 ----
        guard !session.isRemoteSession else {
            await Self.record("TextSend skip-remote session=\(session.sessionId)")
            return false
        }

        // ---- 2. 换行剥离（防注入红线：Enter 只走独立步骤）----
        guard let singleLine = Self.sanitizedSingleLine(text) else {
            await Self.record("TextSend skip-empty-text session=\(session.sessionId)")
            return false
        }

        // ---- 3. 按宿主终端分流 ----
        if session.isInTmux {
            return await sendViaTmux(
                singleLine,
                session: session,
                tmuxPathProvider: tmuxPathProvider,
                tmuxTargetResolver: tmuxTargetResolver,
                commandRunner: commandRunner
            )
        }

        if let bundleIdentifier = session.clientInfo.terminalBundleIdentifier {
            switch bundleIdentifier {
            case "com.mitchellh.ghostty", "com.cmuxterm.app":
                // cmux 基于 Ghostty，AppleScript 接口同构（focuser 同款先例）
                return await sendViaGhostty(
                    singleLine,
                    session: session,
                    bundleIdentifier: bundleIdentifier,
                    appleScriptRunner: appleScriptRunner
                )
            case "sh.kero", "sh.kero.dev":
                // 本期边界：kero 无 AppleScript / 外部注入接口
                await Self.record("TextSend skip-kero-unsupported session=\(session.sessionId)")
                return false
            default:
                break
            }
        }

        // 其他终端（含 bundle 标识缺失）：不支持，绝不猜测目标
        await Self.record(
            "TextSend skip-unsupported-terminal session=\(session.sessionId) bundle=\(session.clientInfo.terminalBundleIdentifier ?? "nil")"
        )
        return false
    }

    // ============================================================
    // MARK: - 纯构造函数（测试面，无 IO）
    // ============================================================

    /// 剥离换行：只保留首行；首行为空（含纯换行输入）返回 nil。
    ///
    /// "a\nrm -rf /" → "a"——换行之后的内容绝不可达，
    /// 从源头掐断"借换行注入第二条命令"的攻击面。
    static func sanitizedSingleLine(_ text: String) -> String? {
        guard let firstLine = text.components(separatedBy: .newlines).first,
              !firstLine.isEmpty else {
            return nil
        }
        return firstLine
    }

    /// tmux 通道两步命令参数：字面文本与 Enter 严格分离。
    ///
    /// -l 字面模式下引号 / 反斜杠按原样透传，不做 shell 转义；
    /// 第二步的 Enter 是显式 key 名，不接受文本内嵌。
    static func tmuxSendCommands(text: String, targetString: String) -> [[String]] {
        [
            ["send-keys", "-t", targetString, "-l", text],
            ["send-keys", "-t", targetString, "Enter"]
        ]
    }

    /// Ghostty 通道 AppleScript：三级匹配（唯一命中才投递）。
    ///
    /// 匹配优先级（对齐 ovi TerminalJumpTargetResolver 语义）：
    ///   1. terminal session id（UUID 精确，经 focuser 同款归一化）
    ///   2. working directory（精确相等且唯一）
    ///   3. 项目名（cwd 尾段 contains 且唯一）
    /// 发送通道语义不同于聚焦——错发比不发更糟，任何一级
    /// 都要求恰好一个候选，三级键全空时直接收尾 error。
    static func ghosttySendScriptLines(
        text: String,
        terminalSessionIdentifier: String?,
        workingDirectory: String?,
        bundleIdentifier: String = "com.mitchellh.ghostty"
    ) -> [String] {
        var lines = ["tell application id \(appleScriptStringLiteral(bundleIdentifier))"]

        // ---- 第一级：session id 精确匹配 ----
        if let sessionID = TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(
            terminalSessionIdentifier
        ) {
            lines.append(contentsOf: [
                "set targetTerminalID to \(appleScriptStringLiteral(sessionID))",
                "try",
                "set targetTerminal to first terminal whose id is targetTerminalID",
                "input text \(appleScriptStringLiteral(text)) to targetTerminal",
                "send key \"enter\" to targetTerminal",
                "return \"ok\"",
                "end try"
            ])
        }

        // ---- 第二 / 三级：working directory 精确，项目名 contains 兜底 ----
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            lines.append(contentsOf: [
                "set targetPath to \(appleScriptStringLiteral(directory))",
                "set exactMatches to every terminal whose working directory is targetPath",
                "if (count of exactMatches) is 1 then",
                "set targetTerminal to item 1 of exactMatches",
                "input text \(appleScriptStringLiteral(text)) to targetTerminal",
                "send key \"enter\" to targetTerminal",
                "return \"ok\"",
                "end if"
            ])

            let projectName = URL(fileURLWithPath: directory).lastPathComponent
            if !projectName.isEmpty {
                lines.append(contentsOf: [
                    "set targetName to \(appleScriptStringLiteral(projectName))",
                    "set nameMatches to every terminal whose name contains targetName",
                    "if (count of nameMatches) is 1 then",
                    "set targetTerminal to item 1 of nameMatches",
                    "input text \(appleScriptStringLiteral(text)) to targetTerminal",
                    "send key \"enter\" to targetTerminal",
                    "return \"ok\"",
                    "end if"
                ])
            }
        }

        // ---- 收尾：全部失配即不发（绝不盲发到任意终端）----
        lines.append(contentsOf: [
            "return \"error\"",
            "end tell"
        ])

        return lines
    }

    // ============================================================
    // MARK: - 通道实现（薄编排层）
    // ============================================================

    /// tmux 通道：解析路径与目标 → 两步命令依序执行。
    private func sendViaTmux(
        _ text: String,
        session: SessionState,
        tmuxPathProvider: (() async -> String?)?,
        tmuxTargetResolver: ((SessionState) async -> TmuxTarget?)?,
        commandRunner: ((String, [String]) async -> Bool)?
    ) async -> Bool {
        let resolvePath = tmuxPathProvider ?? {
            await TmuxPathFinder.shared.getTmuxPath()
        }
        // 目标解析级联与 SessionLauncher.activateTmuxSession 同款：
        // 进程树匹配优先，cwd 兜底
        let resolveTarget = tmuxTargetResolver ?? { session in
            if let pid = session.pid,
               let byPid = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
                return byPid
            }
            return await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd)
        }
        let run = commandRunner ?? { path, arguments in
            (try? await ProcessExecutor.shared.run(path, arguments: arguments)) != nil
        }

        guard let tmuxPath = await resolvePath() else {
            await Self.record("TextSend tmux no-executable session=\(session.sessionId)")
            return false
        }
        guard let target = await resolveTarget(session) else {
            await Self.record("TextSend tmux no-target session=\(session.sessionId)")
            return false
        }

        // 文本步失败即中止——半截输入不可提交，绝不补发 Enter
        for arguments in Self.tmuxSendCommands(text: text, targetString: target.targetString) {
            guard await run(tmuxPath, arguments) else {
                await Self.record(
                    "TextSend tmux command-failed session=\(session.sessionId) target=\(target.targetString)"
                )
                return false
            }
        }
        await Self.record("TextSend tmux delivered session=\(session.sessionId) target=\(target.targetString)")
        return true
    }

    /// Ghostty 通道：构造三级匹配脚本后交给 NSAppleScript。
    private func sendViaGhostty(
        _ text: String,
        session: SessionState,
        bundleIdentifier: String,
        appleScriptRunner: (([String]) async -> Bool)?
    ) async -> Bool {
        let runScript = appleScriptRunner ?? { lines in
            await self.runAppleScriptLines(lines)
        }
        let lines = Self.ghosttySendScriptLines(
            text: text,
            terminalSessionIdentifier: session.clientInfo.terminalSessionIdentifier,
            workingDirectory: session.cwd,
            bundleIdentifier: bundleIdentifier
        )
        let delivered = await runScript(lines)
        if !delivered {
            await Self.record(
                "TextSend ghostty script-failed session=\(session.sessionId) bundle=\(bundleIdentifier)"
            )
        }
        return delivered
    }

    // ============================================================
    // MARK: - 私有助手
    // ============================================================

    /// 读取总开关（默认 false，见 AppSettingsStore）
    private static func readEnabledSetting() async -> Bool {
        await MainActor.run {
            AppSettingsStore.shared.terminalTextSendingEnabled
        }
    }

    /// AppleScript 字面量：只转义反斜杠与双引号（ovi 实证结论）
    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// 执行 AppleScript 行序列，返回是否拿到 "ok"（focuser 同款范式）
    private func runAppleScriptLines(_ lines: [String]) async -> Bool {
        await MainActor.run {
            let source = lines.joined(separator: "\n")
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                Self.logger.error("AppleScript compilation failed")
                return false
            }
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                Self.logger.error(
                    "AppleScript failed: \(String(describing: errorInfo), privacy: .public)"
                )
                return false
            }
            let output = result.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output == "ok"
        }
    }

    /// 诊断事件落盘（FocusDiagnosticsStore 同款通道）
    private static func record(_ message: String) async {
        await FocusDiagnosticsStore.shared.record(message)
    }
}
