import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 悬浮宠物悬停弹出判定（T12-B/C · detached hover 打开语义）
//
// detached 悬浮宠物此前只有点击（handlePetTap）与事件自动弹出
// （attention/完成通知）两条路径；本项补齐「悬停短驻留后弹出预览」，
// 并统一受「面板打开方式」设置（notchOpenTrigger）门控：
// hover 档=悬停弹出活动会话预览；click 档=保持隐藏仅点击打开。
// 预览内容源 activePreviewSessions 已与主列表同源（既有收录规则），
// 悬停弹出让活动会话无需等通知即可进入预览（T12-C 行为目标）。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class DetachedIslandPetHoverTriggerTests: XCTestCase {

    // ── 悬停弹出判定 ───────────────────────────────────────────────

    func testHoverTriggerOpensPreviewWhenHiddenAndIdle() {
        XCTAssertTrue(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            notchOpenTrigger: .hover,
            bubbleState: .hidden,
            isPetDragging: false
        ))
    }

    func testClickTriggerSuppressesPetHoverPreview() {
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            notchOpenTrigger: .click,
            bubbleState: .hidden,
            isPetDragging: false
        ))
    }

    func testExistingBubbleSuppressesPetHoverPreview() {
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            notchOpenTrigger: .hover,
            bubbleState: .hoverPreview,
            isPetDragging: false
        ))
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            notchOpenTrigger: .hover,
            bubbleState: .pinned,
            isPetDragging: false
        ))
    }

    func testPetDraggingSuppressesPetHoverPreview() {
        XCTAssertFalse(DetachedIslandContentModel.shouldPresentPetHoverPreview(
            notchOpenTrigger: .hover,
            bubbleState: .hidden,
            isPetDragging: true
        ))
    }

    // ── 驻留延迟常量 ───────────────────────────────────────────────

    func testPetHoverActivationDelayAlignsDockedHoverDwell() {
        // 对齐 docked 非全屏 hover 驻留延迟（NotchViewModel.hoverActivationDelay 0.24s）
        XCTAssertEqual(DetachedIslandPanelMetrics.petHoverActivationDelay, 0.24)
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
