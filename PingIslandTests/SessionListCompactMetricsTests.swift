import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 会话行紧凑度量（SessionListCompactMetrics 契约）
//
// 紧凑模式（settings.compactSessionList，默认开）把会话行从
// ~64pt 两行预览样式压到 ~40pt 单行预览样式。全部密度参数
// （字号 / 行距 / 头像 / 徽章间距 / 按钮边长 / 行高估算）集中
// 在 SessionListCompactMetrics 纯函数表里，本测试锁死契约：
//   1. compactList = true  → 紧凑值（目标行高 ≤ 40pt）
//   2. compactList = false → 与旧版宽松样式完全一致的值（零回归）
// ═════════════════════════════════════════════════════════════════
final class SessionListCompactMetricsTests: XCTestCase {

    // ── 字号：默认 base 13 → 标题 12 / 项目名·正文 10.5 ──────────

    func testSessionTitleFontSizeShrinksUnderCompactAtDefaultBase() {
        XCTAssertEqual(
            SessionListCompactMetrics.sessionTitleFontSize(base: 13, compactList: true), 12
        )
        XCTAssertEqual(
            SessionListCompactMetrics.sessionTitleFontSize(base: 13, compactList: false), 14
        )
    }

    func testDetailFontSizeHitsTenAndAHalfUnderCompactAtDefaultBase() {
        XCTAssertEqual(
            SessionListCompactMetrics.detailFontSize(base: 13, compactList: true), 10.5
        )
        XCTAssertEqual(
            SessionListCompactMetrics.detailFontSize(base: 13, compactList: false), 11
        )
    }

    func testProjectTitleFontSizeHitsTenAndAHalfUnderCompactAtDefaultBase() {
        XCTAssertEqual(
            SessionListCompactMetrics.projectTitleFontSize(base: 13, compactList: true), 10.5
        )
        XCTAssertEqual(
            SessionListCompactMetrics.projectTitleFontSize(base: 13, compactList: false), 12
        )
    }

    func testFontSizeFloorsSurviveAtMinimumBase() {
        // base=11（contentFontSize 下限）时紧凑值不得塌缩到不可读
        XCTAssertGreaterThanOrEqual(
            SessionListCompactMetrics.sessionTitleFontSize(base: 11, compactList: true), 11
        )
        XCTAssertGreaterThanOrEqual(
            SessionListCompactMetrics.detailFontSize(base: 11, compactList: true), 9.5
        )
        XCTAssertGreaterThanOrEqual(
            SessionListCompactMetrics.projectTitleFontSize(base: 11, compactList: true), 10.5
        )
    }

    // ── 行距：垂直 padding 减半、文本间距 5→2 ────────────────────

    func testRowVerticalPaddingHalvedUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.rowVerticalPadding(compactList: false, singleLine: false), 8)
        XCTAssertEqual(SessionListCompactMetrics.rowVerticalPadding(compactList: false, singleLine: true), 5)
        XCTAssertEqual(SessionListCompactMetrics.rowVerticalPadding(compactList: true, singleLine: false), 4)
        XCTAssertEqual(SessionListCompactMetrics.rowVerticalPadding(compactList: true, singleLine: true), 3)
    }

    func testLeadingTextSpacingTightensUnderCompactForRegularRows() {
        XCTAssertEqual(SessionListCompactMetrics.leadingTextSpacing(compactList: false, singleLine: false), 5)
        XCTAssertEqual(SessionListCompactMetrics.leadingTextSpacing(compactList: true, singleLine: false), 2)
        // single-line 紧凑呈现（折叠/Codex subagent）原本就无间距，保持 0
        XCTAssertEqual(SessionListCompactMetrics.leadingTextSpacing(compactList: false, singleLine: true), 0)
        XCTAssertEqual(SessionListCompactMetrics.leadingTextSpacing(compactList: true, singleLine: true), 0)
    }

    // ── 预览行数：紧凑下强制单行 ─────────────────────────────────

    func testPreviewLineLimitForcedToOneUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.previewLineLimit(detailsEnabled: true, compactList: false), 2)
        XCTAssertEqual(SessionListCompactMetrics.previewLineLimit(detailsEnabled: true, compactList: true), 1)
        XCTAssertEqual(SessionListCompactMetrics.previewLineLimit(detailsEnabled: false, compactList: false), 1)
        XCTAssertEqual(SessionListCompactMetrics.previewLineLimit(detailsEnabled: false, compactList: true), 1)
    }

    // ── 头像：18→14，single-line 16→13；圆角 10→8 ───────────────

    func testAvatarMascotSizeShrinksUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.avatarMascotSize(compactList: false, singleLine: false), 18)
        XCTAssertEqual(SessionListCompactMetrics.avatarMascotSize(compactList: false, singleLine: true), 16)
        XCTAssertEqual(SessionListCompactMetrics.avatarMascotSize(compactList: true, singleLine: false), 14)
        XCTAssertEqual(SessionListCompactMetrics.avatarMascotSize(compactList: true, singleLine: true), 13)
    }

    func testAvatarEdgeShrinksUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.avatarEdge(compactList: false, singleLine: false), 34)
        XCTAssertEqual(SessionListCompactMetrics.avatarEdge(compactList: false, singleLine: true), 30)
        XCTAssertEqual(SessionListCompactMetrics.avatarEdge(compactList: true, singleLine: false), 26)
        XCTAssertEqual(SessionListCompactMetrics.avatarEdge(compactList: true, singleLine: true), 24)
    }

    func testAvatarCornerRadiusTightensUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.avatarCornerRadius(compactList: false), 10)
        XCTAssertEqual(SessionListCompactMetrics.avatarCornerRadius(compactList: true), 8)
    }

    // ── 徽章与尾随按钮：间距 6→4，按钮 22→18 ────────────────────

    func testBadgeSpacingTightensUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.badgeSpacing(compactList: false), 6)
        XCTAssertEqual(SessionListCompactMetrics.badgeSpacing(compactList: true), 4)
    }

    func testTrailingStackSpacingTightensUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.trailingStackSpacing(compactList: false), 6)
        XCTAssertEqual(SessionListCompactMetrics.trailingStackSpacing(compactList: true), 3)
    }

    func testActionButtonEdgeShrinksUnderCompact() {
        XCTAssertEqual(SessionListCompactMetrics.actionButtonEdge(compactList: false), 22)
        XCTAssertEqual(SessionListCompactMetrics.actionButtonEdge(compactList: true), 18)
    }

    // ── 行高验收：紧凑 ≤ 40pt，且相对宽松版显著下降 ─────────────

    func testEstimatedRowHeightStaysWithinFortyPointsUnderCompact() {
        XCTAssertLessThanOrEqual(
            SessionListCompactMetrics.estimatedRowHeight(base: 13, compactList: true), 40
        )
    }

    func testEstimatedRowHeightImprovesByAtLeastTwentyPointsUnderCompact() {
        let relaxed = SessionListCompactMetrics.estimatedRowHeight(base: 13, compactList: false)
        let compact = SessionListCompactMetrics.estimatedRowHeight(base: 13, compactList: true)
        XCTAssertGreaterThan(relaxed, compact + 20)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: 子代理子行与头像角标（Task 17 · 字号跟随设置）
    //
    // SubagentAttachmentRow 原全写死（标题 12 / 详情 11 / 年龄 10 /
    // 徽章 7）；头像角标符号同样写死（wifi 7 / spinner 8）。统一改为
    // contentFontSize 派生后，base=13 必须与旧值零漂移，且随 base
    // 缩放、下限不塌缩。
    // ══════════════════════════════════════════════════════════════

    func testSubagentRowFontSizesMatchLegacyConstantsAtDefaultBase() {
        // base=13 与旧写死值完全一致：标题 12 / 详情 11 / 年龄 10 / 徽章 7
        XCTAssertEqual(SessionListCompactMetrics.subagentTitleFontSize(base: 13), 12)
        XCTAssertEqual(SessionListCompactMetrics.subagentDetailFontSize(base: 13), 11)
        XCTAssertEqual(SessionListCompactMetrics.subagentAgeFontSize(base: 13), 10)
        XCTAssertEqual(SessionListCompactMetrics.subagentBadgeFontSize(base: 13), 7, accuracy: 0.01)
    }

    func testSubagentRowFontSizesFollowBaseChanges() {
        // base=15：标题 14 / 详情 13 / 年龄 12 / 徽章 ≈8.08（随设置缩放）
        XCTAssertEqual(SessionListCompactMetrics.subagentTitleFontSize(base: 15), 14)
        XCTAssertEqual(SessionListCompactMetrics.subagentDetailFontSize(base: 15), 13)
        XCTAssertEqual(SessionListCompactMetrics.subagentAgeFontSize(base: 15), 12)
        XCTAssertEqual(SessionListCompactMetrics.subagentBadgeFontSize(base: 15), 7 * 15 / 13, accuracy: 0.01)
    }

    func testSubagentRowFontSizesRespectBoundsAtMinimumBase() {
        // base=11（contentFontSize 下限）：标题≥10 / 详情≥9 / 年龄≥8 / 徽章≥5
        XCTAssertGreaterThanOrEqual(SessionListCompactMetrics.subagentTitleFontSize(base: 11), 10)
        XCTAssertGreaterThanOrEqual(SessionListCompactMetrics.subagentDetailFontSize(base: 11), 9)
        XCTAssertGreaterThanOrEqual(SessionListCompactMetrics.subagentAgeFontSize(base: 11), 8)
        XCTAssertGreaterThanOrEqual(SessionListCompactMetrics.subagentBadgeFontSize(base: 11), 5)
    }

    func testAvatarBadgeSymbolFontSizeZeroDriftAtDefaultBase() {
        // base=13 与旧写死值一致：wifi 7 / spinner 8
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 13, original: 7), 7, accuracy: 0.01)
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 13, original: 8), 8, accuracy: 0.01)
    }

    func testAvatarBadgeSymbolFontSizeScalesWithinBounds() {
        // base=17 封顶 original+2 / base=11 兜底 original-1（不溢出 14×14 圆）
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 17, original: 7), 9, accuracy: 0.01)
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 17, original: 8), 10, accuracy: 0.01)
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 11, original: 7), 6, accuracy: 0.01)
        XCTAssertEqual(SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: 11, original: 8), 7, accuracy: 0.01)
    }

    func testEstimatedSubagentRowHeightMatchesRenderModel() {
        // 模型 = vertical padding 6×2 + 标题×1.25 + 间距 2 + 详情×1.25
        // base=13 → 12+15+2+13.75 = 42.75；base=15 → 12+17.5+2+16.25 = 47.75
        XCTAssertEqual(SessionListCompactMetrics.estimatedSubagentRowHeight(base: 13), 42.75, accuracy: 0.01)
        XCTAssertEqual(SessionListCompactMetrics.estimatedSubagentRowHeight(base: 15), 47.75, accuracy: 0.01)
    }
}
