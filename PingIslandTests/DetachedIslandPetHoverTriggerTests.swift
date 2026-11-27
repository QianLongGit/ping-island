import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 悬浮宠物悬停弹出判定（T13 · 移除 notchOpenTrigger 门控）
//
// notchOpenTrigger 五件套已删除：宠物悬停弹出不再受「面板打开
// 方式」档位门控，恒为「悬停短驻留后弹出活动会话预览」；保留
// 气泡互斥（已有气泡展示时不重复弹出）与拖拽保护两条硬规则。
// 预览内容源 activePreviewSessions 与主列表同源（既有收录规则）。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class DetachedIslandPetHoverTriggerTests: XCTestCase {

    // ── 悬停弹出判定 ───────────────────────────────────────────────

    func testHoverOpensPreviewWhenHiddenAndIdle() {
        XCTAssertTrue(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            bubbleState: .hidden,
            isPetDragging: false
        ))
    }

    func testExistingBubbleSuppressesPetHoverPreview() {
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            bubbleState: .hoverPreview,
            isPetDragging: false
        ))
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            bubbleState: .pinned,
            isPetDragging: false
        ))
    }

    func testPetDraggingSuppressesPetHoverPreview() {
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            bubbleState: .hidden,
            isPetDragging: true
        ))
    }

    // ── 驻留延迟常量 ───────────────────────────────────────────────

    // 旧语义「对齐 docked 非全屏 hover 驻留 0.24s」在 T30 被有意改掉：
    // 悬停预览面板最高 480–700pt，0.24s 下指针路过宠物就会弹出并压住
    // 工作区；改为 0.6s，只有真的停在宠物上才弹（detached 不再与 docked 对齐）。
    func testPetHoverActivationDelayRequiresDeliberateDwell() {
        XCTAssertEqual(DetachedIslandPanelMetrics.petHoverActivationDelay, 0.6)
    }

    // ── 悬停触发区 = 宠物可见形象 ─────────────────────────────────

    func testHoverTriggerIgnoresInvisibleHitFrameDeadZone() {
        let metrics = DetachedIslandPetMetrics(scale: 1)
        let inset = (metrics.petHitFrame - metrics.petVisualFrame) / 2

        XCTAssertTrue(metrics.isInsideVisibleFrame(CGPoint(x: inset + 0.5, y: 46)))
        XCTAssertFalse(metrics.isInsideVisibleFrame(CGPoint(x: inset - 0.5, y: 46)))
        XCTAssertFalse(metrics.isInsideVisibleFrame(CGPoint(x: 46, y: metrics.petHitFrame - inset + 0.5)))
    }

    // ── 预览密度接入紧凑列表设置 ───────────────────────────────────

    func testDensityResolutionFollowsSurfaceAndCompactSetting() {
        XCTAssertEqual(
            HoverPreviewDensity.resolved(surface: .floating, compactList: false),
            .detachedCompact
        )
        XCTAssertEqual(
            HoverPreviewDensity.resolved(surface: .floating, compactList: true),
            .detachedCompact
        )
        XCTAssertEqual(
            HoverPreviewDensity.resolved(surface: .docked, compactList: true),
            .detachedCompact
        )
        XCTAssertEqual(
            HoverPreviewDensity.resolved(surface: .docked, compactList: false),
            .regular
        )
    }
}
