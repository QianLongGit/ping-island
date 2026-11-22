import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 紧凑会话列表开关（compactSessionList 三件套）
//
// 默认开启；关闭后行高/字号/头像完全回到旧版宽松样式。
// 覆盖：默认值、开关写入持久化、跨实例重载、旧值迁移。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class AppSettingsCompactSessionListTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.AppSettingsCompactSessionList.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    func testCompactSessionListDefaultsToOn() {
        let store = makeStore(defaults: makeDefaults())

        XCTAssertTrue(store.compactSessionList)
    }

    func testDisablingCompactSessionListPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactSessionList = false

        XCTAssertEqual(defaults.bool(forKey: "compactSessionList"), false)
        XCTAssertFalse(makeStore(defaults: defaults).compactSessionList)
    }

    func testReenablingCompactSessionListPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactSessionList = false
        store.compactSessionList = true

        XCTAssertEqual(defaults.bool(forKey: "compactSessionList"), true)
        XCTAssertTrue(makeStore(defaults: defaults).compactSessionList)
    }

    func testLegacyOffValueSurvivesReload() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "compactSessionList")

        XCTAssertFalse(makeStore(defaults: defaults).compactSessionList)
    }

    func testLegacyOnValueSurvivesReload() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "compactSessionList")

        XCTAssertTrue(makeStore(defaults: defaults).compactSessionList)
    }
}
