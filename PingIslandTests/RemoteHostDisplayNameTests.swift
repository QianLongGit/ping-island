import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 远程主机名徽标映射（会话行 · 主机名后缀）
//
// 输入会话携带的 remoteHost 提示（裸 host / host:port / user@host /
// ssh:// URL 四种历史形态），在已配置 endpoints 中按 host 大小写
// 不敏感匹配（显式非默认端口须一致），命中返回 endpoint 展示名，
// 未命中回退 host 部分（去端口），空输入返回 nil。
// ═════════════════════════════════════════════════════════════════
final class RemoteHostDisplayNameTests: XCTestCase {

    // ── 命中路径 ───────────────────────────────────────────────────

    func testBareHostMatchesEndpointAndReturnsResolvedTitle() {
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "homeubuntu", endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testHostMatchIsCaseInsensitive() {
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "HOMEubuntu", endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testHostPortFormMatchesEndpointWithSamePort() {
        let endpoints = [makeEndpoint(displayName: "Build Box", target: "buildbox", port: 2222)]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "buildbox:2222", endpoints: endpoints),
            "Build Box"
        )
    }

    func testExplicitPortSkipsEndpointWithDifferentPort() {
        let endpoints = [
            makeEndpoint(displayName: "Box A", target: "box", port: 2222),
            makeEndpoint(displayName: "Box B", target: "box", port: 22)
        ]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "box:22", endpoints: endpoints),
            "Box B"
        )
    }

    func testUserAtHostFormMatchesByHost() {
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "user@homeubuntu", endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testSSHURLFormMatchesAfterStrippingScheme() {
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "ssh://homeubuntu:22", endpoints: endpoints),
            "HomeUbuntu"
        )
    }

    func testEmptyDisplayNameFallsBackToSSHTargetTitle() {
        let endpoints = [makeEndpoint(displayName: "   ", target: "165")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "165", endpoints: endpoints),
            "165"
        )
    }

    // ── 未命中与空输入 ─────────────────────────────────────────────

    func testUnmatchedHostFallsBackToHostPartWithoutPort() {
        let endpoints = [makeEndpoint(displayName: "HomeUbuntu", target: "homeubuntu")]

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "unknown-host:2222", endpoints: endpoints),
            "unknown-host"
        )
    }

    func testEmptyEndpointsReturnHostPart() {
        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "homeubuntu", endpoints: []),
            "homeubuntu"
        )
    }

    func testNilRemoteHostReturnsNil() {
        XCTAssertNil(RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: nil, endpoints: []))
    }

    func testEmptyOrWhitespaceRemoteHostReturnsNil() {
        XCTAssertNil(RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "", endpoints: []))
        XCTAssertNil(RemoteConnectorManager.resolvedRemoteHostBadgeTitle(remoteHost: "   ", endpoints: []))
    }

    // ── 构造助手 ───────────────────────────────────────────────────

    private func makeEndpoint(displayName: String, target: String, port: Int = 22) -> RemoteEndpoint {
        RemoteEndpoint(
            displayName: displayName,
            sshTarget: target,
            sshPort: port
        )
    }
}
