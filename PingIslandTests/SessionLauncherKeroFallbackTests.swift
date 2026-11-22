//
//  SessionLauncherKeroFallbackTests.swift
//  PingIslandTests
//
//  T12 第 6 项：无活动远程会话（stale-identity）点击跳转兜底。
//  场景：kero 识别上线前捕获的远程会话 terminalBundleIdentifier
//  停留在 ghostty 等旧值 → kero 早返回不命中 → 载体猎取（本机无
//  ssh 载体）落空 → 此前静默失败。修复后在载体失败路径追加
//  focusKeroSession 最后手段兜底。
//

import XCTest
@testable import Ping_Island

@MainActor
final class SessionLauncherKeroFallbackTests: XCTestCase {

    // ============================================================
    // 测试基建
    // ------------------------------------------------------------
    // focusKeroSessionHandlerForTesting 为 TerminalSessionFocuser
    // 暴露的静态 hook：拦截 focusKeroSession 真实 NSWorkspace.open
    // 调用，记录参数并返回注入结果，测试可安全断言路由行为。
    // ============================================================

    /// 远程 ghostty 会话（stale-identity 形态：kero 上线前的旧标识）
    private func makeStaleRemoteGhosttySession() -> SessionState {
        SessionState(
            sessionId: "stale-ghostty-remote",
            cwd: "/Users/dev/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                remoteHost: "dev-box.internal",
                terminalBundleIdentifier: "com.mitchellh.ghostty"
            ),
            ingress: .remoteBridge
        )
    }

    /// 远程 kero 会话（标识已刷新，命中 T6 早返回分支）
    private func makeKeroIdentifiedRemoteSession() -> SessionState {
        SessionState(
            sessionId: "kero-identified-remote",
            cwd: "/Users/dev/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                remoteHost: "dev-box.internal",
                terminalBundleIdentifier: "sh.kero"
            ),
            ingress: .remoteBridge
        )
    }

    /// 本地 ghostty 会话（对照组：本地分支不受兜底影响）
    private func makeLocalGhosttySession() -> SessionState {
        SessionState(
            sessionId: "local-ghostty",
            cwd: "/Users/dev/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                terminalBundleIdentifier: "com.mitchellh.ghostty"
            )
        )
    }

    /// 安装 hook 并返回（sessionId 记录 + 结果注入）调用记录器
    private func installKeroFocusHook(result: Bool) -> KeroFocusCallRecorder {
        let recorder = KeroFocusCallRecorder()
        TerminalSessionFocuser.focusKeroSessionHandlerForTesting = { sessionId in
            await recorder.record(sessionId: sessionId)
            return result
        }
        return recorder
    }

    private func uninstallKeroFocusHook() {
        TerminalSessionFocuser.focusKeroSessionHandlerForTesting = nil
    }

    // ============================================================
    // 用例
    // ============================================================

    /// stale-identity 远程会话：载体猎取落空后必须落到 kero 兜底，
    /// 兜底成功即整体激活成功，且透传 sessionId。
    func testRemoteGhosttySessionFallsBackToKeroWhenCarrierMissing() async {
        let recorder = installKeroFocusHook(result: true)
        defer { uninstallKeroFocusHook() }

        let activated = await SessionLauncher.shared.activate(makeStaleRemoteGhosttySession())

        XCTAssertTrue(activated, "载体缺失的 stale-identity 远程会话应经 kero 兜底激活")
        let routedSessionIds = await recorder.sessionIds
        XCTAssertEqual(
            routedSessionIds,
            ["stale-ghostty-remote"],
            "兜底应精确透传原 sessionId 给 focusKeroSession"
        )
    }

    /// kero 标识远程会话：T6 早返回分支照旧直达 focusKeroSession
    /// （hook 拦截证明路由一致，且不再继续本地瀑布）。
    func testKeroIdentifiedRemoteSessionRoutesThroughEarlyReturn() async {
        let recorder = installKeroFocusHook(result: true)
        defer { uninstallKeroFocusHook() }

        let activated = await SessionLauncher.shared.activate(makeKeroIdentifiedRemoteSession())

        XCTAssertTrue(activated, "kero 标识远程会话应命中早返回直跳")
        let routedSessionIds = await recorder.sessionIds
        XCTAssertEqual(
            routedSessionIds,
            ["kero-identified-remote"],
            "早返回应只调用一次 focusKeroSession"
        )
    }

    /// 本地会话（对照组）：任何失败路径都不得触发 kero 兜底。
    func testLocalGhosttySessionNeverTouchesKeroFallback() async {
        let recorder = installKeroFocusHook(result: true)
        defer { uninstallKeroFocusHook() }

        _ = await SessionLauncher.shared.activate(makeLocalGhosttySession())

        let calls = await recorder.sessionIds
        XCTAssertTrue(calls.isEmpty, "本地会话不得触碰 kero 跳转链（calls=\(calls)）")
    }
}

// ============================================================
// 调用记录器（actor，跨并发域安全收集 hook 参数）
// ============================================================
actor KeroFocusCallRecorder {
    private(set) var sessionIds: [String] = []

    func record(sessionId: String?) {
        sessionIds.append(sessionId ?? "<nil>")
    }
}
