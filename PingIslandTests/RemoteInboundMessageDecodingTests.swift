import XCTest
@testable import Ping_Island

/// ══════════════════════════════════════════════════════════════════
/// 远端 hello wire 解码（Task 28 FIX2，第 35 审 P2-2 补测）
///
/// FIX1 让 bridge 握手 hello 携带 `now`（远端时钟基准，用于标定
/// 跨主机时钟偏移）。这是本轮最大的 wire 回归风险点：一旦 App
/// 入站解码失败，所有远程连接都起不来。App 真实入站路径
///（RemoteConnectorManager 的行解码器）用 `JSONDecoder()` 默认
/// 策略，`.hello` 分支直接对 `RemoteDaemonHello` 走 `init(from:)`
/// ——本用例用同一默认策略解码同一 struct，覆盖该 wire 通道：
///   - 带 `now` 的 hello（Codable 默认 Date = 自 2001 起算的
///     Double 秒）解码成功且非 nil；
///   - 旧 bridge 的 hello（无 `now`）解码得 nil 且不崩，偏移
///     标定回落 0（行为与 FIX1 之前完全一致）。
/// ══════════════════════════════════════════════════════════════════
final class RemoteInboundMessageDecodingTests: XCTestCase {

    /// 新 bridge hello：`now` 必须经默认策略解码为非 nil 的
    /// referenceDate 语义 Date，否则偏移标定整体失效。
    func testHelloWithNowDecodesThroughInboundDefaultDecoderStrategy() throws {
        let json = """
        {"type":"hello","version":"1.14.2","hostname":"synthetic-bridge","now":700000000.5}
        """
        // 与 RemoteConnectorManager 入站行解码器完全同款（默认策略）
        let hello = try JSONDecoder().decode(RemoteDaemonHello.self, from: Data(json.utf8))
        XCTAssertEqual(hello.type, "hello")
        XCTAssertEqual(hello.hostname, "synthetic-bridge")
        XCTAssertEqual(hello.now, Date(timeIntervalSinceReferenceDate: 700_000_000.5))
    }

    /// 旧 bridge hello（无 `now`）：解码得 nil、不崩，偏移保持 0。
    func testLegacyHelloWithoutNowDecodesAsNilAndKeepsZeroOffset() throws {
        let json = """
        {"type":"hello","version":"1.13.0","hostname":"legacy-bridge"}
        """
        let hello = try JSONDecoder().decode(RemoteDaemonHello.self, from: Data(json.utf8))
        XCTAssertNil(hello.now)
        // nil → 偏移 0：与 T28 之前的行为逐字一致，不得误杀
        XCTAssertEqual(
            RemoteConnectorManager.clockOffset(helloNow: hello.now, receivedAt: Date()),
            0
        )
    }
}
