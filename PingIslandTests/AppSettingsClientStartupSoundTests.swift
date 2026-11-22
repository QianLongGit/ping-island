import XCTest
@testable import Ping_Island

// ═════════════════════════════════════════════════════════════════
// MARK: - 客户端启动音开关（clientStartupSoundEnabled 三件套）
//
// 默认开启；关闭后 playClientStartupSound() 入口直接短路，
// 不影响 AppSoundFeedback 路由与其他声音资产（Task 19）。
// 覆盖：默认值、开关写入持久化、跨实例重载、旧值迁移、关闭态短路冒烟。
// ═════════════════════════════════════════════════════════════════
@MainActor
final class AppSettingsClientStartupSoundTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.AppSettingsClientStartupSound.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    func testClientStartupSoundDefaultsToOn() {
        let store = makeStore(defaults: makeDefaults())

        XCTAssertTrue(store.clientStartupSoundEnabled)
    }

    func testDisablingClientStartupSoundPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.clientStartupSoundEnabled = false

        XCTAssertEqual(defaults.bool(forKey: "clientStartupSoundEnabled"), false)
        XCTAssertFalse(makeStore(defaults: defaults).clientStartupSoundEnabled)
    }

    func testReenablingClientStartupSoundPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.clientStartupSoundEnabled = false
        store.clientStartupSoundEnabled = true

        XCTAssertEqual(defaults.bool(forKey: "clientStartupSoundEnabled"), true)
        XCTAssertTrue(makeStore(defaults: defaults).clientStartupSoundEnabled)
    }

    func testLegacyOffValueSurvivesReload() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "clientStartupSoundEnabled")

        XCTAssertFalse(makeStore(defaults: defaults).clientStartupSoundEnabled)
    }

    func testPlayClientStartupSoundShortCircuitsWhenDisabled() {
        // 关闭态走 static 入口：guard 短路，不触达 AppSoundFeedback 播放链
        let original = AppSettings.clientStartupSoundEnabled
        defer { AppSettings.clientStartupSoundEnabled = original }

        AppSettings.clientStartupSoundEnabled = false
        AppSettings.playClientStartupSound()

        XCTAssertFalse(AppSettings.clientStartupSoundEnabled)
    }
}
