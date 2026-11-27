import Combine
import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 手动时钟（T30 · 延时任务测试替身）
//
// 悬停驻留（0.6s）、离开宽限（1.5s）、交互抑制（0.12s）都是「时间即
// 行为」的判定。测试用这只手动时钟精确推进，断言不依赖真实等待。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class ManualDelayedWorkScheduler: DetachedIslandDelayedWorkScheduling {
    private struct PendingWork {
        let id: UUID
        /// 调度时的当前时刻
        let scheduledAt: TimeInterval
        /// 请求的延时
        let delay: TimeInterval
        let work: @MainActor () -> Void
    }

    private var elapsed: TimeInterval = 0
    private var pending: [PendingWork] = []

    /// 尚未执行的延时任务（按调度顺序）
    var pendingDelays: [TimeInterval] {
        pending.map(\.delay)
    }

    func schedule(
        after delay: TimeInterval,
        work: @escaping @MainActor () -> Void
    ) -> DetachedIslandDelayedWorkToken {
        let id = UUID()
        pending.append(
            PendingWork(id: id, scheduledAt: elapsed, delay: delay, work: work)
        )
        return DetachedIslandDelayedWorkToken { [weak self] in
            self?.pending.removeAll { $0.id == id }
        }
    }

    /// 推进时钟：依次执行到期任务（任务本身再排的任务按新时刻计算）
    func advance(by interval: TimeInterval) {
        elapsed += interval

        var executionBudget = 64
        while executionBudget > 0 {
            executionBudget -= 1
            let due = pending
                .filter { $0.scheduledAt + $0.delay <= elapsed }
                .min { lhs, rhs in
                    let lhsDue = lhs.scheduledAt + lhs.delay
                    let rhsDue = rhs.scheduledAt + rhs.delay
                    return lhsDue != rhsDue ? lhsDue < rhsDue : false
                }
            guard let next = due else { return }
            pending.removeAll { $0.id == next.id }
            next.work()
        }
    }
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 悬浮胶囊鼠标路由规则（T30）
//
// 纯函数层断言：宠物可见形象始终接受；面板仅在就绪态接受；
// 就绪需要「指针在面板内真的动过」。
// ═════════════════════════════════════════════════════════════════
final class DetachedIslandMouseRoutingTests: XCTestCase {
    private let petVisibleRect = CGRect(x: 100, y: 100, width: 74, height: 74)
    private let bubbleRect = CGRect(x: 300, y: 100, width: 392, height: 300)

    // ── 接受 / 穿透判定 ──────────────────────────────────────────

    func testPetVisibleShapeAlwaysAcceptsMouse() {
        XCTAssertTrue(DetachedIslandMouseRouting.acceptsMouse(
            at: CGPoint(x: 137, y: 137),
            petVisibleRect: petVisibleRect,
            bubbleRect: nil,
            bubbleInteractive: false
        ))
        XCTAssertTrue(DetachedIslandMouseRouting.acceptsMouse(
            at: CGPoint(x: 100.5, y: 173.5),
            petVisibleRect: petVisibleRect,
            bubbleRect: bubbleRect,
            bubbleInteractive: false
        ))
    }

    func testTransparentAreaOutsidePetAndPanelPassesThrough() {
        // 命中框死区（92 与 74 之间）与 gutter
        XCTAssertFalse(DetachedIslandMouseRouting.acceptsMouse(
            at: CGPoint(x: 95, y: 137),
            petVisibleRect: petVisibleRect,
            bubbleRect: bubbleRect,
            bubbleInteractive: true
        ))
        XCTAssertFalse(DetachedIslandMouseRouting.acceptsMouse(
            at: CGPoint(x: 299, y: 137),
            petVisibleRect: petVisibleRect,
            bubbleRect: bubbleRect,
            bubbleInteractive: true
        ))
    }

    func testPanelAcceptsMouseOnlyWhenInteractive() {
        let insidePanel = CGPoint(x: 496, y: 250)

        XCTAssertFalse(DetachedIslandMouseRouting.acceptsMouse(
            at: insidePanel,
            petVisibleRect: petVisibleRect,
            bubbleRect: bubbleRect,
            bubbleInteractive: false
        ))
        XCTAssertTrue(DetachedIslandMouseRouting.acceptsMouse(
            at: insidePanel,
            petVisibleRect: petVisibleRect,
            bubbleRect: bubbleRect,
            bubbleInteractive: true
        ))
    }

    func testNullPanelRectNeverAcceptsMouse() {
        XCTAssertFalse(DetachedIslandMouseRouting.acceptsMouse(
            at: CGPoint(x: 496, y: 250),
            petVisibleRect: petVisibleRect,
            bubbleRect: .null,
            bubbleInteractive: true
        ))
    }

    // ── 就绪判定：指针必须在面板内真的动过 ──────────────────────

    func testStationaryPointerInsideNewPanelIsNotReady() {
        let pointer = CGPoint(x: 496, y: 250)

        XCTAssertFalse(DetachedIslandMouseRouting.isAutoPanelReady(
            pointerLocation: pointer,
            movementBaseline: pointer
        ))
        XCTAssertFalse(DetachedIslandMouseRouting.isAutoPanelReady(
            pointerLocation: pointer,
            movementBaseline: nil
        ))
    }

    func testPointerMovingInsidePanelBecomesReady() {
        let baseline = CGPoint(x: 496, y: 250)

        // 抖动 1pt：不算移动
        XCTAssertFalse(DetachedIslandMouseRouting.isAutoPanelReady(
            pointerLocation: CGPoint(x: 497, y: 251),
            movementBaseline: baseline
        ))
        // 移动 4pt：就绪
        XCTAssertTrue(DetachedIslandMouseRouting.isAutoPanelReady(
            pointerLocation: CGPoint(x: 500, y: 250),
            movementBaseline: baseline
        ))
    }

    // ── 悬停触发区几何 ───────────────────────────────────────────

    func testPetHoverTriggerCoversVisibleShapeOnly() {
        let metrics = DetachedIslandPetMetrics(scale: 1)
        let inset = (metrics.petHitFrame - metrics.petVisualFrame) / 2

        XCTAssertTrue(metrics.isInsideVisibleFrame(CGPoint(x: 46, y: 46)))
        XCTAssertTrue(metrics.isInsideVisibleFrame(CGPoint(x: inset + 1, y: 46)))
        // 命中框死区（92 与 74 之间）不算停在宠物上
        XCTAssertFalse(metrics.isInsideVisibleFrame(CGPoint(x: 4, y: 46)))
        XCTAssertFalse(metrics.isInsideVisibleFrame(CGPoint(x: 88, y: 46)))
        XCTAssertFalse(metrics.isInsideVisibleFrame(CGPoint(x: 46, y: 4)))
    }
}
