import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - hover 打开行为（T13 · 智能交互层）
//
// notchOpenTrigger 五件套已删除：hover 恒为预览入口、click 恒为
// 完整面板入口。智能层补两条规则：
//   1. 预览有内容（activePreviewSessions 非空）→ dwell 到点展开
//      轻量预览（dashboard）；
//   2. 预览无内容 → dwell 到点直接展开完整面板（sessionList），
//      跳过「无活动会话」空态卡的中转。
//   3. 预览态下单击面板内部 → 升级为完整面板（任意状态单击即
//      完整面板）。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class NotchViewModelHoverTriggerTests: XCTestCase {

    // ── 智能层：预览内容分流 ───────────────────────────────────────

    func testDeferredHoverOpenExpandsPreviewWithActiveSessions() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [makeSession(id: "active-1")])
            viewModel.isHovering = true

            viewModel.performDeferredHoverOpenIfNeeded()

            // 有活动会话 → hover 预览（dashboard）
            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .hover)
        }
    }

    func testDeferredHoverOpenFallsBackToFullPanelWithoutPreviewContent() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [])
            viewModel.isHovering = true

            viewModel.performDeferredHoverOpenIfNeeded()

            // 无可预览会话 → 直接完整面板（sessionList），不展示空态卡
            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
        }
    }

    func testDeferredHoverVMDefaultProviderOpensFullPanel() async {
        await MainActor.run {
            // 生产未注入 provider 时按「无内容」处理 → 完整面板
            let viewModel = makeViewModel(previewSessions: nil)
            viewModel.isHovering = true

            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
        }
    }

    // ── 守卫回归：驻留前置条件不放松 ───────────────────────────────

    func testDeferredHoverOpenRequiresHoveringState() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [makeSession(id: "active-2")])
            viewModel.isHovering = false

            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .closed)
            XCTAssertEqual(viewModel.openReason, .unknown)
        }
    }

    func testDeferredHoverOpenSkipsWhenAlreadyOpened() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [makeSession(id: "active-3")])
            viewModel.isHovering = true
            viewModel.notchOpen(reason: .click)

            viewModel.performDeferredHoverOpenIfNeeded()

            // 已打开时不重入（不把完整面板降级回预览）
            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
        }
    }

    // ── 智能层：预览态单击升级完整面板 ─────────────────────────────

    func testOpenedHoverPreviewInteriorClickUpgradesToFullPanel() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [makeSession(id: "active-4")])
            viewModel.notchOpen(reason: .hover)
            XCTAssertEqual(viewModel.openReason, .hover)

            viewModel.handleOpenedPanelInteriorClick()

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
        }
    }

    func testOpenedFullPanelInteriorClickIsIdempotent() async {
        await MainActor.run {
            let viewModel = makeViewModel(previewSessions: [makeSession(id: "active-5")])
            viewModel.presentSessionList(reason: .click)

            viewModel.handleOpenedPanelInteriorClick()

            // 完整面板下再点面板内部：保持原样（无聊天会话恢复、不重置）
            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
        }
    }

    // ── 构造助手（与 NotchViewModelPanelSizeTests 同款） ───────────

    @MainActor
    private func makeViewModel(
        previewSessions: [SessionState]?
    ) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false },
            hoverPreviewSessionsProvider: previewSessions == nil
                ? { [] }
                : { previewSessions! }
        )
    }

    /// active 预览会话：connected（默认）+ processing（isActive）
    private func makeSession(id: String) -> SessionState {
        var session = SessionState(sessionId: id, cwd: "/tmp/\(id)")
        session.phase = .processing
        return session
    }
}
