import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - hover 打开方式行为（notchOpenTrigger 档位联动）
//
// hover 档（默认）：dwell 到点后 performDeferredHoverOpenIfNeeded
// 正常展开；click 档：同入口只做视觉反馈，不得触发 notchOpen。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class NotchViewModelHoverTriggerTests: XCTestCase {

    func testDeferredHoverOpenExpandsPanelOnHoverTrigger() async {
        await MainActor.run {
            let originalTrigger = AppSettings.notchOpenTrigger
            defer { AppSettings.notchOpenTrigger = originalTrigger }
            AppSettings.notchOpenTrigger = .hover

            let viewModel = makeViewModel()
            viewModel.isHovering = true

            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .hover)
        }
    }

    func testDeferredHoverOpenDoesNotExpandPanelOnClickTrigger() async {
        await MainActor.run {
            let originalTrigger = AppSettings.notchOpenTrigger
            defer { AppSettings.notchOpenTrigger = originalTrigger }
            AppSettings.notchOpenTrigger = .click

            let viewModel = makeViewModel()
            viewModel.isHovering = true

            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .closed)
            XCTAssertEqual(viewModel.openReason, .unknown)
        }
    }

    // ── 构造助手（与 NotchViewModelPanelSizeTests 同款） ───────────

    @MainActor
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )
    }
}
