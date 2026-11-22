import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 完成通知标识行纯函数（T16 · 会话完成弹窗标识+点击跳转）
//
// 完成通知卡片头部新增会话标识行（项目名 · 会话标题 · 主机徽章），
// 文案判定在此纯函数化：
//   · 主机徽章——本地会话恒「本地」；远程会话复用 T12-A
//     HoverSessionHostBadge.badgeTitle（endpoint 命中取展示名、
//     未命中回退 host 部分），极端无 host 提示时兜底「远程」；
//   · 单段名——子代理/网关会话沿用会话列表行的单段标题展示
//     （usesTitleOnlySubagentPresentation || shouldHideProjectContextInUI）。
// ═════════════════════════════════════════════════════════════════
final class SessionCompletionNotificationIdentityTests: XCTestCase {

    // ── 主机徽章文案 ───────────────────────────────────────────────

    func testLocalSessionBadgeTextIsLocal() {
        let local = makeSession(id: "local")

        XCTAssertEqual(
            SessionCompletionNotificationIdentity.hostBadgeText(for: local, endpoints: []),
            "本地"
        )
    }

    func testRemoteSessionWithoutEndpointFallsBackToHost() {
        var remote = makeSession(id: "remote")
        remote.clientInfo.remoteHost = "buildbox:2222"

        XCTAssertEqual(
            SessionCompletionNotificationIdentity.hostBadgeText(for: remote, endpoints: []),
            "buildbox"
        )
    }

    func testRemoteSessionResolvesEndpointDisplayTitle() {
        var remote = makeSession(id: "remote")
        remote.clientInfo.remoteHost = "homeubuntu"
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            SessionCompletionNotificationIdentity.hostBadgeText(for: remote, endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testRemoteBridgeSessionWithoutHostHintShowsGenericRemoteBadge() {
        // ingress 命中 remoteBridge 即远程，但无 host 提示可解析时
        // 不得误标「本地」——兜底统一文案「远程」
        var bridged = makeSession(id: "bridged")
        bridged.ingress = .remoteBridge

        XCTAssertEqual(
            SessionCompletionNotificationIdentity.hostBadgeText(for: bridged, endpoints: []),
            "远程"
        )
    }

    // ── 单段名判定 ─────────────────────────────────────────────────

    func testSubagentSessionUsesSingleTitlePresentation() {
        // 启发式子代理（Qoder Agent 行）在列表行即单段标题展示，
        // 通知标识行须保持同一判定
        let subagent = SessionState(
            sessionId: "qoder-heuristic-subagent",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .qoder, profileID: "qoder", name: "Qoder"),
            heuristicSubagentDisplayTitle: "Agent · Read File README.md"
        )

        XCTAssertTrue(
            SessionCompletionNotificationIdentity.usesSingleTitlePresentation(for: subagent)
        )
    }

    func testRegularSessionUsesTwoSegmentIdentity() {
        let regular = makeSession(id: "regular")

        XCTAssertFalse(
            SessionCompletionNotificationIdentity.usesSingleTitlePresentation(for: regular)
        )
    }

    // ── 帮手 ───────────────────────────────────────────────────────

    private func makeSession(id: String) -> SessionState {
        SessionState(sessionId: id, cwd: "/tmp/\(id)", phase: .processing)
    }

    private func makeEndpoint(displayName: String, target: String, port: Int = 22) -> RemoteEndpoint {
        RemoteEndpoint(displayName: displayName, sshTarget: target, sshPort: port)
    }
}
