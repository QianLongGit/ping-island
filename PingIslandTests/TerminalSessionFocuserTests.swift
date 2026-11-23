import XCTest
@testable import Ping_Island

final class TerminalSessionFocuserTests: XCTestCase {
    func testITermSelectionScriptUsesSessionIdentifierAlongsideTTY() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: "ttys194",
            sessionIdentifier: "w6t0p0:AF9E91C7-A845-4A30-8A18-54C51B61B1B4"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set sessionTTY to tty of theSession"))
        XCTAssertTrue(script.contains("ttys194"))
        XCTAssertTrue(script.contains("AF9E91C7-A845-4A30-8A18-54C51B61B1B4"))
        XCTAssertLessThan(
            script.range(of: "AF9E91C7-A845-4A30-8A18-54C51B61B1B4")!.lowerBound,
            script.range(of: "set sessionTTY to tty of theSession")!.lowerBound
        )
    }

    func testITermSelectionScriptFallsBackToSessionIdentifierWhenTTYMissing() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: nil,
            sessionIdentifier: "w6t0p0:AF9E91C7-A845-4A30-8A18-54C51B61B1B4"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("set sessionTTY to tty of theSession"))
        XCTAssertTrue(script.contains("AF9E91C7-A845-4A30-8A18-54C51B61B1B4"))
    }

    func testITermSelectionScriptCanUniquelyMatchRemoteHostTitleHint() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: nil,
            sessionIdentifier: nil,
            titleHint: "devbox"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetHint to \"devbox\""))
        XCTAssertTrue(script.contains("set matchingSessionIDs to {}"))
        XCTAssertTrue(script.contains("if (count of matchingSessionIDs) is not 1 then"))
    }

    func testGhosttySelectionScriptOnlyUsesUnambiguousWorkspaceMatches() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("if (count of exactMatches) is 1 then"))
        XCTAssertTrue(script.contains("if (count of pathMatches) is 1 then"))
        XCTAssertTrue(script.contains("if (count of nameMatches) is 1 then"))
    }

    func testGhosttySelectionScriptFallsBackToRemoteHostTitleHint() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: nil,
            titleHint: "devbox"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set remoteTitleHint to \"devbox\""))
        XCTAssertTrue(script.contains("set titleMatches to every terminal whose name contains remoteTitleHint"))
    }

    func testGhosttySelectionScriptCanTargetCmuxBundle() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            workspacePath: "/tmp/demo",
            bundleIdentifier: "com.cmuxterm.app"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertEqual(lines.first, "tell application id \"com.cmuxterm.app\"")
        XCTAssertFalse(script.contains("tell application id \"com.mitchellh.ghostty\""))
    }

    func testGhosttyFrontmostTerminalSnapshotScriptTargetsFocusedTerminal() {
        let lines = TerminalSessionFocuser.ghosttyFrontmostTerminalSnapshotScriptLines()
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetWindow to front window"))
        XCTAssertTrue(script.contains("set targetTab to selected tab of targetWindow"))
        XCTAssertTrue(script.contains("set targetTerminal to focused terminal of targetTab"))
        XCTAssertTrue(script.contains("return targetTerminalID & linefeed & targetWorkingDirectory & linefeed & targetTerminalName"))
    }

    func testGhosttyFrontmostTerminalSnapshotScriptCanTargetCmuxBundle() {
        let lines = TerminalSessionFocuser.ghosttyFrontmostTerminalSnapshotScriptLines(
            bundleIdentifier: "com.cmuxterm.app"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertEqual(lines.first, "tell application id \"com.cmuxterm.app\"")
        XCTAssertTrue(script.contains("set targetTerminal to focused terminal of targetTab"))
        XCTAssertFalse(script.contains("tell application id \"com.mitchellh.ghostty\""))
    }

    func testParseGhosttyTerminalSnapshotReadsIdentifierWorkingDirectoryAndTitle() {
        let snapshot = TerminalSessionFocuser.parseGhosttyTerminalSnapshot(
            "ABC-123\n/Users/example/project\nclaude session"
        )

        XCTAssertEqual(
            snapshot,
            TerminalSessionFocuser.GhosttyTerminalSnapshot(
                terminalSessionIdentifier: "ABC-123",
                workingDirectory: "/Users/example/project",
                title: "claude session"
            )
        )
    }

    func testGhosttyWorkingDirectoryMatchesStandardizedPathsAndSubdirectories() {
        XCTAssertTrue(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/project/subdir",
                workspacePath: "/Users/example/project"
            )
        )
        XCTAssertTrue(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/project/../project",
                workspacePath: "/Users/example/project"
            )
        )
        XCTAssertFalse(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/other",
                workspacePath: "/Users/example/project"
            )
        )
    }

    func testNormalizedGhosttyTerminalIdentifierAcceptsUUIDAndUppercasesIt() {
        XCTAssertEqual(
            TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(
                "65a2028f-a93c-48e0-b46a-3f4c20c94b81"
            ),
            "65A2028F-A93C-48E0-B46A-3F4C20C94B81"
        )
    }

    func testNormalizedGhosttyTerminalIdentifierRejectsGenericTermSessionID() {
        XCTAssertNil(
            TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier("ghostty-terminal-1")
        )
    }

    // ============================================================
    // kero://focus URL 构造与 bundle id 判定
    // ------------------------------------------------------------
    // 断言字符串按 URLComponents 在构建机（macOS 26.5）的实际
    // percent-encode 输出写死："/" 在 query 值中保持原样（RFC
    // 3986 允许，kero 侧 Go url.Query().Get 原样还原），空格与
    // 非 ASCII 按 %XX 编码。
    // ============================================================

    func testKeroJumpURLEncodesSessionTTYAndCWD() {
        let url = TerminalSessionFocuser.keroJumpURL(
            sessionId: "abc-uuid",
            tty: "/dev/ttys012",
            cwd: "/Users/example/我的 项目",
            isRemote: false
        )

        XCTAssertEqual(
            url?.absoluteString,
            "kero://focus?session=abc-uuid&tty=/dev/ttys012&cwd=/Users/example/%E6%88%91%E7%9A%84%20%E9%A1%B9%E7%9B%AE"
        )
        // /dev/ 前缀必须原样透传（kero pane.TTY 即完整路径格式，禁止剥前缀）
        XCTAssertTrue(url!.absoluteString.contains("tty=/dev/ttys012"))
    }

    func testKeroJumpURLRemoteCarriesSessionAndCWDButDropsTTY() {
        let url = TerminalSessionFocuser.keroJumpURL(
            sessionId: "abc-uuid",
            tty: "/dev/ttys012",
            cwd: "/Users/example/proj",
            isRemote: true
        )

        // ============================================================
        // 远程跳转参数语义（与 kero resolveJump 级联逐级对齐）：
        // - tty 是远程主机上的设备路径，kero 侧 tty 级联仅扫本机
        //   pane → 必须丢弃；
        // - cwd 与 kero pane 的 WorkDir 同源（远程会话的
        //   workspacePath 即远程 pane 工作目录），cwd 级联不限
        //   host——agent 退出后 kero 清空 AgentSession，完成会话
        //   的 session 级联必落空，cwd 是唯一兜底凭据 → 必须保留。
        // ============================================================
        XCTAssertEqual(
            url?.absoluteString,
            "kero://focus?session=abc-uuid&cwd=/Users/example/proj"
        )
        XCTAssertFalse(url!.absoluteString.contains("tty="))
    }

    func testKeroJumpURLRemoteWithoutSessionOrCWDReturnsNil() {
        // 远程且 session/cwd 全空：tty 即使有值也不构成凭据 → nil
        XCTAssertNil(
            TerminalSessionFocuser.keroJumpURL(
                sessionId: nil,
                tty: "/dev/ttys012",
                cwd: nil,
                isRemote: true
            )
        )
        // 空白字符串视同缺失，session/cwd 全空仍返回 nil
        XCTAssertNil(
            TerminalSessionFocuser.keroJumpURL(
                sessionId: "   ",
                tty: nil,
                cwd: "",
                isRemote: true
            )
        )
    }

    func testKeroJumpURLReturnsNilWhenAllParamsMissing() {
        XCTAssertNil(
            TerminalSessionFocuser.keroJumpURL(sessionId: nil, tty: nil, cwd: nil, isRemote: false)
        )
        // 空白字符串视同缺失，全部省略后返回 nil
        XCTAssertNil(
            TerminalSessionFocuser.keroJumpURL(sessionId: "   ", tty: "", cwd: nil, isRemote: false)
        )
    }

    func testKeroIsHandledBundleIdentifierMatchesBothVariants() {
        XCTAssertTrue(TerminalSessionFocuser.keroIsHandledBundleIdentifier("sh.kero"))
        XCTAssertTrue(TerminalSessionFocuser.keroIsHandledBundleIdentifier("sh.kero.dev"))
        XCTAssertFalse(TerminalSessionFocuser.keroIsHandledBundleIdentifier("com.mitchellh.ghostty"))
        XCTAssertFalse(TerminalSessionFocuser.keroIsHandledBundleIdentifier(""))
        XCTAssertFalse(TerminalSessionFocuser.keroIsHandledBundleIdentifier(nil))
    }

    // ============================================================
    // WezTerm 家族（WezTerm / Kaku）CLI 跳转
    // ------------------------------------------------------------
    // 通道：cli list --format json → 三级匹配（pane_id > tty >
    // cwd 标准化）→ cli activate-pane --pane-id <id>。
    // 断言面全部为纯函数（参数构造 / 匹配优先级 / cwd 归一），
    // 不依赖真 WezTerm/Kaku 安装。
    // ============================================================

    func testWeztermFamilyCLIDetailsMapKakuAndWezTermBundles() {
        // bundle id → (CLI 二进制名, App 名) 映射是 CLI 通道的寻址基础
        let kaku = TerminalSessionFocuser.weztermFamilyCLIDetails(for: "fun.tw93.kaku")
        XCTAssertEqual(kaku?.cliName, "kaku")
        XCTAssertEqual(kaku?.appName, "Kaku")

        let wezterm = TerminalSessionFocuser.weztermFamilyCLIDetails(for: "com.github.wez.wezterm")
        XCTAssertEqual(wezterm?.cliName, "wezterm")
        XCTAssertEqual(wezterm?.appName, "WezTerm")

        // 非 WezTerm 家族 bundle 不进入本通道
        XCTAssertNil(TerminalSessionFocuser.weztermFamilyCLIDetails(for: "com.apple.Terminal"))
        XCTAssertNil(TerminalSessionFocuser.weztermFamilyCLIDetails(for: "sh.kero"))
    }

    func testWeztermFamilyCLIArguments() {
        // list 固定 JSON 输出格式；activate-pane 以 pane-id 定位
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyListArguments(),
            ["cli", "list", "--format", "json"]
        )
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyActivatePaneArguments(paneID: 7),
            ["cli", "activate-pane", "--pane-id", "7"]
        )
    }

    func testWeztermFamilyPaneDecodesCLIJSONFields() throws {
        // wezterm cli list --format json 的真实字段形态（snake_case）
        let json = """
        [
          {
            "window_id": 0,
            "tab_id": 1,
            "pane_id": 5,
            "title": "claude session",
            "cwd": "file:///Users/example/project",
            "tty_name": "/dev/ttys012",
            "is_active": true
          }
        ]
        """.data(using: .utf8)!

        let panes = try JSONDecoder().decode([TerminalSessionFocuser.WeztermFamilyPane].self, from: json)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].paneID, 5)
        XCTAssertEqual(panes[0].ttyName, "/dev/ttys012")
        XCTAssertEqual(panes[0].cwd, "file:///Users/example/project")
        XCTAssertEqual(panes[0].title, "claude session")
        XCTAssertTrue(panes[0].isActive)
    }

    func testWeztermFamilyMatchedPaneIDPrioritizesSessionOverTTYOverCWD() {
        let panes = [
            TerminalSessionFocuser.WeztermFamilyPane(
                windowID: 0, tabID: 0, paneID: 1,
                title: "other", cwd: "/Users/example/other",
                ttyName: "/dev/ttys099", isActive: false
            ),
            TerminalSessionFocuser.WeztermFamilyPane(
                windowID: 0, tabID: 0, paneID: 2,
                title: "tty hit", cwd: "/Users/example/other",
                ttyName: "/dev/ttys012", isActive: false
            ),
            TerminalSessionFocuser.WeztermFamilyPane(
                windowID: 0, tabID: 0, paneID: 3,
                title: "cwd hit", cwd: "file:///Users/example/project",
                ttyName: nil, isActive: true
            )
        ]

        // 一级：WEZTERM_PANE 精确命中（sessionIdentifier 即 pane_id）
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: "3", tty: "/dev/ttys012",
                workspacePath: "/Users/example/other"
            ),
            3
        )
        // 非数字 sessionIdentifier 视同缺失，落入 tty 级
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: "not-a-pane", tty: "/dev/ttys012",
                workspacePath: nil
            ),
            2
        )
        // 二级：tty 精确匹配（/dev/ 前缀原样，禁止剥前缀）
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: nil, tty: "/dev/ttys012",
                workspacePath: nil
            ),
            2
        )
        // 三级：cwd 标准化匹配（file:// 剥壳 + 尾斜杠归一）
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: nil, tty: nil,
                workspacePath: "/Users/example/project/"
            ),
            3
        )
    }

    func testWeztermFamilyNormalizeCWDStripsFileScheme() {
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyNormalizeCWD("file:///Users/example/project"),
            "/Users/example/project"
        )
        // 普通路径直通（wezterm 亦可能输出裸路径）
        XCTAssertEqual(
            TerminalSessionFocuser.weztermFamilyNormalizeCWD("/Users/example/project"),
            "/Users/example/project"
        )
    }

    func testWeztermFamilyMatchedPaneIDReturnsNilWithoutCredentialsOrMatch() {
        let panes = [
            TerminalSessionFocuser.WeztermFamilyPane(
                windowID: 0, tabID: 0, paneID: 1,
                title: "other", cwd: "/Users/example/other",
                ttyName: "/dev/ttys099", isActive: true
            )
        ]
        // 三级凭据全空 → 无从匹配（退化：focuser 返回 false）
        XCTAssertNil(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: nil, tty: nil, workspacePath: nil
            )
        )
        // 凭据存在但全部不命中 → 同样 nil
        XCTAssertNil(
            TerminalSessionFocuser.weztermFamilyMatchedPaneID(
                panes: panes, sessionIdentifier: "42", tty: "/dev/ttys777",
                workspacePath: "/no/such/dir"
            )
        )
    }

    // ============================================================
    // Warp 精确跳转（N2b）：AX 菜单点击是唯一实证可靠的 tab 推进
    // 路径（CGEventPost 被 Warp HID 过滤 NSBeep、System Events
    // keystroke 不可靠），参照 open-vibe-island 实现逐项锁定。
    // ============================================================

    func testWarpTabAdvanceScriptClicksNextTabMenuItemViaSystemEvents() {
        // joined 子串断言（与 iTerm/ghostty string-assert 模式一致，
        // 不受 AppleScript 行缩进影响）
        let script = TerminalSessionFocuser.warpTabAdvanceScriptLines()
            .joined(separator: "\n")

        // 激活 Warp（AppleScript 通道，bundle id 为真机注册形态）
        XCTAssertTrue(script.contains("tell application id \"dev.warp.Warp-Stable\" to activate"))
        // 激活后等待 WindowServer 前后台切换完成再点击
        XCTAssertTrue(script.contains("delay 0.08"))
        // 经 System Events 的 Accessibility 通道点击菜单项
        XCTAssertTrue(script.contains("tell application \"System Events\""))
        XCTAssertTrue(script.contains("tell process \"Warp\""))
        XCTAssertTrue(script.contains(
            "click menu item \"Switch to Next Tab\" of menu \"Tab\" of menu bar item \"Tab\" of menu bar 1"
        ))
    }

    func testWarpJumpTimingConstants() {
        // frontmost 轮询：上限 1.5s、间隔 25ms；tab 推进落盘等待 0.1s
        XCTAssertEqual(TerminalSessionFocuser.warpFrontmostMaxWait, 1.5)
        XCTAssertEqual(TerminalSessionFocuser.warpFrontmostPollInterval, 0.025)
        XCTAssertEqual(TerminalSessionFocuser.warpTabCycleSettleDelay, 0.1)
    }

    func testWarpMaxTabAttemptsClampsAndAddsSafetyMargin() {
        // tabCount 读取失败（0）按单 tab 兜底；+2 为计数毛刺安全余量
        XCTAssertEqual(TerminalSessionFocuser.warpMaxTabAttempts(tabCount: 0), 3)
        XCTAssertEqual(TerminalSessionFocuser.warpMaxTabAttempts(tabCount: 1), 3)
        XCTAssertEqual(TerminalSessionFocuser.warpMaxTabAttempts(tabCount: 5), 7)
    }

    func testWarpPaneMatchesIsCaseInsensitive() {
        // Reader 返回大写 hex，贯穿链理论同形态；比对容错大小写差异
        XCTAssertTrue(TerminalSessionFocuser.warpPaneMatches(
            focusedPaneUUID: "ABCDEF0123", targetPaneUUID: "ABCDEF0123"
        ))
        XCTAssertTrue(TerminalSessionFocuser.warpPaneMatches(
            focusedPaneUUID: "abcdef0123", targetPaneUUID: "ABCDEF0123"
        ))
        // 焦点不可读（DB 缺失等）或值不等 → 不匹配
        XCTAssertFalse(TerminalSessionFocuser.warpPaneMatches(
            focusedPaneUUID: nil, targetPaneUUID: "ABCDEF0123"
        ))
        XCTAssertFalse(TerminalSessionFocuser.warpPaneMatches(
            focusedPaneUUID: "FFFFFFFF", targetPaneUUID: "ABCDEF0123"
        ))
    }

    func testWarpCycleDecisionDoneAdvanceGiveUp() {
        let target = "ABCDEF0123"
        // 焦点已命中 → 立即完成（fast path 与循环内共用）
        XCTAssertEqual(
            TerminalSessionFocuser.warpCycleDecision(
                focusedPaneUUID: target, targetPaneUUID: target, attempt: 1, maxAttempts: 7
            ),
            .done
        )
        // 未命中且未到上限 → 继续推进
        XCTAssertEqual(
            TerminalSessionFocuser.warpCycleDecision(
                focusedPaneUUID: "FFFFFFFF", targetPaneUUID: target, attempt: 1, maxAttempts: 7
            ),
            .advance
        )
        // 未命中且已达上限 → 放弃（激活已达，精度未确认）
        XCTAssertEqual(
            TerminalSessionFocuser.warpCycleDecision(
                focusedPaneUUID: nil, targetPaneUUID: target, attempt: 7, maxAttempts: 7
            ),
            .giveUp
        )
    }

    func testWarpIsFrontmostBundleIdentifier() {
        XCTAssertTrue(TerminalSessionFocuser.warpIsFrontmostBundleIdentifier("dev.warp.Warp-Stable"))
        XCTAssertFalse(TerminalSessionFocuser.warpIsFrontmostBundleIdentifier(nil))
        XCTAssertFalse(TerminalSessionFocuser.warpIsFrontmostBundleIdentifier("com.apple.Terminal"))
    }

    func testWarpFocusStoreDefaultDatabasePathPointsToWarpGroupContainer() {
        // 沙盒化的 Warp 把状态存于 Group Container（与 N2a Reader 同路径约定）
        let path = WarpFocusStore.defaultDatabasePath()
        XCTAssertTrue(path.hasSuffix(
            "/Library/Group Containers/2BBY89MBSN.dev.warp"
                + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
        ))
    }
}
