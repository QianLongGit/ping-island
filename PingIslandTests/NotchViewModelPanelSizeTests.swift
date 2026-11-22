import CoreGraphics
import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 实例面板高度规格（docked .instances，内容自适应封顶）
//
// docked 实例面板高度 = min(用户上限, max(最小可用高, 内容需求高))：
// 内容需求高由解析式估算（closedHeight + 列表 padding + 行数 ×
// SessionListCompactMetrics.estimatedRowHeight + 行间距），通知呈
// 现时以通知卡最低高度兜底——杜绝 LazyVStack 视口钳制的测量值
// （自我实现的矮面板）与「恒最大高度」两种极端（cap 不是 floor）。
// 紧凑行高（base 13）= 8 + 15 + 2 + 13.125 = 38.125；
// 宽松行高 = 16 + 17.5 + 5 + 27.5 + 3 = 69。
// ═════════════════════════════════════════════════════════════════
final class NotchViewModelPanelSizeTests: XCTestCase {

    // ── 解析式纯函数：0/1/刚好满/超限 四档 ────────────────────────

    func testFormulaZeroRowsFallsBackToMinimumUsableHeight() {
        // 0 行：内容 52 被最小可用高 closedHeight+24=56 抬底
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 0,
            isNotificationPresentationActive: false,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 56, accuracy: 0.01)
    }

    func testFormulaSingleCompactRowMatchesAnalyticExpectation() {
        // 1 行紧凑：32 + 12 + 8 + 38.125 = 90.125
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 1,
            isNotificationPresentationActive: false,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 90.125, accuracy: 0.01)
    }

    func testFormulaSingleRelaxedRowUsesRelaxedRowHeight() {
        // 1 行宽松：32 + 12 + 8 + 69 = 121
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 1,
            isNotificationPresentationActive: false,
            compactList: false,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 121, accuracy: 0.01)
    }

    func testFormulaExactlyFullContentIsNotCapped() {
        // 刚好满：需求高 == 上限时原样返回（cap 不侵蚀）
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 1,
            isNotificationPresentationActive: false,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 90.125
        )

        XCTAssertEqual(height, 90.125, accuracy: 0.01)
    }

    func testFormulaOverflowingContentIsCappedAtMaximum() {
        // 30 行：52 + 30×38.125 + 29×2 = 1253.75 → cap 700
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 30,
            isNotificationPresentationActive: false,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 700, accuracy: 0.01)
    }

    func testFormulaActiveNotificationFloorsContentAtCardMinimum() {
        // 通知活跃 0 行：内容取通知卡最低高 172 → 32+12+172 = 216
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 0,
            isNotificationPresentationActive: true,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 216, accuracy: 0.01)
    }

    // ── VM 集成：openedSize 走公式（cap 语义） ────────────────────

    func testDockedInstancesHoverZeroRowsStaysAtMinimumUsableHeight() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .hover)

            // 0 行（未上报行数）→ closedHeight + 24 = 56，而非上限 700
            XCTAssertEqual(viewModel.openedSize.height, 56, accuracy: 0.01)
        }
    }

    func testDockedInstancesOverflowingRowsReachConfiguredPanelMaximum() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.updateInstanceRowCount(30)
            viewModel.presentSessionList(reason: .click)

            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)
        }
    }

    func testDockedInstancesHeightIgnoresSmallMeasuredHeight() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.updateInstanceRowCount(30)
            viewModel.notchOpen(reason: .hover)
            // 模拟 LazyVStack 被视口钳制后上报的小测量值
            viewModel.updateOpenedMeasuredHeight(150)

            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)
        }
    }

    func testDockedInstancesHeightRespectsScreenLimit() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            // 屏幕 560 高 → screenLimit = 440，优先于设置值 700
            let viewModel = NotchViewModel(
                deviceNotchRect: .zero,
                screenRect: CGRect(x: 0, y: 0, width: 1440, height: 560),
                windowHeight: 320,
                hasPhysicalNotch: false,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false }
            )
            viewModel.updateInstanceRowCount(30)
            viewModel.notchOpen(reason: .click)

            XCTAssertEqual(viewModel.openedSize.height, 440, accuracy: 0.01)
        }
    }

    func testDockedInstancesActiveNotificationFloorsHeightAtCardMinimum() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .notification)
            viewModel.updateNotificationPresentationActive(true)

            // 0 行 + 通知卡 → 32 + 12 + 172 = 216
            XCTAssertEqual(viewModel.openedSize.height, 216, accuracy: 0.01)
        }
    }

    func testDockedInstancesSingleRelaxedRowFollowsRelaxedFormula() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            let originalCompactList = AppSettings.compactSessionList
            defer {
                AppSettings.maxPanelHeight = originalMaxPanelHeight
                AppSettings.compactSessionList = originalCompactList
            }
            AppSettings.maxPanelHeight = 700
            AppSettings.compactSessionList = false

            let viewModel = makeViewModel()
            viewModel.updateInstanceRowCount(1)
            viewModel.notchOpen(reason: .click)

            // 宽松 1 行：32 + 12 + 8 + 69 = 121
            XCTAssertEqual(viewModel.openedSize.height, 121, accuracy: 0.01)
        }
    }

    // ── 回归保护：.chat 与 detached 尺寸不随本改动漂移 ─────────────

    func testDockedChatHeightStillMatchesConfiguredPanelMaximum() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.presentChat(for: makeSession(id: "chat-size"), reason: .click)

            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)
        }
    }

    func testDetachedExpandedInstancesHeightKeepsLegacyMeasuredIndependentSize() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.beginDetachedPresentation(contentType: .instances)
            viewModel.setDetachedDisplayMode(.hoverExpanded)

            // expandedDetachedSize 恒为 min(上限, max(closedHeight+24, 220)) = 220
            XCTAssertEqual(viewModel.detachedSize.height, 220, accuracy: 0.01)

            viewModel.updateOpenedMeasuredHeight(150)
            XCTAssertEqual(viewModel.detachedSize.height, 220, accuracy: 0.01)
        }
    }

    // ── 构造助手（与 NotchViewModelTests 同款参数范式） ─────────────

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

    private func makeSession(id: String) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)"
        )
    }
}
