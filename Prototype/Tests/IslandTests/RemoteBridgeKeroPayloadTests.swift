import Foundation
import IslandShared
@testable import PingIslandBridge
import Testing

// ─────────────────────────────────────────────────────────────────
// 远程链路 kero 标识贯穿（Task 5）
//
// 验证 mapper 产出的 terminalContext.terminalBundleID 在
// RemoteBridgeMessageBuilder 组装 RemoteHookEventPayload 时
// 无丢失、无改写地进入 clientInfo.terminalBundleIdentifier，
// 且 JSON wire key 与 App 侧 RemoteModels 解码约定一致。
// 远程 kero session 的识别依赖此字段（Task 6 路由输入）。
// ─────────────────────────────────────────────────────────────────

// ── 构造辅助：KERO_PANE 环境（Task 1 约定）下的真实 envelope ──
private func makeKeroEnvelope(
    extraEnvironment: [String: String] = [:]
) throws -> BridgeEnvelope {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "remote-kero-1"
    }
    """.data(using: .utf8)!

    var environment = [
        "KERO_PANE": "pane-1001",
        "TERM_PROGRAM": "ghostty",
        "TTY": "/dev/ttys044",
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
// 组装端：envelope → RemoteHookEventPayload.clientInfo
// ─────────────────────────────────────────────────────────────────

@Test
func testRemotePayloadCarriesKeroBundleIdentifierFromTerminalContext() throws {
    // 无 __CFBundleIdentifier → mapper 推断 sh.kero → 组装端原样透传
    let envelope = try makeKeroEnvelope()
    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)

    #expect(payload.clientInfo.terminalBundleIdentifier == "sh.kero")
    #expect(payload.clientInfo.terminalProgram == "kero")
}

@Test
func testRemotePayloadPreservesKeroDevBundleVariant() throws {
    // dev 构建 __CFBundleIdentifier=sh.kero.dev → 保留原值贯穿
    let envelope = try makeKeroEnvelope(
        extraEnvironment: ["__CFBundleIdentifier": "sh.kero.dev"]
    )
    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)

    #expect(payload.clientInfo.terminalBundleIdentifier == "sh.kero.dev")
}

// ─────────────────────────────────────────────────────────────────
// wire 格式：bridge 编码 key 与 App 侧 RemoteModels 解码约定一致
// （两侧 struct 均为 camelCase 合成 CodingKeys，此测试锁定拼写）
// ─────────────────────────────────────────────────────────────────

@Test
func testRemotePayloadJSONRoundTripsTerminalBundleIdentifier() throws {
    let envelope = try makeKeroEnvelope()
    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)

    let data = try JSONEncoder().encode(payload)

    // wire 层面：clientInfo JSON 里必须出现 camelCase key（App 侧解码前提）
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let clientInfo = object?["clientInfo"] as? [String: Any]
    #expect(clientInfo?["terminalBundleIdentifier"] as? String == "sh.kero")

    // roundtrip：解码后字段保持
    let decoded = try JSONDecoder().decode(RemoteHookEventPayload.self, from: data)
    #expect(decoded.clientInfo.terminalBundleIdentifier == "sh.kero")
    #expect(decoded.clientInfo.terminalProgram == "kero")
}

// ─────────────────────────────────────────────────────────────────
// 白名单防御：kero 是独立终端，不得被 IDE bundle 标识覆盖
// （resolvedTerminalHostBundleIdentifier 的 standalone 白名单
// 需含 sh.kero / sh.kero.dev，与 App 侧 TerminalAppRegistry 镜像）
// ─────────────────────────────────────────────────────────────────

@Test
func testStandaloneKeroTerminalIsNotOverriddenByIDEBundleIdentifier() throws {
    // env 同时带 IDE 痕迹（CURSOR_ 前缀触发 ideBundleID 检测）与 kero 痕迹
    let envelope = try makeKeroEnvelope(
        extraEnvironment: ["CURSOR_TRACE_ID": "trace-1"]
    )

    // 前置确认：该 env 组合确实同时产生两个不同的 bundle 标识
    #expect(envelope.terminalContext.terminalBundleID == "sh.kero")
    #expect(envelope.terminalContext.ideBundleID != nil)
    #expect(envelope.terminalContext.ideBundleID != "sh.kero")

    let payload = RemoteBridgeMessageBuilder.payload(from: envelope)
    #expect(payload.clientInfo.terminalBundleIdentifier == "sh.kero")
}
