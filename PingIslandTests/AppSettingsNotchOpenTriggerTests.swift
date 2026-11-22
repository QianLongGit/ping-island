import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 面板打开方式开关（notchOpenTrigger 三件套）
//
// hover=默认：鼠标移入刘海短暂停留自动展开；click：仅点击展开，
// 移入只保留视觉反馈。覆盖：默认值、切换持久化、跨实例重载、
// 旧值迁移与未知值兜底。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class AppSettingsNotchOpenTriggerTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.AppSettingsNotchOpenTrigger.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    func testNotchOpenTriggerDefaultsToHover() {
        let store = makeStore(defaults: makeDefaults())

        XCTAssertEqual(store.notchOpenTrigger, .hover)
    }

    func testSwitchingToClickPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.notchOpenTrigger = .click

        XCTAssertEqual(defaults.string(forKey: "notchOpenTrigger"), "click")
        XCTAssertEqual(makeStore(defaults: defaults).notchOpenTrigger, .click)
    }

    func testSwitchingBackToHoverPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.notchOpenTrigger = .click
        store.notchOpenTrigger = .hover

        XCTAssertEqual(defaults.string(forKey: "notchOpenTrigger"), "hover")
        XCTAssertEqual(makeStore(defaults: defaults).notchOpenTrigger, .hover)
    }

    func testLegacyHoverValueSurvivesReload() {
        let defaults = makeDefaults()
        defaults.set("hover", forKey: "notchOpenTrigger")

        XCTAssertEqual(makeStore(defaults: defaults).notchOpenTrigger, .hover)
    }

    func testLegacyClickValueSurvivesReload() {
        let defaults = makeDefaults()
        defaults.set("click", forKey: "notchOpenTrigger")

        XCTAssertEqual(makeStore(defaults: defaults).notchOpenTrigger, .click)
    }

    func testUnknownValueFallsBackToHover() {
        let defaults = makeDefaults()
        defaults.set("bogus", forKey: "notchOpenTrigger")

        XCTAssertEqual(makeStore(defaults: defaults).notchOpenTrigger, .hover)
    }
}
