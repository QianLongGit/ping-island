import Foundation
import IslandShared
@testable import PingIslandBridge
import Testing

// ─────────────────────────────────────────────────────────────────
// Warp pane UUID 贯穿（Task N2a）
//
// 验证三件事：
// 1. bridge 侧 Warp 判定（isWarpPaneContext）精确触发、不误伤
//    kero/ghostty 等既有终端；
// 2. 填充入口（applyWarpPaneResolution）只在 Warp 环境调用解析
//    器，非 Warp 环境零副作用；
// 3. terminalContext.warpPaneUUID → RemoteHookEventPayload
//    .clientInfo.warpPaneUUID 组装透传 + JSON wire key 与 App
//    侧 RemoteModels 解码约定一致（camelCase）。
// ─────────────────────────────────────────────────────────────────

// ── 构造辅助：Warp 环境下的真实 envelope ────────────────────────

private func makeWarpEnvelope(
    extraEnvironment: [String: String] = [:]
) throws -> BridgeEnvelope {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "warp-session-2"
    }
    """.data(using: .utf8)!

    var environment = [
        "TERM_PROGRAM": "WarpTerminal",
        "TTY": "/dev/ttys047",
    ]
    extraEnvironment.forEach { environment[$0.key] = $0.value }

    return HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: environment,
        stdinData: payload
    )
}

// ─────────────────────────────────────────────────────────────────
// 判定：isWarpPaneContext 纯函数
// ─────────────────────────────────────────────────────────────────

@Test
func testWarpContextDetectionViaTermProgram() {
    // WarpTerminal（真实形态）/ warp（小写防御）都命中
    #expect(WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: "WarpTerminal"),
        environment: [:]
    ))
    #expect(WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: "warp"),
        environment: [:]
    ))
}

@Test
func testWarpContextDetectionViaBundleIdentifier() {
    // bundle 标识大小写不敏感匹配（registry/mapper 输出混合大小写）
    #expect(WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: nil, terminalBundleID: "dev.warp.Warp-Stable"),
        environment: [:]
    ))
    #expect(WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: nil, terminalBundleID: "dev.warp.warp-stable"),
        environment: [:]
    ))
}

@Test
func testWarpContextDetectionViaWarpEnvFallback() {
    // TERM_PROGRAM/bundle 双缺时以 WARP_IS_LOCAL_SHELL_SESSION 兜底
    #expect(WarpPaneResolution.isWarpPaneContext(
        TerminalContext(),
        environment: ["WARP_IS_LOCAL_SHELL_SESSION": "1"]
    ))
}

@Test
func testNonWarpContextsAreRejected() {
    // kero / ghostty / iTerm / 空上下文一律不触发（零误伤）
    #expect(!WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: "kero", terminalBundleID: "sh.kero"),
        environment: ["KERO_PANE": "pane-1"]
    ))
    #expect(!WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: "ghostty"),
        environment: [:]
    ))
    #expect(!WarpPaneResolution.isWarpPaneContext(
        TerminalContext(terminalProgram: "iTerm.app"),
        environment: [:]
    ))
    #expect(!WarpPaneResolution.isWarpPaneContext(
        TerminalContext(),
        environment: [:]
    ))
}

// ─────────────────────────────────────────────────────────────────
// 填充入口：applyWarpPaneResolution（注入解析器）
// ─────────────────────────────────────────────────────────────────

@Test
func testApplyResolutionFillsUUIDForWarpEnvelopeOnly() throws {
    // Warp 环境：解析器返回值写入 terminalContext
    var warpEnvelope = try makeWarpEnvelope()
    WarpPaneResolution.apply(to: &warpEnvelope, environment: [
        "TERM_PROGRAM": "WarpTerminal",
    ]) { _ in
        "ABCDEF0123ABCDEF0123ABCDEF0123AB"
    }
    #expect(warpEnvelope.terminalContext.warpPaneUUID == "ABCDEF0123ABCDEF0123ABCDEF0123AB")

    // 非 Warp 环境：解析器若被错误调用将写入哨兵污染值——
    // 断言字段保持 nil 即等价于"解析器未被调用"
    let payload = "{}".data(using: .utf8)!
    var ghosttyEnvelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "ghostty"],
        stdinData: payload
    )
    WarpPaneResolution.apply(to: &ghosttyEnvelope, environment: [
        "TERM_PROGRAM": "ghostty",
    ]) { _ in
        "SHOULD-NOT-BE-USED"
    }
    #expect(ghosttyEnvelope.terminalContext.warpPaneUUID == nil)
    // Warp envelope 侧未被污染（隔离验证）
    #expect(warpEnvelope.terminalContext.warpPaneUUID == "ABCDEF0123ABCDEF0123ABCDEF0123AB")
}

@Test
func testApplyResolutionKeepsNilWhenResolverFails() throws {
    // 无 Warp 安装/DB 缺失/爬链失败：解析器返回 nil，静默保持空
    var envelope = try makeWarpEnvelope()
    WarpPaneResolution.apply(to: &envelope, environment: [
        "TERM_PROGRAM": "WarpTerminal",
    ]) { _ in nil }
    #expect(envelope.terminalContext.warpPaneUUID == nil)
}

// ─────────────────────────────────────────────────────────────────
// 组装端：envelope → RemoteHookEventPayload.clientInfo 透传
// ─────────────────────────────────────────────────────────────────

@Test
func testRemotePayloadCarriesWarpPaneUUID() throws {
    var envelope = try makeWarpEnvelope()
    envelope.terminalContext.warpPaneUUID = "1234567890ABCDEF1234567890ABCDEF"

    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)
    #expect(payload.clientInfo.warpPaneUUID == "1234567890ABCDEF1234567890ABCDEF")
    #expect(payload.clientInfo.terminalBundleIdentifier == "dev.warp.Warp-Stable")
}

@Test
func testRemotePayloadWarpPaneUUIDJSONRoundTrips() throws {
    // wire 层面：clientInfo JSON 必须出现 camelCase key
    // warpPaneUUID（App 侧 RemoteModels 解码前提）
    var envelope = try makeWarpEnvelope()
    envelope.terminalContext.warpPaneUUID = "FEDCBA0987654321FEDCBA0987654321"

    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)
    let data = try JSONEncoder().encode(payload)

    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let clientInfo = object?["clientInfo"] as? [String: Any]
    #expect(clientInfo?["warpPaneUUID"] as? String == "FEDCBA0987654321FEDCBA0987654321")

    // roundtrip：解码后字段保持
    let decoded = try JSONDecoder().decode(RemoteHookEventPayload.self, from: data)
    #expect(decoded.clientInfo.warpPaneUUID == "FEDCBA0987654321FEDCBA0987654321")
}

@Test
func testRemotePayloadWithoutWarpUUIDDecodesToNil() throws {
    // 非 Warp session：字段缺席/为 null 时解码得 nil（可选字段
    // 兼容旧远端 bridge）
    let envelope = try makeWarpEnvelope()
    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)
    #expect(payload.clientInfo.warpPaneUUID == nil)

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(RemoteHookEventPayload.self, from: data)
    #expect(decoded.clientInfo.warpPaneUUID == nil)
}
