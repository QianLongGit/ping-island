import Foundation
import IslandShared
import Testing

// ─────────────────────────────────────────────────────────────────
// kero 识别（KERO_PANE 捕获 + bundle 推断）
//
// makeTerminalContext 为 private，参照现有 mapper 测试的调用形态，
// 经 makeEnvelope 间接构造 terminalContext 后断言其字段。
// ─────────────────────────────────────────────────────────────────

@Test
func testKeroPaneOverridesGhosttyProgram() throws {
    // KERO_PANE 存在 + TERM_PROGRAM=ghostty → 判为 kero，不判为 ghostty
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "kero-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "KERO_PANE": "pane-123",
            "TERM_PROGRAM": "ghostty",
            "TTY": "/dev/ttys012",
            "__CFBundleIdentifier": "sh.kero"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "kero")
    #expect(envelope.terminalContext.terminalBundleID == "sh.kero")
}

@Test
func testRealGhosttyWithoutKeroPaneStaysGhostty() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "ghostty-no-kero"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "ghostty",
            "TTY": "/dev/ttys012"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "ghostty") // 不变
}

@Test
func testKeroPanePreservesDevBundleIDAndMirrorsMetadata() throws {
    // 场景一：__CFBundleIdentifier 已是 sh.kero.dev（dev 构建）→ 保留原值，不用推断值覆盖
    let devPayload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "kero-dev-1"
    }
    """.data(using: .utf8)!

    let devEnvelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "KERO_PANE": "pane-456",
            "TERM_PROGRAM": "ghostty",
            "__CFBundleIdentifier": "sh.kero.dev"
        ],
        stdinData: devPayload
    )

    #expect(devEnvelope.terminalContext.terminalProgram == "kero")
    #expect(devEnvelope.terminalContext.terminalBundleID == "sh.kero.dev")
    #expect(devEnvelope.metadata["terminal_program"] == "kero")
    #expect(devEnvelope.metadata["terminal_bundle_id"] == "sh.kero.dev")

    // 场景二：无 __CFBundleIdentifier → 推断短路返回 sh.kero，镜像同步出现
    let inferredEnvelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "KERO_PANE": "pane-789",
            "TERM_PROGRAM": "ghostty"
        ],
        stdinData: devPayload
    )

    #expect(inferredEnvelope.terminalContext.terminalProgram == "kero")
    #expect(inferredEnvelope.terminalContext.terminalBundleID == "sh.kero")
    #expect(inferredEnvelope.metadata["terminal_program"] == "kero")
    #expect(inferredEnvelope.metadata["terminal_bundle_id"] == "sh.kero")
}
