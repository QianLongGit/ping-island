import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 悬停预览行集（T29：显示全部活动会话）
//
// SessionHoverDashboardView.displayedSessions(from:) 是预览行
// 集的可测入口（计算属性的同名透传）：上游传入多少活动会话就
// 渲染多少行，不再按 3 行截断——面板高度随行数线性撑开、至
// maximumOpenedHeight 封顶，超出部分在面板内滚动。
// ═════════════════════════════════════════════════════════════════
final class SessionHoverDashboardViewTests: XCTestCase {

    func testDisplayedSessionsReturnsAllSessionsBeyondThreeCap() {
        let sessions = (1...5).map { index in
            SessionState(sessionId: "hover-\(index)", cwd: "/tmp/hover-\(index)")
        }

        let displayed = SessionHoverDashboardView.displayedSessions(from: sessions)

        // 5 个会话进 → 5 个出（修复前 prefix(3) 只出 3 个）
        XCTAssertEqual(displayed.count, 5)
        XCTAssertEqual(displayed.map(\.sessionId), sessions.map(\.sessionId))
    }

    func testDisplayedSessionsPreservesEmptyAndShortLists() {
        // 空表 → 空态卡（HoverEmptyPreviewView）路径不受影响
        XCTAssertTrue(SessionHoverDashboardView.displayedSessions(from: []).isEmpty)

        // 1-3 行行为与旧实现一致（回归保护）
        let three = (1...3).map { index in
            SessionState(sessionId: "hover-\(index)", cwd: "/tmp/hover-\(index)")
        }
        XCTAssertEqual(
            SessionHoverDashboardView.displayedSessions(from: three).map(\.sessionId),
            three.map(\.sessionId)
        )
    }
}
