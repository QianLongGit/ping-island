import XCTest
@testable import Ping_Island

// ═══════════════════════════════════════════════════════════════
// 远程会话标题透传（Task 11 · App 侧 wire + 重建注入）
//
// 远程转写 jsonl 在 SSH 主机上，Mac 侧 ConversationParser 读不
// 到（displayTitle 第 2 级断链，右段回退 projectName）。本链路：
//   ▸ wire：RemoteHookEventPayload 顶层新字段 conversationTitle
//     （camelCase 惯例，同 requestID/sessionID；旧 bridge 缺字段
//     解码得 nil，向后兼容）
//   ▸ 重建：SessionStore 将非空标题写入 conversationInfo.summary
//     （displayTitle 第 2 级消费位，UI 零改动）；每事件刷新
//     （custom-title 每轮重写，取新弃旧）；nil 不覆盖旧值。
//
// 本地路径（HookSocketServer）不注入：ConversationParser 直读
// 本地转写是权威来源，避免双写竞争。
// ═══════════════════════════════════════════════════════════════
final class RemoteConversationTitleTests: XCTestCase {

    // MARK: - Wire Decode（新旧 bridge 兼容）

    func testLegacyPayloadWithoutConversationTitleDecodesAsNil() throws {
        let payload = try decodePayload(extraJSON: "")  // 旧 bridge：无该字段

        XCTAssertNil(payload.conversationTitle)
    }

    func testConversationTitleDecodesFromWire() throws {
        let payload = try decodePayload(extraJSON: ", \"conversationTitle\": \"Kero-Island\"")

        XCTAssertEqual(payload.conversationTitle, "Kero-Island")
    }

    func testExplicitNullDecodesAsNil() throws {
        let payload = try decodePayload(extraJSON: ", \"conversationTitle\": null")

        XCTAssertNil(payload.conversationTitle)
    }

    // MARK: - 重建注入（有值刷新 / nil 不覆盖）

    func testInjectsTitleIntoConversationSummary() {
        var session = makeSession()

        SessionStore.applyRemoteConversationTitle("Kero-Island", to: &session)

        XCTAssertEqual(session.conversationInfo.summary, "Kero-Island")
    }

    func testInjectionPreservesOtherConversationFields() {
        var session = makeSession(summary: nil)
        session.conversationInfo = ConversationInfo(
            summary: nil, lastMessage: "last", lastMessageRole: "assistant",
            lastToolName: "Bash", firstUserMessage: "first", lastUserMessageDate: nil
        )

        SessionStore.applyRemoteConversationTitle("新标题", to: &session)

        XCTAssertEqual(session.conversationInfo.summary, "新标题")
        XCTAssertEqual(session.conversationInfo.lastMessage, "last")
        XCTAssertEqual(session.conversationInfo.lastMessageRole, "assistant")
        XCTAssertEqual(session.conversationInfo.lastToolName, "Bash")
        XCTAssertEqual(session.conversationInfo.firstUserMessage, "first")
    }

    func testNilTitleDoesNotOverrideExistingSummary() {
        var session = makeSession(summary: "旧 bridge 时代留下的标题")

        SessionStore.applyRemoteConversationTitle(nil, to: &session)

        XCTAssertEqual(session.conversationInfo.summary, "旧 bridge 时代留下的标题")
    }

    func testBlankTitleDoesNotOverrideExistingSummary() {
        var session = makeSession(summary: "既有标题")

        SessionStore.applyRemoteConversationTitle("   ", to: &session)

        XCTAssertEqual(session.conversationInfo.summary, "既有标题")
    }

    func testTitleRefreshesOnEveryEvent() {
        var session = makeSession()

        SessionStore.applyRemoteConversationTitle("第一轮标题", to: &session)
        SessionStore.applyRemoteConversationTitle("第二轮标题", to: &session)

        XCTAssertEqual(session.conversationInfo.summary, "第二轮标题")
    }

    func testDisplayTitleConsumesInjectedSummary() {
        // displayTitle 第 2 级即 conversationInfo.summary——注入后
        // 无 sessionName 时右段直接显示真实会话标题（UI 零改动的依据）。
        var session = makeSession()

        SessionStore.applyRemoteConversationTitle("Kero-Island", to: &session)

        XCTAssertEqual(session.displayTitle, "Kero-Island")
    }

    func testSessionNameStillWinsOverInjectedTitle() {
        var session = makeSession(sessionName: "用户手动命名")

        SessionStore.applyRemoteConversationTitle("Kero-Island", to: &session)

        XCTAssertEqual(session.displayTitle, "用户手动命名")
    }

    // MARK: - 构造辅助

    private func decodePayload(extraJSON: String) throws -> RemoteHookEventPayload {
        let json = """
        {
          "requestID": "11111111-2222-3333-4444-555555555555",
          "sessionID": "remote-title-1",
          "cwd": "/home/dev/project",
          "event": "Stop",
          "status": "idle",
          "provider": "claude",
          "expectsResponse": false,
          "clientInfo": {"kind": "claudeCode"}\(extraJSON)
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(RemoteHookEventPayload.self, from: data)
    }

    private func makeSession(
        summary: String? = nil,
        sessionName: String? = nil
    ) -> SessionState {
        SessionState(
            sessionId: "remote-title-1",
            cwd: "/home/dev/project",
            projectName: "project",
            provider: .claude,
            ingress: .remoteBridge,
            sessionName: sessionName,
            conversationInfo: ConversationInfo(
                summary: summary, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        )
    }
}
