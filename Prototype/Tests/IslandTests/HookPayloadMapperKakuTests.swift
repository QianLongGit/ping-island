import Foundation
import IslandShared
import Testing

// ─────────────────────────────────────────────────────────────────
// Kaku 识别（TERM_PROGRAM=kaku 推断 + bundle 保真）
//
// Kaku 是 WezTerm 家族终端（tw93 fork），TERM_PROGRAM 报 "kaku"。
// 推断链路与 kero 对称：makeTerminalContext 直通 program，bundleID
// 缺失时经 inferredTerminalBundleID 兜底。
// ─────────────────────────────────────────────────────────────────

@Test
func testKakuProgramInfersKakuBundleIdentifier() throws {
    // 无 __CFBundleIdentifier → 推断兜底返回 fun.tw93.kaku
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "kaku-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "kaku",
            "TTY": "/dev/ttys012"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "kaku")
    #expect(envelope.terminalContext.terminalBundleID == "fun.tw93.kaku")
    #expect(envelope.metadata["terminal_program"] == "kaku")
    #expect(envelope.metadata["terminal_bundle_id"] == "fun.tw93.kaku")
}

@Test
func testKakuBundleIdentifierEnvValueIsPreserved() throws {
    // __CFBundleIdentifier 已是 fun.tw93.kaku → 保留原值，不被推断覆盖
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "kaku-2"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "kaku",
            "TTY": "/dev/ttys012",
            "__CFBundleIdentifier": "fun.tw93.kaku"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "kaku")
    #expect(envelope.terminalContext.terminalBundleID == "fun.tw93.kaku")
}

@Test
func testWezTermProgramInferenceDoesNotRegress() throws {
    // kaku case 落位不得影响 wezterm 既有推断
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "wez-regress"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "wezterm",
            "TTY": "/dev/ttys012"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "wezterm")
    #expect(envelope.terminalContext.terminalBundleID == "com.github.wez.wezterm")
}
