//
//  TerminalSessionFocuser.swift
//  PingIsland
//
//  Focuses a specific terminal tab/session using stable terminal identifiers when
//  the host app supports scripting, falling back to TTY matching when needed.
//

import AppKit
import Foundation
import os.log

actor TerminalSessionFocuser {
    static let shared = TerminalSessionFocuser()
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "TerminalFocus")
    private let iTermSelectionRetryDelayNanoseconds: UInt64 = 250_000_000

    struct GhosttyTerminalSnapshot: Equatable {
        let terminalSessionIdentifier: String
        let workingDirectory: String?
        let title: String?
    }

    private init() {}

    func focusSession(
        terminalPid: Int,
        tty: String?,
        candidateProcessIDs: [Int] = [],
        sessionId: String? = nil,
        clientInfo: SessionClientInfo? = nil,
        workspacePath: String? = nil,
        launchURL: String? = nil,
        remoteHostHint: String? = nil
    ) async -> Bool {
        guard let appInfo = await MainActor.run(body: {
            NSRunningApplication(processIdentifier: pid_t(terminalPid)).map {
                (
                    bundleIdentifier: $0.bundleIdentifier,
                    localizedName: $0.localizedName
                )
            }
        }) else {
            logger.debug("No running app found for terminal pid \(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus no-running-app terminalPid=\(terminalPid) tty=\(tty ?? "nil") sessionId=\(sessionId ?? "nil")"
            )
            return false
        }

        let bundleIdentifier = appInfo.bundleIdentifier ?? ""
        let localizedName = appInfo.localizedName ?? ""
        let logTTY = tty ?? "unknown"

        logger.debug("Attempting scripted focus terminalPid=\(terminalPid, privacy: .public) bundle=\(bundleIdentifier, privacy: .public) tty=\(logTTY, privacy: .public)")
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus start terminalPid=\(terminalPid) bundle=\(bundleIdentifier) tty=\(logTTY) sessionId=\(sessionId ?? "nil") clientSession=\(clientInfo?.terminalSessionIdentifier ?? "nil") iTermSession=\(clientInfo?.iTermSessionIdentifier ?? "nil")"
        )

        if let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: bundleIdentifier,
            appName: localizedName
        ), IDEExtensionInstaller.isInstalled(profile) {
            let activatedIDEWindow: Bool
            if profile.prefersWorkspaceWindowRouting {
                activatedIDEWindow = await SessionLauncher.routeIDEWorkspaceWindow(
                    detectedBundleIdentifier: bundleIdentifier,
                    appName: localizedName,
                    workspacePath: workspacePath,
                    fallbackLaunchURL: launchURL,
                    additionalBundleIdentifiers: profile.localAppBundleIdentifiers
                )
            } else {
                activatedIDEWindow = await MainActor.run {
                    guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
                        return false
                    }

                    if app.isHidden {
                        app.unhide()
                    }

                    return app.activate(options: [])
                }
            }

            if activatedIDEWindow {
                _ = await SessionLauncher.waitForIDEWindowActivation(
                    bundleIdentifiers: [bundleIdentifier] + profile.localAppBundleIdentifiers
                )
            }

            let pids = candidateProcessIDs.isEmpty ? [terminalPid] : candidateProcessIDs
            if await focusWithExtension(
                profile: profile,
                processIDs: pids,
                tty: tty,
                sessionId: sessionId,
                clientInfo: clientInfo,
                workspacePath: workspacePath
            ) {
                logger.debug("Focused IDE terminal via URI extension profile=\(profile.id, privacy: .public) pids=\(String(describing: pids), privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus ide-extension success profile=\(profile.id) terminalPid=\(terminalPid)"
                )
                return true
            }
        }

        switch bundleIdentifier {
        case "com.apple.Terminal":
            guard let tty else {
                logger.debug("No tty available for Terminal bundle \(bundleIdentifier, privacy: .public); skipping AppleScript fallback")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus terminal skip-no-tty terminalPid=\(terminalPid)"
                )
                return false
            }
            guard await TerminalAutomationPermissionCoordinator.shared.ensurePermissionIfNeeded(
                terminalPid: terminalPid,
                bundleIdentifier: bundleIdentifier,
                sessionId: sessionId
            ) else {
                logger.debug("Automation permission unavailable for Terminal bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus terminal skip-no-automation-permission terminalPid=\(terminalPid) sessionId=\(sessionId ?? "nil")"
                )
                return false
            }
            return await runAppleScript(lines: terminalScriptLines(for: tty))
        case "com.googlecode.iterm2":
            let iTermSessionIdentifier = clientInfo?.iTermSessionIdentifier ?? clientInfo?.terminalSessionIdentifier
            guard let selector = iTermScriptSelector(
                for: tty,
                sessionIdentifier: iTermSessionIdentifier,
                titleHint: remoteHostHint
            ) else {
                logger.debug("No iTerm session identifier or tty available for bundle \(bundleIdentifier, privacy: .public); skipping AppleScript fallback")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus iterm skip-no-selector terminalPid=\(terminalPid) tty=\(tty ?? "nil") sessionIdentifier=\(iTermSessionIdentifier ?? "nil")"
                )
                return false
            }

            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus iterm applescript terminalPid=\(terminalPid) tty=\(tty ?? "nil") normalizedSessionIdentifier=\(normalizedITermSessionIdentifier(iTermSessionIdentifier) ?? "nil")"
            )
            guard await TerminalAutomationPermissionCoordinator.shared.ensurePermissionIfNeeded(
                terminalPid: terminalPid,
                bundleIdentifier: bundleIdentifier,
                sessionId: sessionId
            ) else {
                logger.debug("Automation permission unavailable for iTerm bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus iterm skip-no-automation-permission terminalPid=\(terminalPid) sessionId=\(sessionId ?? "nil")"
                )
                return false
            }
            return await focusITermSession(terminalPid: terminalPid, selector: selector)
        case "com.mitchellh.ghostty":
            let ghosttyTerminalIdentifier = clientInfo?.terminalSessionIdentifier
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus ghostty applescript terminalPid=\(terminalPid) terminalIdentifier=\(ghosttyTerminalIdentifier ?? "nil") workspacePath=\(workspacePath ?? "nil")"
            )
            guard await TerminalAutomationPermissionCoordinator.shared.ensurePermissionIfNeeded(
                terminalPid: terminalPid,
                bundleIdentifier: bundleIdentifier,
                sessionId: sessionId
            ) else {
                logger.debug("Automation permission unavailable for Ghostty bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus ghostty skip-no-automation-permission terminalPid=\(terminalPid) sessionId=\(sessionId ?? "nil")"
                )
                return false
            }
            return await focusGhosttyTerminal(
                bundleIdentifier: bundleIdentifier,
                terminalPid: terminalPid,
                terminalSessionIdentifier: ghosttyTerminalIdentifier,
                workspacePath: workspacePath,
                titleHint: remoteHostHint
            )
        case "com.cmuxterm.app":
            // cmux is based on Ghostty, reuse Ghostty focus logic
            let cmuxTerminalIdentifier = clientInfo?.terminalSessionIdentifier
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus cmux applescript terminalPid=\(terminalPid) terminalIdentifier=\(cmuxTerminalIdentifier ?? "nil") workspacePath=\(workspacePath ?? "nil")"
            )
            guard await TerminalAutomationPermissionCoordinator.shared.ensurePermissionIfNeeded(
                terminalPid: terminalPid,
                bundleIdentifier: bundleIdentifier,
                sessionId: sessionId
            ) else {
                logger.debug("Automation permission unavailable for cmux bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus cmux skip-no-automation-permission terminalPid=\(terminalPid) sessionId=\(sessionId ?? "nil")"
                )
                return false
            }
            return await focusGhosttyTerminal(
                bundleIdentifier: bundleIdentifier,
                terminalPid: terminalPid,
                terminalSessionIdentifier: cmuxTerminalIdentifier,
                workspacePath: workspacePath,
                titleHint: remoteHostHint
            )
        case _ where Self.keroIsHandledBundleIdentifier(bundleIdentifier):
            // ============================================================
            // kero：kero://focus URL scheme 跳转（sh.kero / sh.kero.dev
            // 双变体经 static 判定收敛）。构造 URL 后交给 NSWorkspace
            // 路由，kero 侧自行解析目标 pane 并在未就绪时挂起重试。
            // ============================================================
            let isRemote = remoteHostHint != nil
            if let jumpURL = Self.keroJumpURL(
                sessionId: sessionId,
                tty: tty,
                cwd: workspacePath,
                isRemote: isRemote
            ) {
                let opened = await MainActor.run {
                    NSWorkspace.shared.open(jumpURL)
                }
                logger.debug("Opened kero focus URL opened=\(opened, privacy: .public) remote=\(isRemote, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus kero url-scheme terminalPid=\(terminalPid) bundle=\(bundleIdentifier) remote=\(isRemote) success=\(opened)"
                )
                return opened
            }

            // 三参全空且非远程：无凭据可寻 pane，退化为仅激活 kero 主窗口
            let activated = await MainActor.run {
                guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
                    return false
                }
                if app.isHidden {
                    app.unhide()
                }
                return app.activate(options: [])
            }
            logger.debug("Degraded kero focus to plain activation activated=\(activated, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus kero activate-only terminalPid=\(terminalPid) bundle=\(bundleIdentifier) success=\(activated)"
            )
            return activated
        case "com.github.wez.wezterm", "fun.tw93.kaku":
            // ============================================================
            // WezTerm 家族（WezTerm / Kaku）：CLI 通道精确跳转
            // （list → 三级匹配 → activate-pane）。远程 session 不
            // 走本通道：本地 CLI 无法寻址远程主机上的 pane，返回
            // false 交还上层瀑布（fallback 激活照常生效）。
            // ============================================================
            guard remoteHostHint == nil else {
                logger.debug("Skipping WezTerm-family CLI jump for remote session bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus wezterm skip-remote bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
                )
                return false
            }
            return await focusWeztermFamilyTerminal(
                bundleIdentifier: bundleIdentifier,
                terminalPid: terminalPid,
                sessionIdentifier: clientInfo?.terminalSessionIdentifier,
                tty: tty,
                workspacePath: workspacePath
            )
        case "dev.warp.Warp-Stable":
            // ============================================================
            // Warp：SQLite 焦点轮询 + AX 菜单点击精确跳转（N2b）。
            // 目标 pane UUID 由 N2a 在 bridge hook 侧解析后经
            // clientInfo.warpPaneIdentifier 贯穿到达。远程 session
            // 直退 false——本地无 Warp 窗口可寻址，与 WezTerm
            // skip-remote 同模式（Warp 无跨机通道）。
            // ============================================================
            guard remoteHostHint == nil else {
                logger.debug("Skipping Warp jump for remote session bundle \(bundleIdentifier, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus warp skip-remote bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
                )
                return false
            }
            return await focusWarpTerminal(
                terminalPid: terminalPid,
                targetPaneUUID: clientInfo?.warpPaneIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        default:
            logger.debug("No scripted focuser for bundle \(bundleIdentifier, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus unsupported bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
            )
            return false
        }
    }

    func focusHostedSession(
        sessionId: String? = nil,
        clientInfo: SessionClientInfo,
        workspacePath: String? = nil
    ) async -> Bool {
        let detectedBundleIdentifier = clientInfo.terminalBundleIdentifier ?? clientInfo.bundleIdentifier
        let appName = clientInfo.originator ?? clientInfo.name
        guard let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: detectedBundleIdentifier,
            appName: appName
        ), IDEExtensionInstaller.isInstalled(profile) else {
            return false
        }

        return await focusWithExtension(
            profile: profile,
            processIDs: [],
            tty: nil,
            sessionId: sessionId,
            clientInfo: clientInfo,
            workspacePath: workspacePath
        )
    }

    // ============================================================
    // kero 远程 session 直跳入口
    // ------------------------------------------------------------
    // session 是跨 host 唯一的精确匹配器：kero 侧按 AgentSession.ID
    // 级联激活窗口并解析 pane。agent 退出后 kero 会清空该会话的
    // AgentSession（"完成"会话的 session 级联必落空），此时 cwd
    // 是兜底凭据——kero 的 cwd 级联按 pane WorkDir 匹配且不限
    // host（远程 pane 的 WorkDir 与 payload 的 workspacePath 同
    // 源），仍可精确命中开着的 pane。tty 是远程主机上的设备路
    // 径，kero 侧 tty 级联仅扫本机 pane，故永不传。
    // ============================================================
    func focusKeroSession(sessionId: String?, cwd: String? = nil) async -> Bool {
        // ============================================================
        // 测试 hook：拦截真实 NSWorkspace.open，让单测能安全断言
        // SessionLauncher 各分支到 kero 跳转链的路由行为。
        // ============================================================
        if let handler = Self.focusKeroSessionHandlerForTesting {
            return await handler(sessionId, cwd)
        }

        guard let jumpURL = Self.keroJumpURL(
            sessionId: sessionId,
            tty: nil,
            cwd: cwd,
            isRemote: true
        ) else {
            logger.debug("No session id or cwd available for remote kero focus; skipping URL scheme jump")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus kero remote skip-no-credentials sessionId=\(sessionId ?? "nil") cwd=\(cwd ?? "nil")"
            )
            return false
        }

        let opened = await MainActor.run {
            NSWorkspace.shared.open(jumpURL)
        }
        logger.debug("Opened remote kero focus URL opened=\(opened, privacy: .public)")
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus kero remote url-scheme sessionId=\(sessionId ?? "nil") cwd=\(cwd ?? "nil") success=\(opened)"
        )
        return opened
    }

    private func focusWithExtension(
        profile: ManagedIDEExtensionProfile,
        processIDs: [Int],
        tty: String?,
        sessionId: String?,
        clientInfo: SessionClientInfo?,
        workspacePath: String?
    ) async -> Bool {
        var queryItems = processIDs
            .filter { $0 > 0 }
            .map { URLQueryItem(name: "pid", value: String($0)) }

        if let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionId))
        }

        if let normalizedTTY = tty?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: ""),
           !normalizedTTY.isEmpty {
            queryItems.append(URLQueryItem(name: "tty", value: normalizedTTY))
        }

        let resolvedWorkspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedWorkspacePath, !resolvedWorkspacePath.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: resolvedWorkspacePath))
        }

        if let processName = clientInfo?.processName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            queryItems.append(URLQueryItem(name: "processName", value: processName))
        }

        if let terminalSessionIdentifier = clientInfo?.terminalSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalSessionIdentifier.isEmpty {
            queryItems.append(URLQueryItem(name: "terminalSessionId", value: terminalSessionIdentifier))
        }

        if let iTermSessionIdentifier = clientInfo?.iTermSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !iTermSessionIdentifier.isEmpty {
            queryItems.append(URLQueryItem(name: "iTermSessionId", value: iTermSessionIdentifier))
        }

        guard !queryItems.isEmpty,
              let url = IDEExtensionInstaller.makeURI(
                profile: profile,
                path: "/focus",
                queryItems: queryItems
              ) else {
            return false
        }

        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func runAppleScript(lines: [String]) async -> Bool {
        guard let output = await runAppleScriptWithOutput(lines: lines) else {
            return false
        }
        return output == "ok"
    }

    private func runAppleScriptWithOutput(lines: [String]) async -> String? {
        let preview = lines.joined(separator: " | ")
        logger.debug("Running AppleScript: \(preview, privacy: .public)")
        await FocusDiagnosticsStore.shared.record("TerminalFocus applescript-run \(preview)")

        return await MainActor.run {
            let source = lines.joined(separator: "\n")
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                logger.error("Failed to create AppleScript object")
                Task {
                    await FocusDiagnosticsStore.shared.record("TerminalFocus applescript-create-failed")
                }
                return nil
            }

            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                logger.error("AppleScript failed: \(String(describing: errorInfo), privacy: .public)")
                Task {
                    await FocusDiagnosticsStore.shared.record(
                        "TerminalFocus applescript-error \(String(describing: errorInfo))"
                    )
                }
                return nil
            }

            let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.debug("AppleScript success result=\(output, privacy: .public)")
            Task {
                await FocusDiagnosticsStore.shared.record("TerminalFocus applescript-result \(output)")
            }
            return output
        }
    }

    func frontmostGhosttyTerminalSnapshot() async -> GhosttyTerminalSnapshot? {
        let frontmostBundleId = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        // cmux is based on Ghostty and uses the same AppleScript interface
        guard let frontmostBundleId else {
            return nil
        }
        let normalizedFrontmostBundleId = frontmostBundleId.lowercased()
        let isGhosttyFrontmost = normalizedFrontmostBundleId == "com.mitchellh.ghostty"
            || normalizedFrontmostBundleId == "com.cmuxterm.app"
        guard isGhosttyFrontmost else {
            return nil
        }

        guard let output = await runAppleScriptWithOutput(
            lines: Self.ghosttyFrontmostTerminalSnapshotScriptLines(bundleIdentifier: frontmostBundleId)
        ),
              output != "not-found" else {
            return nil
        }

        return Self.parseGhosttyTerminalSnapshot(output)
    }

    private func terminalScriptLines(for tty: String) -> [String] {
        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        let fullTTY = "/dev/\(normalizedTTY)"

        return [
            "set shortTTY to \"\(normalizedTTY)\"",
            "set fullTTY to \"\(fullTTY)\"",
            "tell application id \"com.apple.Terminal\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "set tabTTY to tty of theTab",
            "if tabTTY is shortTTY or tabTTY is fullTTY then",
            "set selected of theTab to true",
            "set frontmost of theWindow to true",
            "activate",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ]
    }

    private func focusITermSession(terminalPid: Int, selector: ITermScriptSelector) async -> Bool {
        let restoreResult = await runAppleScript(lines: iTermRestoreScriptLines(for: selector))
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus iterm restore-result terminalPid=\(terminalPid) success=\(restoreResult)"
        )
        guard restoreResult else {
            return false
        }

        let waitResult = await SessionLauncher.waitForIDEWindowActivation(
            bundleIdentifiers: ["com.googlecode.iterm2"],
            timeoutNanoseconds: iTermSelectionRetryDelayNanoseconds
        )
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus iterm wait-visible terminalPid=\(terminalPid) success=\(waitResult)"
        )

        let selectionLines = iTermSelectionScriptLines(for: selector)
        if await runAppleScript(lines: selectionLines) {
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus iterm select-result terminalPid=\(terminalPid) success=true attempt=1"
            )
            return true
        }

        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus iterm select-result terminalPid=\(terminalPid) success=false attempt=1"
        )
        try? await Task.sleep(nanoseconds: iTermSelectionRetryDelayNanoseconds)

        let retryResult = await runAppleScript(lines: selectionLines)
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus iterm select-result terminalPid=\(terminalPid) success=\(retryResult) attempt=2"
        )
        return retryResult
    }

    private func focusGhosttyTerminal(
        bundleIdentifier: String,
        terminalPid: Int,
        terminalSessionIdentifier: String?,
        workspacePath: String?,
        titleHint: String?
    ) async -> Bool {
        let result = await runAppleScript(lines: Self.ghosttySelectionScriptLines(
            terminalSessionIdentifier: Self.normalizedGhosttyTerminalIdentifier(terminalSessionIdentifier),
            workspacePath: workspacePath,
            titleHint: titleHint,
            bundleIdentifier: bundleIdentifier
        ))
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus ghostty select-result terminalPid=\(terminalPid) bundle=\(bundleIdentifier) success=\(result)"
        )
        return result
    }

    private struct ITermScriptSelector {
        let sessionIdentifier: String?
        let tty: String?
        let titleHint: String?
    }

    private nonisolated func iTermScriptSelector(
        for tty: String?,
        sessionIdentifier: String?,
        titleHint: String? = nil
    ) -> ITermScriptSelector? {
        let normalizedSessionIdentifier = normalizedITermSessionIdentifier(sessionIdentifier)
        let normalizedTTY = tty?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: "")
        let usableTTY = normalizedTTY?.isEmpty == false ? normalizedTTY : nil
        let usableSessionIdentifier = normalizedSessionIdentifier?.isEmpty == false
            ? normalizedSessionIdentifier
            : nil
        let usableTitleHint: String?
        if usableTTY == nil && usableSessionIdentifier == nil,
           let trimmedTitleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedTitleHint.isEmpty {
            usableTitleHint = trimmedTitleHint
        } else {
            usableTitleHint = nil
        }

        guard usableSessionIdentifier != nil || usableTTY != nil || usableTitleHint != nil else {
            return nil
        }

        return ITermScriptSelector(
            sessionIdentifier: usableSessionIdentifier,
            tty: usableTTY,
            titleHint: usableTitleHint
        )
    }

    private nonisolated func iTermRestoreScriptLines(for selector: ITermScriptSelector) -> [String] {
        if selector.tty == nil,
           selector.sessionIdentifier == nil,
           selector.titleHint?.isEmpty == false {
            return iTermUniqueTitleScriptLines(selector: selector, restoreWindowOnly: true)
        }

        var lines: [String] = [
            "tell application id \"com.googlecode.iterm2\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab"
        ]

        appendITermSelectorMatch(lines: &lines, selector: selector) {
            [
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "set miniaturized of resolvedWindow to false",
                "select resolvedWindow",
                "activate",
                "return \"ok\""
            ]
        }

        lines.append(contentsOf: [
            "end repeat",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ])

        return lines
    }

    private nonisolated func iTermSelectionScriptLines(for selector: ITermScriptSelector) -> [String] {
        if selector.tty == nil,
           selector.sessionIdentifier == nil,
           selector.titleHint?.isEmpty == false {
            return iTermUniqueTitleScriptLines(selector: selector, restoreWindowOnly: false)
        }

        var lines: [String] = [
            "tell application id \"com.googlecode.iterm2\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab"
        ]

        appendITermSelectorMatch(lines: &lines, selector: selector) {
            [
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "select theTab",
                "select theSession",
                "select resolvedWindow",
                "activate",
                "return \"ok\""
            ]
        }

        lines.append(contentsOf: [
            "end repeat",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ])

        return lines
    }

    private nonisolated func appendITermSelectorMatch(
        lines: inout [String],
        selector: ITermScriptSelector,
        body: () -> [String]
    ) {
        if let usableSessionIdentifier = selector.sessionIdentifier {
            lines.append(contentsOf: [
                "try",
                "if (id of theSession as text) is \"\(usableSessionIdentifier)\" then"
            ])
            lines.append(contentsOf: body())
            lines.append(contentsOf: [
                "end if",
                "end try"
            ])
        }

        if let usableTTY = selector.tty {
            let fullTTY = "/dev/\(usableTTY)"
            lines.append(contentsOf: [
                "set sessionTTY to tty of theSession",
                "if sessionTTY is \"\(usableTTY)\" or sessionTTY is \"\(fullTTY)\" then"
            ])
            lines.append(contentsOf: body())
            lines.append("end if")
        }
    }

    private nonisolated func iTermUniqueTitleScriptLines(
        selector: ITermScriptSelector,
        restoreWindowOnly: Bool
    ) -> [String] {
        guard let titleHint = selector.titleHint else {
            return []
        }

        let body: [String]
        if restoreWindowOnly {
            body = [
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "set miniaturized of resolvedWindow to false",
                "select resolvedWindow",
                "activate",
                "return \"ok\""
            ]
        } else {
            body = [
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "select theTab",
                "select theSession",
                "select resolvedWindow",
                "activate",
                "return \"ok\""
            ]
        }

        var lines: [String] = [
            "tell application id \"com.googlecode.iterm2\"",
            "set targetHint to \(Self.appleScriptStringLiteral(titleHint))",
            "set matchingSessionIDs to {}",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab",
            "try",
            "set sessionName to (name of theSession as text)",
            "if sessionName contains targetHint then",
            "copy (id of theSession as text) to end of matchingSessionIDs",
            "end if",
            "end try",
            "end repeat",
            "end repeat",
            "end repeat",
            "if (count of matchingSessionIDs) is not 1 then",
            "return \"not-found\"",
            "end if",
            "set targetSessionID to item 1 of matchingSessionIDs",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab",
            "try",
            "if (id of theSession as text) is targetSessionID then"
        ]

        lines.append(contentsOf: body)
        lines.append(contentsOf: [
            "end if",
            "end try",
            "end repeat",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ])

        return lines
    }

    static func iTermSelectionScriptLinesForTesting(tty: String?, sessionIdentifier: String?) -> [String] {
        let focuser = TerminalSessionFocuser.shared
        guard let selector = focuser.iTermScriptSelector(for: tty, sessionIdentifier: sessionIdentifier) else {
            return []
        }
        return focuser.iTermSelectionScriptLines(for: selector)
    }

    static func iTermSelectionScriptLinesForTesting(
        tty: String?,
        sessionIdentifier: String?,
        titleHint: String?
    ) -> [String] {
        let focuser = TerminalSessionFocuser.shared
        guard let selector = focuser.iTermScriptSelector(
            for: tty,
            sessionIdentifier: sessionIdentifier,
            titleHint: titleHint
        ) else {
            return []
        }
        return focuser.iTermSelectionScriptLines(for: selector)
    }

    static func ghosttySelectionScriptLines(
        terminalSessionIdentifier: String?,
        workspacePath: String?,
        titleHint: String? = nil,
        bundleIdentifier: String = "com.mitchellh.ghostty"
    ) -> [String] {
        var lines = [
            "tell application id \(appleScriptStringLiteral(bundleIdentifier))"
        ]

        if let terminalSessionIdentifier = normalizedGhosttyTerminalIdentifier(terminalSessionIdentifier) {
            lines.append(contentsOf: [
                "set targetTerminalID to \(appleScriptStringLiteral(terminalSessionIdentifier))",
                "try",
                "set targetTerminal to first terminal whose id is targetTerminalID",
                "focus targetTerminal",
                "return \"ok\"",
                "end try"
            ])
        }

        if let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspacePath.isEmpty {
            let projectName = URL(fileURLWithPath: workspacePath).lastPathComponent
            lines.append(contentsOf: [
                "set targetPath to \(appleScriptStringLiteral(workspacePath))",
                "set targetName to \(appleScriptStringLiteral(projectName))",
                "set exactMatches to every terminal whose working directory is targetPath",
                "if (count of exactMatches) is 1 then",
                "focus (item 1 of exactMatches)",
                "return \"ok\"",
                "end if",
                "set pathMatches to every terminal whose working directory contains targetPath",
                "if (count of pathMatches) is 1 then",
                "focus (item 1 of pathMatches)",
                "return \"ok\"",
                "end if",
                "if targetName is not \"\" then",
                "set nameMatches to every terminal whose name contains targetName",
                "if (count of nameMatches) is 1 then",
                "focus (item 1 of nameMatches)",
                "return \"ok\"",
                "end if",
                "end if"
            ])
        }

        if let titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !titleHint.isEmpty {
            lines.append(contentsOf: [
                "set remoteTitleHint to \(appleScriptStringLiteral(titleHint))",
                "set titleMatches to every terminal whose name contains remoteTitleHint",
                "if (count of titleMatches) is 1 then",
                "focus (item 1 of titleMatches)",
                "return \"ok\"",
                "end if"
            ])
        }

        lines.append(contentsOf: [
            "activate",
            "return \"ok\"",
            "end tell"
        ])

        return lines
    }

    static func ghosttyFrontmostTerminalSnapshotScriptLines(
        bundleIdentifier: String = "com.mitchellh.ghostty"
    ) -> [String] {
        [
            "tell application id \(appleScriptStringLiteral(bundleIdentifier))",
            "try",
            "set targetWindow to front window",
            "set targetTab to selected tab of targetWindow",
            "set targetTerminal to focused terminal of targetTab",
            "set targetTerminalID to (id of targetTerminal as text)",
            "set targetWorkingDirectory to \"\"",
            "try",
            "set targetWorkingDirectory to (working directory of targetTerminal as text)",
            "end try",
            "set targetTerminalName to \"\"",
            "try",
            "set targetTerminalName to (name of targetTerminal as text)",
            "end try",
            "return targetTerminalID & linefeed & targetWorkingDirectory & linefeed & targetTerminalName",
            "on error",
            "return \"not-found\"",
            "end try",
            "end tell"
        ]
    }

    static func parseGhosttyTerminalSnapshot(_ output: String) -> GhosttyTerminalSnapshot? {
        let lines = output.components(separatedBy: .newlines)
        guard let terminalSessionIdentifier = sanitizedNonEmpty(lines.first) else {
            return nil
        }

        let workingDirectory = lines.count > 1 ? sanitizedNonEmpty(lines[1]) : nil
        let title = lines.count > 2 ? sanitizedNonEmpty(lines[2]) : nil
        return GhosttyTerminalSnapshot(
            terminalSessionIdentifier: terminalSessionIdentifier,
            workingDirectory: workingDirectory,
            title: title
        )
    }

    static func normalizedGhosttyTerminalIdentifier(_ terminalSessionIdentifier: String?) -> String? {
        guard let trimmedIdentifier = terminalSessionIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmedIdentifier.isEmpty else {
            return nil
        }

        guard UUID(uuidString: trimmedIdentifier.uppercased()) != nil else {
            return nil
        }

        return trimmedIdentifier.uppercased()
    }

    // ============================================================
    // kero URL scheme 跳转协议（kero://focus）
    // ------------------------------------------------------------
    // kero（sh.kero / sh.kero.dev）注册了 kero://focus URL scheme，
    // 参数 session=<UUID>&tty=<tty>&cwd=<dir>；kero 侧 resolveJump
    // 按 session（跨 host 的 AgentSession.ID 精确匹配）→ tty（仅本
    // 机 pane 精确匹配）→ cwd 级联解析目标 pane。这里只负责构造
    // URL 并经 NSWorkspace.open 交给系统路由，不做任何 pane 匹配。
    // 注意：tty 必须原样透传（kero pane.TTY 即含 /dev/ 前缀的完整
    // 路径），与 IDE extension 分支剥 /dev/ 前缀的做法相反。
    // ============================================================

    /// kero 正式版与 dev 构建的 bundle id 双变体判定
    static func keroIsHandledBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "sh.kero" || bundleIdentifier == "sh.kero.dev"
    }

    /// 测试专用 hook：非 nil 时 focusKeroSession 不再真实 open URL
    /// （参数按 (sessionId, cwd) 透传，供断言远程跳转补发 cwd 兜底）
    static var focusKeroSessionHandlerForTesting: (@Sendable (String?, String?) async -> Bool)?

    /// 构造 kero://focus 跳转 URL：
    /// - 空参数（nil / 空白）省略对应 query 项，三参全空返回 nil
    /// - isRemote == true 时丢弃 tty（远程 tty 是远程主机上的设备
    ///   路径，kero 侧 tty 级联仅扫本机 pane），保留 session 与
    ///   cwd：cwd 与 kero pane 的 WorkDir 同源，cwd 级联不限
    ///   host，是 agent 退出后完成会话的兜底凭据
    /// - query 值由 URLComponents 自动 percent-encode（kero 侧 Go
    ///   url.Query().Get 自动解码还原）
    static func keroJumpURL(
        sessionId: String?,
        tty: String?,
        cwd: String?,
        isRemote: Bool
    ) -> URL? {
        var queryItems: [URLQueryItem] = []

        if let session = sanitizedNonEmpty(sessionId) {
            queryItems.append(URLQueryItem(name: "session", value: session))
        }
        if !isRemote {
            if let ttyValue = sanitizedNonEmpty(tty) {
                queryItems.append(URLQueryItem(name: "tty", value: ttyValue))
            }
        }
        if let cwdValue = sanitizedNonEmpty(cwd) {
            queryItems.append(URLQueryItem(name: "cwd", value: cwdValue))
        }

        guard !queryItems.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "kero"
        components.host = "focus"
        components.queryItems = queryItems
        return components.url
    }

    // ============================================================
    // WezTerm 家族（WezTerm / Kaku）CLI 跳转通道
    // ------------------------------------------------------------
    // wezterm cli list --format json → 三级匹配（pane_id > tty >
    // cwd 标准化）→ wezterm cli activate-pane --pane-id <id>。
    // Kaku（fun.tw93.kaku）是 WezTerm fork，复用同一 CLI 协议，
    // 仅二进制名不同（kaku vs wezterm）。
    // ============================================================

    /// `wezterm cli list --format json` 单条 pane 记录（字段与
    /// wezterm 源码 PaneInformation 的 JSON 序列化对齐）
    struct WeztermFamilyPane: Decodable {
        let windowID: Int
        let tabID: Int
        let paneID: Int
        let title: String
        let cwd: String
        let ttyName: String?
        let isActive: Bool

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case tabID = "tab_id"
            case paneID = "pane_id"
            case title
            case cwd
            case ttyName = "tty_name"
            case isActive = "is_active"
        }
    }

    /// bundle id → (CLI 二进制名, App 显示名) 映射；非家族成员返回 nil
    static func weztermFamilyCLIDetails(for bundleIdentifier: String) -> (cliName: String, appName: String)? {
        switch bundleIdentifier {
        case "fun.tw93.kaku":
            return (cliName: "kaku", appName: "Kaku")
        case "com.github.wez.wezterm":
            return (cliName: "wezterm", appName: "WezTerm")
        default:
            return nil
        }
    }

    /// `cli list` 参数（固定 JSON 输出格式）
    static func weztermFamilyListArguments() -> [String] {
        ["cli", "list", "--format", "json"]
    }

    /// `cli activate-pane` 参数（--pane-id 定位目标 pane）
    static func weztermFamilyActivatePaneArguments(paneID: Int) -> [String] {
        ["cli", "activate-pane", "--pane-id", "\(paneID)"]
    }

    /// 剥除 cwd 的 file:// scheme 与 percent-encoding（wezterm 以
    /// file URL 形式上报工作目录）
    static func weztermFamilyNormalizeCWD(_ cwd: String) -> String {
        if cwd.hasPrefix("file://"), let url = URL(string: cwd) {
            return url.path
        }
        return cwd
    }

    /// 三级匹配目标 pane：pane_id（sessionIdentifier 数字解析）>
    /// tty 精确（/dev/ 前缀原样，禁止剥前缀）> cwd 标准化路径；
    /// 无命中返回 nil
    static func weztermFamilyMatchedPaneID(
        panes: [WeztermFamilyPane],
        sessionIdentifier: String?,
        tty: String?,
        workspacePath: String?
    ) -> Int? {
        // 一级：pane_id 精确命中（WEZTERM_PANE 即 pane id；非数字
        // 值视同缺失，落下一级）
        if let rawID = sanitizedNonEmpty(sessionIdentifier),
           let paneID = Int(rawID),
           panes.contains(where: { $0.paneID == paneID }) {
            return paneID
        }

        // 二级：tty 精确匹配
        if let targetTTY = sanitizedNonEmpty(tty),
           let matched = panes.first(where: { $0.ttyName == targetTTY }) {
            return matched.paneID
        }

        // 三级：cwd 标准化路径匹配（尾斜杠 / 相对段归一）
        if let targetCWD = sanitizedNonEmpty(workspacePath) {
            let normalizedTarget = URL(fileURLWithPath: targetCWD).standardizedFileURL.path
            if let matched = panes.first(where: {
                URL(fileURLWithPath: weztermFamilyNormalizeCWD($0.cwd)).standardizedFileURL.path == normalizedTarget
            }) {
                return matched.paneID
            }
        }

        return nil
    }

    // ============================================================
    // CLI 执行原语（actor 内同步执行，与 runAppleScript 的
    // NSAppleScript 同步执行模式一致；CLI 均为短生命周期命令）
    // ============================================================

    /// 定位 WezTerm 家族 CLI：先查 .app bundle 内嵌 CLI 的常规
    /// 安装路径（最可靠），再经 /usr/bin/which 沿 PATH 兜底
    private func weztermFamilyCLIPath(for bundleIdentifier: String) -> String? {
        guard let details = Self.weztermFamilyCLIDetails(for: bundleIdentifier) else {
            return nil
        }

        let bundleCandidates = [
            "/Applications/\(details.appName).app/Contents/MacOS/\(details.cliName)",
            NSHomeDirectory() + "/Applications/\(details.appName).app/Contents/MacOS/\(details.cliName)"
        ]
        if let found = bundleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = [details.cliName]
        let pipe = Pipe()
        whichTask.standardOutput = pipe
        whichTask.standardError = FileHandle.nullDevice
        guard (try? whichTask.run()) != nil else {
            return nil
        }
        whichTask.waitUntilExit()
        guard whichTask.terminationStatus == 0 else {
            return nil
        }
        let path = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// 执行 `cli list --format json` 并解码 pane 列表；CLI 不可达
    /// 或输出非法时返回 nil
    private func weztermFamilyListPanes(cliPath: String) -> [WeztermFamilyPane]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = Self.weztermFamilyListArguments()
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode([WeztermFamilyPane].self, from: data)
    }

    /// 执行 `cli activate-pane --pane-id <id>`；退出码 0 即成功
    private func weztermFamilyActivatePane(cliPath: String, paneID: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = Self.weztermFamilyActivatePaneArguments(paneID: paneID)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// WezTerm 家族跳转编排：先激活应用本身（与既有终端分支一
    /// 致；CLI 通道失配时至少完成窗口级激活），再 list → 三级匹
    /// 配 → activate-pane 精确落点
    private func focusWeztermFamilyTerminal(
        bundleIdentifier: String,
        terminalPid: Int,
        sessionIdentifier: String?,
        tty: String?,
        workspacePath: String?
    ) async -> Bool {
        let activated = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
                return false
            }
            if app.isHidden {
                app.unhide()
            }
            return app.activate(options: [])
        }

        guard let cliPath = weztermFamilyCLIPath(for: bundleIdentifier) else {
            logger.debug("No WezTerm-family CLI found for bundle \(bundleIdentifier, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus wezterm skip-no-cli bundle=\(bundleIdentifier) terminalPid=\(terminalPid) activated=\(activated)"
            )
            return false
        }

        guard let panes = weztermFamilyListPanes(cliPath: cliPath) else {
            logger.debug("WezTerm-family CLI list failed bundle \(bundleIdentifier, privacy: .public) cli=\(cliPath, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus wezterm cli-list-failed bundle=\(bundleIdentifier) terminalPid=\(terminalPid) activated=\(activated)"
            )
            return false
        }

        guard let paneID = Self.weztermFamilyMatchedPaneID(
            panes: panes,
            sessionIdentifier: sessionIdentifier,
            tty: tty,
            workspacePath: workspacePath
        ) else {
            logger.debug("No matching WezTerm-family pane bundle \(bundleIdentifier, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus wezterm no-pane-match bundle=\(bundleIdentifier) terminalPid=\(terminalPid) activated=\(activated)"
            )
            return false
        }

        let jumped = weztermFamilyActivatePane(cliPath: cliPath, paneID: paneID)
        logger.debug("WezTerm-family activate-pane paneID=\(paneID, privacy: .public) success=\(jumped, privacy: .public)")
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus wezterm cli-jump bundle=\(bundleIdentifier) terminalPid=\(terminalPid) paneID=\(paneID) activated=\(activated) success=\(jumped)"
        )
        return jumped
    }

    // ============================================================
    // Warp 精确跳转通道（N2b）
    // ------------------------------------------------------------
    // 激活 Warp → frontmost 轮询 → fast path 焦点 UUID 比对 →
    // AX 点击菜单 "Tab ▸ Switch to Next Tab" 循环推进（每步重读
    // 焦点，命中即停）。参照 open-vibe-island 实证结论：合成键事件
    // 被 Warp 的 HID 过滤（NSBeep）、System Events keystroke 仅
    // 首次授权后成功一次，AX 菜单点击是唯一可靠推进路径。
    // ============================================================

    /// frontmost 轮询上限 / 间隔；tab 推进后 SQLite 落盘等待。
    /// （open-vibe-island 真机调优值，static let 本身即测试靶）
    static let warpFrontmostMaxWait: TimeInterval = 1.5
    static let warpFrontmostPollInterval: TimeInterval = 0.025
    static let warpTabCycleSettleDelay: TimeInterval = 0.1

    /// 单步 tab 推进的决策结果
    enum WarpCycleStep: Equatable {
        case done      // 焦点已命中目标 pane
        case advance   // 未命中且未达上限，继续推进
        case giveUp    // 未命中且已达上限，放弃（激活已达，精度未确认）
    }

    /// AX 点击 "Tab ▸ Switch to Next Tab" 的 AppleScript 行。
    ///
    /// 先 `activate` 确保 Warp 前置（AppleScript 通道自带激活，
    /// 与外层 NSRunningApplication.activate 双保险），`delay 0.08`
    /// 等待 WindowServer 前后台切换完成，再经 System Events 的
    /// Accessibility 通道点击菜单项——菜单动作直接派发，不受 key
    /// window / first responder / TUI 抢占影响。
    static func warpTabAdvanceScriptLines() -> [String] {
        [
            "tell application id \"dev.warp.Warp-Stable\" to activate",
            "delay 0.08",
            "tell application \"System Events\"",
            "    tell process \"Warp\"",
            "        click menu item \"Switch to Next Tab\" of menu \"Tab\" of menu bar item \"Tab\" of menu bar 1",
            "    end tell",
            "end tell",
        ]
    }

    /// frontmost 判定（纯函数；生产侧传入 NSWorkspace 观测值）
    static func warpIsFrontmostBundleIdentifier(_ frontmostBundleIdentifier: String?) -> Bool {
        frontmostBundleIdentifier == "dev.warp.Warp-Stable"
    }

    /// AX 循环推进上限 = max(1, tabCount) + 2：到达任意 tab 最多
    /// 需 tabCount-1 步，+2 为计数毛刺与 active_tab_index 瞬态
    /// 过期的安全余量；tabCount 读取失败（0）按单 tab 兜底。
    static func warpMaxTabAttempts(tabCount: Int) -> Int {
        max(1, tabCount) + 2
    }

    /// 焦点 pane UUID 比对（fast path 与循环内共用）。焦点不可读
    /// （DB 缺失 / 无活动窗口）视同不匹配。
    static func warpPaneMatches(focusedPaneUUID: String?, targetPaneUUID: String) -> Bool {
        guard let focusedPaneUUID else { return false }
        return focusedPaneUUID.caseInsensitiveCompare(targetPaneUUID) == .orderedSame
    }

    /// 单步循环决策：命中 → done；未命中且 attempt 已达上限 →
    /// giveUp；否则 advance。
    static func warpCycleDecision(
        focusedPaneUUID: String?,
        targetPaneUUID: String,
        attempt: Int,
        maxAttempts: Int
    ) -> WarpCycleStep {
        if warpPaneMatches(focusedPaneUUID: focusedPaneUUID, targetPaneUUID: targetPaneUUID) {
            return .done
        }
        return attempt >= maxAttempts ? .giveUp : .advance
    }

    /// Warp 跳转组装（IO 全集中于此薄层；决策逻辑全在上方纯函数）。
    ///
    /// 流程：激活 → 无 pane 映射早退（激活即完成）→ frontmost
    /// 轮询 → fast path 比对 → AX 循环推进。SQLite 读 / AX 交互 /
    /// frontmost 观测均经可选闭包注入（默认走 WarpFocusStore /
    /// AppleScript / NSWorkspace 生产实现），测试与上层可注假。
    ///
    /// 返回语义与 WezTerm 家族一致：精度未达成返回 false（上层
    /// fallback 激活的仍是 Warp 本身，幂等无害）；仅"激活成功但
    /// 无 pane 映射"返回 true（此时已无事可做）。
    private func focusWarpTerminal(
        terminalPid: Int,
        targetPaneUUID: String?,
        bundleIdentifier: String,
        focusedPaneReader: (() -> String?)? = nil,
        tabCountReader: (() -> Int)? = nil,
        tabAdvancer: (() async -> Bool)? = nil,
        frontmostChecker: (() async -> Bool)? = nil
    ) async -> Bool {
        // 0. 激活 Warp（kero / WezTerm 分支同款 NSRunningApplication 通道）
        let activated = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
                return false
            }
            if app.isHidden {
                app.unhide()
            }
            return app.activate(options: [])
        }
        guard activated else {
            logger.debug("Failed to activate Warp terminalPid=\(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus warp activate-failed bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
            )
            return false
        }

        // 无 pane 映射（bridge 侧解析失败 / 无 Warp 集成）：激活即完成
        guard let targetPaneUUID = Self.sanitizedNonEmpty(targetPaneUUID) else {
            logger.debug("No Warp pane mapping; activated only terminalPid=\(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus warp activate-only bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
            )
            return true
        }

        // 注入点落地：默认实现绑生产数据源，测试可整体替换
        let readFocusedPaneUUID = focusedPaneReader ?? { WarpFocusStore().currentFocusedPaneUUID() }
        let readTabCount = tabCountReader ?? { WarpFocusStore().tabCountInActiveWindow() }
        let advanceTab = tabAdvancer ?? {
            await self.runAppleScriptWithOutput(lines: Self.warpTabAdvanceScriptLines()) != nil
        }
        let checkFrontmost = frontmostChecker ?? {
            await MainActor.run {
                Self.warpIsFrontmostBundleIdentifier(
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                )
            }
        }

        // DB 缺失 / 无活动窗口：tab 数读不出即无循环意义，静默降级
        // （此时 Warp 已激活，false 触发的上层 fallback 激活仍为
        // Warp 本身，幂等无害）
        let tabCount = readTabCount()
        guard tabCount > 0 else {
            logger.debug("Warp DB unavailable or no tabs; skipping AX cycling terminalPid=\(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus warp no-db-or-no-tabs bundle=\(bundleIdentifier) terminalPid=\(terminalPid) pane=\(targetPaneUUID)"
            )
            return false
        }

        // 1. frontmost 轮询：activate 的 WindowServer 激活是异步的
        //    （50-300ms 量级），AX 点击必须等 Warp 真正前置才可靠
        let frontmostStart = Date()
        while !(await checkFrontmost()) {
            if Date().timeIntervalSince(frontmostStart) >= Self.warpFrontmostMaxWait {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.warpFrontmostPollInterval * 1_000_000_000))
        }

        // 2. fast path：已聚焦目标 pane → 零按键完成
        if Self.warpPaneMatches(
            focusedPaneUUID: readFocusedPaneUUID(),
            targetPaneUUID: targetPaneUUID
        ) {
            await FocusDiagnosticsStore.shared.record(
                "TerminalFocus warp fast-path bundle=\(bundleIdentifier) terminalPid=\(terminalPid) pane=\(targetPaneUUID)"
            )
            return true
        }

        // 3. AX 循环推进：每步点击后等 SQLite 落盘再重读焦点
        let maxAttempts = Self.warpMaxTabAttempts(tabCount: tabCount)
        for attempt in 1...maxAttempts {
            guard await advanceTab() else {
                // AX 不可用（辅助功能权限缺失 / 菜单更名）：静默降级，
                // 记诊断后交还上层（激活已达）
                logger.debug("Warp tab advance failed attempt=\(attempt, privacy: .public)")
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus warp advance-failed bundle=\(bundleIdentifier) terminalPid=\(terminalPid) attempt=\(attempt)"
                )
                return false
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.warpTabCycleSettleDelay * 1_000_000_000))

            switch Self.warpCycleDecision(
                focusedPaneUUID: readFocusedPaneUUID(),
                targetPaneUUID: targetPaneUUID,
                attempt: attempt,
                maxAttempts: maxAttempts
            ) {
            case .done:
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus warp cycled-to-target bundle=\(bundleIdentifier) terminalPid=\(terminalPid) attempts=\(attempt) pane=\(targetPaneUUID)"
                )
                return true
            case .advance:
                continue
            case .giveUp:
                await FocusDiagnosticsStore.shared.record(
                    "TerminalFocus warp unconfirmed bundle=\(bundleIdentifier) terminalPid=\(terminalPid) attempts=\(attempt) pane=\(targetPaneUUID)"
                )
                return false
            }
        }

        // 理论不可达（giveUp 在循环内必触发）；防御性收尾
        await FocusDiagnosticsStore.shared.record(
            "TerminalFocus warp unconfirmed bundle=\(bundleIdentifier) terminalPid=\(terminalPid) pane=\(targetPaneUUID)"
        )
        return false
    }

    static func ghosttyWorkingDirectoryMatches(
        snapshotWorkingDirectory: String?,
        workspacePath: String?
    ) -> Bool {
        guard let normalizedSnapshot = normalizedComparablePath(snapshotWorkingDirectory),
              let normalizedWorkspace = normalizedComparablePath(workspacePath) else {
            return false
        }

        if normalizedSnapshot == normalizedWorkspace {
            return true
        }

        return normalizedSnapshot.hasPrefix(normalizedWorkspace + "/")
            || normalizedWorkspace.hasPrefix(normalizedSnapshot + "/")
    }

    private static func normalizedComparablePath(_ value: String?) -> String? {
        guard let trimmed = sanitizedNonEmpty(value) else {
            return nil
        }

        let standardized = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
        return NSString(string: standardized).standardizingPath.lowercased()
    }

    private static func sanitizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated func normalizedITermSessionIdentifier(_ sessionIdentifier: String?) -> String? {
        guard let rawValue = sessionIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return nil
        }

        if let suffix = rawValue.split(separator: ":", omittingEmptySubsequences: false).last,
           !suffix.isEmpty {
            return String(suffix)
        }

        return rawValue
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
