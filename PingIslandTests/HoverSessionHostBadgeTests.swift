import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 悬停预览主机名徽章（T12-A · 通知弹出/悬停预览标题行）
//
// 悬停预览族（HoverSessionHeader / SessionHoverCompactRow）的
// 「项目名 · 会话标题」行需追加「 · 主机名」后缀：仅远程会话显示，
// 文案复用 RemoteConnectorManager.resolvedRemoteHostBadgeTitle，
// 低亮度语义与会话列表 T9 徽章一致（分隔符 0.34 / 主机名 0.5）。
// ═════════════════════════════════════════════════════════════════
final class HoverSessionHostBadgeTests: XCTestCase {

    // ── 文案判定 ───────────────────────────────────────────────────

    func testLocalSessionYieldsNoBadgeTitle() {
        let local = makeSession(id: "local")

        XCTAssertNil(HoverSessionHostBadge.badgeTitle(for: local, endpoints: []))
    }

    func testRemoteSessionWithoutEndpointFallsBackToHost() {
        var remote = makeSession(id: "remote")
        remote.clientInfo.remoteHost = "buildbox:2222"

        XCTAssertEqual(
            HoverSessionHostBadge.badgeTitle(for: remote, endpoints: []),
            "buildbox"
        )
    }

    func testRemoteSessionResolvesEndpointDisplayTitle() {
        var remote = makeSession(id: "remote")
        remote.clientInfo.remoteHost = "homeubuntu"
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            HoverSessionHostBadge.badgeTitle(for: remote, endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testEmptyRemoteHostHintYieldsNoBadgeTitle() {
        var remote = makeSession(id: "remote")
        remote.clientInfo.remoteHost = "  "

        XCTAssertNil(HoverSessionHostBadge.badgeTitle(for: remote, endpoints: []))
    }

    // ── 度量表（与列表 T9 徽章同语义）──────────────────────────────

    func testBadgeOpacityMatchesListBadgeSemantics() {
        XCTAssertEqual(HoverSessionHostBadgeMetrics.separatorOpacity, 0.34)
        XCTAssertEqual(HoverSessionHostBadgeMetrics.hostOpacity, 0.5)
    }

    func testBadgeFontSizeFollowsRowProjectNameFontSize() {
        // 徽章字号跟随所在行的项目名字号（Header 与紧凑行各自传入）
        XCTAssertEqual(HoverSessionHostBadgeMetrics.fontSize(matching: 13), 13)
        XCTAssertEqual(HoverSessionHostBadgeMetrics.fontSize(matching: 12), 12)
        XCTAssertEqual(HoverSessionHostBadgeMetrics.fontSize(matching: 10.5), 10.5)
    }

    // ── 帮手 ───────────────────────────────────────────────────────

    private func makeSession(id: String) -> SessionState {
        SessionState(sessionId: id, cwd: "/tmp/\(id)", phase: .processing)
    }

    private func makeEndpoint(displayName: String, target: String, port: Int = 22) -> RemoteEndpoint {
        RemoteEndpoint(displayName: displayName, sshTarget: target, sshPort: port)
    }
}
