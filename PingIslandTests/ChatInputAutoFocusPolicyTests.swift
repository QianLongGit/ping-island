import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 对话输入框自动聚焦判定（T30）
//
// 自动弹出场景下请求 FocusState 可能把窗口拉成 key 并激活应用；
// 只有宿主窗口已是 key（用户点进对话）且可发消息时才请求焦点。
// ═════════════════════════════════════════════════════════════════
final class ChatInputAutoFocusPolicyTests: XCTestCase {
    func testAutoFocusOnlyWhenHostWindowIsKeyAndMessagingAvailable() {
        XCTAssertTrue(
            ChatInputAutoFocusPolicy.shouldFocus(isHostWindowKey: true, canSendMessages: true),
            "用户点进对话（窗口已是 key）时输入框照常自动聚焦"
        )
        XCTAssertFalse(
            ChatInputAutoFocusPolicy.shouldFocus(isHostWindowKey: false, canSendMessages: true),
            "自动弹出场景窗口不是 key，不得请求键盘焦点"
        )
        XCTAssertFalse(
            ChatInputAutoFocusPolicy.shouldFocus(isHostWindowKey: true, canSendMessages: false),
            "不可发消息时没有输入框可聚焦"
        )
    }
}
