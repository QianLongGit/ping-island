import XCTest
@testable import Ping_Island

// ============================================================================
//  KERO_PANE 环境变量透传断言（kero-jump-integration Task 4）
//  ----------------------------------------------------------------------------
//  HookInstaller 的 ENV_KEYS 白名单在 4 处 hook 模板里各存一份副本：
//    1. OpenCode JS hook      — managedPluginSource(opencode-hooks)
//    2. Hermes Python 插件    — managedPluginDirectoryFiles(hermes-hooks)["__init__.py"]
//    3. Pi TS extension       — managedPluginDirectoryFiles(pi-hooks)["index.ts"]
//    4. OMP TS hook           — managedPluginSource(omp-hooks)
//  任一处遗漏都会让对应 hook 形态静默丢掉 KERO_PANE，bridge 侧 mapper
//  （Task 1）在真实链路将无法识别 kero 终端。本测试聚合断言 4 处副本
//  全部透传，防未来新增键时漏同步。
//
//  注：本文件在零构建机约束下编写（T2 独占构建机），机器执行留待
//  T3/T7 构建窗口（xcodebuild -only-testing:PingIslandTests）。
// ============================================================================

final class HookInstallerKeroPaneEnvTests: XCTestCase {
    func testAllHookTemplateEnvKeysIncludeKeroPane() throws {
        // -- 副本 1：OpenCode JS hook ------------------------------------
        let opencodeProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "opencode-hooks"))
        XCTAssertTrue(
            HookInstaller.managedPluginSource(for: opencodeProfile).contains("\"KERO_PANE\""),
            "OpenCode JS 模板 ENV_KEYS 应包含 KERO_PANE"
        )

        // -- 副本 2：Hermes Python 插件 ----------------------------------
        let hermesProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let hermesSource = try XCTUnwrap(
            HookInstaller.managedPluginDirectoryFiles(for: hermesProfile)["__init__.py"]
        )
        XCTAssertTrue(hermesSource.contains("\"KERO_PANE\""), "Hermes Python 模板 ENV_KEYS 应包含 KERO_PANE")

        // -- 副本 3：Pi TS extension -------------------------------------
        let piProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "pi-hooks"))
        let piSource = try XCTUnwrap(
            HookInstaller.managedPluginDirectoryFiles(for: piProfile)["index.ts"]
        )
        XCTAssertTrue(piSource.contains("\"KERO_PANE\""), "Pi extension 模板 ENV_KEYS 应包含 KERO_PANE")

        // -- 副本 4：OMP TS hook -----------------------------------------
        let ompProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "omp-hooks"))
        XCTAssertTrue(
            HookInstaller.managedPluginSource(for: ompProfile).contains("\"KERO_PANE\""),
            "OMP TS 模板 ENV_KEYS 应包含 KERO_PANE"
        )
    }
}
