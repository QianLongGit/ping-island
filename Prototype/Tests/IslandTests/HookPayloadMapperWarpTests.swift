import Foundation
import IslandShared
import Testing

// ─────────────────────────────────────────────────────────────────
// Warp 终端识别（Task N2a）
//
// Warp 的 TERM_PROGRAM 实际报 "WarpTerminal"（大写驼峰），小写
// "warp" 是防御形态；mapper 侧经 lowercased 归一后推断
// dev.warp.Warp-Stable。TERM_PROGRAM 缺失时以
// WARP_IS_LOCAL_SHELL_SESSION 兜底标记 terminalProgram="warp"。
// 此文件锁定识别行为不回归（kero/ghostty 路径零影响）。
// ─────────────────────────────────────────────────────────────────

private func makeEnvelope(
    environment: [String: String]
) throws -> BridgeEnvelope {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "warp-session-1"
    }
    """.data(using: .utf8)!

    return HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: environment,
        stdinData: payload
    )
}

// ─────────────────────────────────────────────────────────────────
// 主识别路径：TERM_PROGRAM 归一推断
// ─────────────────────────────────────────────────────────────────

@Test
func testWarpTerminalProgramInfersWarpStableBundle() throws {
    // Warp 真实环境 TERM_PROGRAM=WarpTerminal（保留原值，
    // bundle 经 lowercased 推断）
    let envelope = try makeEnvelope(environment: [
        "TERM_PROGRAM": "WarpTerminal",
        "TTY": "/dev/ttys045",
    ])

    #expect(envelope.terminalContext.terminalProgram == "WarpTerminal")
    #expect(envelope.terminalContext.terminalBundleID == "dev.warp.Warp-Stable")
}

@Test
func testLowercaseWarpProgramAlsoInfersWarpStableBundle() throws {
    // 小写 "warp" 防御形态同样命中
    let envelope = try makeEnvelope(environment: [
        "TERM_PROGRAM": "warp",
    ])

    #expect(envelope.terminalContext.terminalBundleID == "dev.warp.Warp-Stable")
}

@Test
func testCFBundleIdentifierPreservesWarpStableBundle() throws {
    // __CFBundleIdentifier 已能给出门票时沿用原值（优先级保真）
    let envelope = try makeEnvelope(environment: [
        "TERM_PROGRAM": "WarpTerminal",
        "__CFBundleIdentifier": "dev.warp.Warp-Stable",
    ])

    #expect(envelope.terminalContext.terminalBundleID == "dev.warp.Warp-Stable")
}

// ─────────────────────────────────────────────────────────────────
// 兜底识别：TERM_PROGRAM 缺失 + WARP_IS_LOCAL_SHELL_SESSION
// ─────────────────────────────────────────────────────────────────

@Test
func testWarpEnvFallbackMarksProgramWhenTermProgramMissing() throws {
    // TERM_PROGRAM 缺失的边缘场景：Warp 导出的
    // WARP_IS_LOCAL_SHELL_SESSION 是唯一识别信号
    let envelope = try makeEnvelope(environment: [
        "WARP_IS_LOCAL_SHELL_SESSION": "1",
        "TTY": "/dev/ttys046",
    ])

    #expect(envelope.terminalContext.terminalProgram == "warp")
    #expect(envelope.terminalContext.terminalBundleID == "dev.warp.Warp-Stable")
}

@Test
func testWarpEnvFallbackDoesNotOverrideExistingTermProgram() throws {
    // TERM_PROGRAM 有值时 Warp 兜底不得覆写（与 kero 的
    // 强制覆写语义不同：Warp 只补缺，不清白值）
    let envelope = try makeEnvelope(environment: [
        "TERM_PROGRAM": "ghostty",
        "WARP_IS_LOCAL_SHELL_SESSION": "1",
    ])

    #expect(envelope.terminalContext.terminalProgram == "ghostty")
    #expect(envelope.terminalContext.terminalBundleID == "com.mitchellh.ghostty")
}

// ─────────────────────────────────────────────────────────────────
// 回归防御：既有终端识别不受 warp case 影响
// ─────────────────────────────────────────────────────────────────

@Test
func testKeroIdentificationUnaffectedByWarpSupport() throws {
    // kero 判定先于 TERM_PROGRAM 逻辑，warp 兜底不得介入
    let envelope = try makeEnvelope(environment: [
        "KERO_PANE": "pane-2001",
        "TERM_PROGRAM": "ghostty",
    ])

    #expect(envelope.terminalContext.terminalProgram == "kero")
    #expect(envelope.terminalContext.terminalBundleID == "sh.kero")
}

@Test
func testITermIdentificationUnaffectedByWarpSupport() throws {
    let envelope = try makeEnvelope(environment: [
        "TERM_PROGRAM": "iTerm.app",
        "ITERM_SESSION_ID": "w0t0p0:UUID",
    ])

    #expect(envelope.terminalContext.terminalBundleID == "com.googlecode.iterm2")
}
