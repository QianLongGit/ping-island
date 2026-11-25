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
//
// T13 增补：hover 预览（dashboard）高度 = 同式 cap 语义，但内容
// 需求高取「preference 实测优先、卡数估算兜底」——dashboard 为
// 普通 VStack（非 Lazy）实测可信；估算 = 12 + 卡数×62 +
// (卡数-1)×18 + 18（regular 密度 padding/间距 + 紧凑行高 62 近似），
// 0 卡时空态卡按 160 估。detached .instances 接入 docked 同一解
// 析式（去固定 170 fallback 与 300 封顶），实测通知高取 max 融合。
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
        // 1 行紧凑：32 + 12 + 8 + 42.5 = 94.5
        // （T20 字号统一后行高 = 8 + 15×1.25 + 2 + 11×1.25 = 42.5）
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 1,
            isNotificationPresentationActive: false,
            compactList: true,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 94.5, accuracy: 0.01)
    }

    func testFormulaSingleRelaxedRowUsesRelaxedRowHeight() {
        // 1 行宽松：32 + 12 + 8 + 70.25 = 122.25
        // （T20 字号统一后行高 = 16 + 18.75 + 5 + 2×13.75 + 3 = 70.25）
        let height = NotchViewModel.estimatedInstancesPanelHeight(
            instanceRowCount: 1,
            isNotificationPresentationActive: false,
            compactList: false,
            contentFontSize: 13,
            closedHeight: 32,
            maxAllowedHeight: 700
        )

        XCTAssertEqual(height, 122.25, accuracy: 0.01)
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

    func testDockedInstancesHoverZeroPreviewCardsShowsEmptyEstimate() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .hover)

            // 0 卡（未上报）→ 空态卡估算 32 + 12 + 160 = 204，而非 56 或上限
            XCTAssertEqual(viewModel.openedSize.height, 204, accuracy: 0.01)
        }
    }

    func testHoverPreviewEstimateScalesWithSessionCount() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .hover)

            // 1 卡：32 + 12 + (12 + 62 + 18) = 136
            viewModel.updateHoverPreviewSessionCount(1)
            XCTAssertEqual(viewModel.openedSize.height, 136, accuracy: 0.01)

            // 2 卡：32 + 12 + (12 + 62×2 + 18 + 18) = 216
            viewModel.updateHoverPreviewSessionCount(2)
            XCTAssertEqual(viewModel.openedSize.height, 216, accuracy: 0.01)

            // 3 卡：32 + 12 + (12 + 62×3 + 18×2 + 18) = 296
            viewModel.updateHoverPreviewSessionCount(3)
            XCTAssertEqual(viewModel.openedSize.height, 296, accuracy: 0.01)
        }
    }

    // ── T29：hover 估算线性无 3 卡封顶 + 设置上限压制 ────────────
    func testHoverPreviewEstimateScalesBeyondThreeCardsAndRespectsSettingCap() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .hover)

            // 6 卡：32 + 12 + (12 + 62×6 + 18×5 + 18) = 536，
            // 估算公式按卡数线性，不因视图历史 3 行上限回缩
            viewModel.updateHoverPreviewSessionCount(6)
            XCTAssertEqual(viewModel.openedSize.height, 536, accuracy: 0.01)

            // 设置最大面板高度压到 480 → 需求高 536 被设置上限收口
            AppSettings.maxPanelHeight = 480
            XCTAssertEqual(viewModel.openedSize.height, 480, accuracy: 0.01)
        }
    }

    func testDockedInstancesHoverPreviewMeasuredHeightTakesOverEstimate() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.notchOpen(reason: .hover)
            viewModel.updateHoverPreviewSessionCount(3)
            // 首帧估算 296（dashboard 为普通 VStack，非 LazyVStack，实测可信）
            XCTAssertEqual(viewModel.openedSize.height, 296, accuracy: 0.01)

            // preference 实测接管：highlighted 卡更高时按实测撑开
            viewModel.updateOpenedMeasuredHeight(360)
            XCTAssertEqual(viewModel.openedSize.height, 360, accuracy: 0.01)

            // 实测小于最小可用高时以 closedHeight + 24 抬底
            viewModel.updateOpenedMeasuredHeight(40)
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

    // ── T13：detached 实例面板接入同一解析式（去固定 170/300 封顶） ─

    func testDetachedInstancesHeightFollowsRowCount() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.beginDetachedPresentation(contentType: .instances)

            // 1 行紧凑：与 docked 同式 32 + 12 + 8 + 42.5 = 94.5
            // （T20 字号统一后行高 42.5；detached 面板高度链 =
            //   panelSize(for: .detached)，DetachedIslandPanelView:284
            //   消费；detachedSize 是 orb 球尺寸，与此无关。）
            viewModel.updateInstanceRowCount(1)
            XCTAssertEqual(viewModel.panelSize(for: .detached).height, 94.5, accuracy: 0.01)

            // 30 行：解析式 1253.75 → cap 700（不再固定 170 或封顶 300）
            viewModel.updateInstanceRowCount(30)
            XCTAssertEqual(viewModel.panelSize(for: .detached).height, 700, accuracy: 0.01)
        }
    }

    func testDetachedInstancesHeightMergesMeasuredNotificationHeight() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()
            viewModel.beginDetachedPresentation(contentType: .instances)
            viewModel.updateInstanceRowCount(1)

            // 实测通知卡高（面板全高量纲）高于解析式时取实测
            viewModel.updateOpenedMeasuredHeight(300)
            XCTAssertEqual(viewModel.panelSize(for: .detached).height, 300, accuracy: 0.01)
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

            // T20：宽松密度只影响行内排版，不影响面板总高（恒 700）
            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)
        }
    }

    // ── T20：点击展开的完整面板高度恒等于用户上限 ──────────────────

    func testDockedInstancesClickedHeightPinnedToMaximumOpenedHeight() async {
        await MainActor.run {
            let originalMaxPanelHeight = AppSettings.maxPanelHeight
            defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
            AppSettings.maxPanelHeight = 700

            let viewModel = makeViewModel()

            // 0 行（原最小可用高 56）也必须直接展开到上限
            viewModel.updateInstanceRowCount(0)
            viewModel.presentSessionList(reason: .click)
            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)

            // 1 行（原内容自适应 90.125）恒 700
            viewModel.updateInstanceRowCount(1)
            viewModel.presentSessionList(reason: .click)
            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)

            // 30 行（原本被 cap 到 700）恒 700，与少行无差别
            viewModel.updateInstanceRowCount(30)
            viewModel.presentSessionList(reason: .click)
            XCTAssertEqual(viewModel.openedSize.height, 700, accuracy: 0.01)
        }
    }

    func testDockedInstancesClickedWidthMatchesHoverPreviewWidth() async {
        await MainActor.run {
            let viewModel = makeViewModel()

            // hover 预览宽度基准：min(1440 - 64, 600) = 600
            viewModel.presentSessionList(reason: .click)
            XCTAssertEqual(viewModel.openedSize.width, 600, accuracy: 0.01)

            // 完整面板（click）宽度不得窄于 hover 预览（原 0.44×1440 cap 520 被移除）
            let hoverViewModel = makeViewModel()
            hoverViewModel.notchOpen(reason: .hover)
            XCTAssertGreaterThanOrEqual(
                viewModel.openedSize.width,
                hoverViewModel.openedSize.width,
                "完整面板宽度不得窄于 hover 预览面板"
            )
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
