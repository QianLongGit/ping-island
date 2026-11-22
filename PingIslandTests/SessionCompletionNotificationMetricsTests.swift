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
        // 紧凑正文 = detailFontSize(base: 13, compact) = max(9.5, 10.5) = 10.5
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsBodyFontSize(base: 13, compactList: true),
            SessionListCompactMetrics.detailFontSize(base: 13, compactList: true),
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsBodyFontSize(base: 13, compactList: true),
            10.5,
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
        // 紧凑标签 = sessionTitleFontSize(base: 13, compact) = max(11, 12) = 12
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(compactList: true),
            SessionListCompactMetrics.sessionTitleFontSize(base: 13, compactList: true),
            accuracy: 0.01
        )
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(compactList: true),
            12,
            accuracy: 0.01
        )
    }

    func testLabelFontSizeRelaxedKeepsLegacyValue() {
        // 宽松标签保持旧值 13
        XCTAssertEqual(
            SessionCompletionNotificationView.metricsLabelFontSize(compactList: false),
            13,
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
