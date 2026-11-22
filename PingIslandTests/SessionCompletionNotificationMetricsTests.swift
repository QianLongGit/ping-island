import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 通知面板布局度量一致性（SessionCompletionNotificationView）
//
// 完成通知卡片在紧凑会话列表开启时字号/间距必须取自
// SessionListCompactMetrics 表（紧凑开=紧凑、关=原样），与主列表
// 视觉密度保持一致；此处以 static 纯函数断言表驱动一致性。
// ═════════════════════════════════════════════════════════════════
final class SessionCompletionNotificationMetricsTests: XCTestCase {

    func testBodyFontSizeCompactTakesDetailFontSizeFromMetricsTable() {
        // 紧凑正文 = detailFontSize(base: 13) = max(10, 11) = 11（T20 统一）
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsBodyFontSize(base: 13, compactList: true),
            SessionListCompactMetrics.detailFontSize(base: 13),
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsBodyFontSize(base: 13, compactList: true),
            11,
            accuracy: 0.01
        )
    }

    func testBodyFontSizeRelaxedKeepsLegacyValue() {
        // 宽松正文保持旧值 max(12, base) = 13
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsBodyFontSize(base: 13, compactList: false),
            13,
            accuracy: 0.01
        )
    }

    func testLabelFontSizeCompactTakesSessionTitleFontSizeFromMetricsTable() {
        // 紧凑标签 = sessionTitleFontSize(base: 13) = max(14, 15) = 15（T20 统一）
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 13, compactList: true),
            SessionListCompactMetrics.sessionTitleFontSize(base: 13),
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 13, compactList: true),
            15,
            accuracy: 0.01
        )
    }

    func testLabelFontSizeRelaxedKeepsLegacyValue() {
        // 宽松标签 = max(13, base)，base=13 保持旧值 13
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 13, compactList: false),
            13,
            accuracy: 0.01
        )
    }

    /// Task 17：标签字号必须跟随 contentFontSize（移除写死 base 13）
    func testLabelFontSizeFollowsContentFontSize() {
        // 紧凑 base=17 → sessionTitleFontSize = max(14, 19) = 19（T20 统一）
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 17, compactList: true),
            19,
            accuracy: 0.01
        )
        // 宽松 base=17 → max(13, 17) = 17
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 17, compactList: false),
            17,
            accuracy: 0.01
        )
        // 紧凑 base=11 → max(14, 13) = 14（下限抬到 14，与预览行同源）
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(base: 11, compactList: true),
            14,
            accuracy: 0.01
        )
    }

    func testSectionPaddingCompactTightensBothAxes() {
        // 紧凑内距收紧：垂直 14→9、水平 16→12
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsSectionVerticalPadding(compactList: true),
            9,
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsSectionVerticalPadding(compactList: false),
            14,
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsSectionHorizontalPadding(compactList: true),
            12,
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsSectionHorizontalPadding(compactList: false),
            16,
            accuracy: 0.01
        )
    }
}
