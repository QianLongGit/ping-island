import XCTest
@testable import Ping_Island

final class TerminalAppRegistryTests: XCTestCase {
    func testChatGPTAndLegacyCodexProcessNamesRemainRecognized() {
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/Codex.app/Contents/MacOS/Codex"))
        XCTAssertNil(TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "ChatGPT"))
    }

    func testQoderIDEProcessNamesKeepLegacyAliases() {
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/Qoder IDE.app/Contents/MacOS/Qoder"))
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/Qoder CN.app/Contents/MacOS/Qoder CN"))
    }

    func testDoesNotInferCodexProgramAsTerminalHostBundle() {
        XCTAssertNil(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "codex")
        )
        XCTAssertNil(
            TerminalAppRegistry.canonicalDisplayName(
                bundleIdentifier: nil,
                program: "codex"
            )
        )
    }

    func testLegacyCodexBundleResolvesChatGPTDisplayName() {
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(
                bundleIdentifier: "com.openai.codex",
                program: nil
            ),
            "ChatGPT"
        )
    }

    func testInfersITermBundleIdentifierFromHelperCommand() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(
                forCommand: "/Users/example/Library/Application Support/iTerm2/iTermServer-3.6.9 socket"
            ),
            "com.googlecode.iterm2"
        )
    }

    func testQoderCNDesktopIsRegisteredAsIDEHost() {
        XCTAssertTrue(TerminalAppRegistry.isIDEBundle("com.aliyun.lingma.ide"))
        XCTAssertEqual(
            TerminalAppRegistry.normalizedHostBundleIdentifier(for: "com.aliyun.lingma.ide.helper"),
            "com.aliyun.lingma.ide"
        )
    }

    // ============================================================ //
    //  kero 注册（Task 2）：terminalProgram=="kero" 约定 + 双 bundle 变体
    //  - "sh.kero"     release 构建
    //  - "sh.kero.dev" dev 构建（.dev 后缀保真）
    //  约定来源：hook 侧 KERO_PANE 非空 → terminalProgram=="kero"
    // ============================================================ //

    func testKeroProgramInfersReleaseBundleIdentifier() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "kero"),
            "sh.kero"
        )
        // 大小写归一化防御（mapper 输出恒小写，此处验证归一入口）
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "KERO"),
            "sh.kero"
        )
    }

    func testKeroBundleVariantsAreRegisteredTerminals() {
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("sh.kero"))
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("sh.kero.dev"))
    }

    func testKeroBundleVariantsResolveDisplayNames() {
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(bundleIdentifier: "sh.kero", program: nil),
            "kero"
        )
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(bundleIdentifier: "sh.kero.dev", program: nil),
            "kero (dev)"
        )
    }

    func testKeroDaemonCommandIsRecognizedAsTerminalHost() {
        // ProcessTreeBuilder 沿父链用 isTerminal(command) 找终端宿主，
        // kero daemon 主进程命令须命中 appNames 匹配
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/kero.app/Contents/MacOS/kero"))
    }

    func testGhosttyProgramInferenceDoesNotRegress() {
        // kero 内嵌 libghostty-vt 导致 TERM_PROGRAM=ghostty 与真 Ghostty 撞识别，
        // 但 ghostty 自身的推断行为必须保持不变
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "ghostty"),
            "com.mitchellh.ghostty"
        )
    }

    // ============================================================ //
    //  Warp 注册锁定（终端扩充 Task N2a）
    //  - 存量条目防回归：registry 四表在 N2a 前已有完整 Warp 条目
    //  - bundle id 形态：dev.warp.Warp-Stable（混合大小写，与
    //    open-vibe-island 参照实现/`open -b` 调用一致）
    //  - displayNames 表 key 为全小写形态（canonicalDisplayName
    //    查询前先 lowercased，非笔误）
    // ============================================================ //

    func testWarpProgramVariantsInferWarpStableBundle() {
        // TERM_PROGRAM 真实形态 WarpTerminal + 小写防御形态
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "WarpTerminal"),
            "dev.warp.Warp-Stable"
        )
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "warp"),
            "dev.warp.Warp-Stable"
        )
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "warpterminal"),
            "dev.warp.Warp-Stable"
        )
    }

    func testWarpBundleIdentifierIsRegisteredTerminal() {
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("dev.warp.Warp-Stable"))
        // 大小写归一化入口（NSRunningApplication 实际报小写形态时同样命中）
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("dev.warp.warp-stable"))
    }

    func testWarpBundleResolvesDisplayName() {
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(bundleIdentifier: "dev.warp.Warp-Stable", program: nil),
            "Warp"
        )
    }

    func testWarpProcessIsRecognizedAsTerminalHost() {
        // ProcessTreeBuilder 沿父链用 isTerminal(command) 找终端宿主
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/Warp.app/Contents/MacOS/warp"))
    }

    func testKeroProgramIsClassifiedAsCLIAtHookMirrorPoint() {
        // HookSocketServer.inferredCodexClientKind 镜像点：program=="kero"
        // 须命中 hasTerminalContext（推断 bundle 为 sh.kero 而非误落 ghostty/nil）
        XCTAssertEqual(
            HookSocketServer.inferredCodexClientKind(
                explicitKind: nil,
                explicitName: nil,
                explicitBundleID: nil,
                hasExplicitNonTerminalBundle: false,
                terminalTTY: nil,
                terminalProgram: "kero",
                terminalBundleID: nil,
                ideBundleID: nil,
                matchedProfileKind: nil
            ),
            .codexCLI
        )
    }

    // ============================================================ //
    //  Kaku 注册（Task N1）：WezTerm 家族终端（tw93 fork）
    //  - "fun.tw93.kaku" 唯一 bundle（无 dev 变体）
    //  约定来源：TERM_PROGRAM 报 "kaku"（fork 后自定义值）
    // ============================================================ //

    func testKakuProgramInfersBundleIdentifier() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "kaku"),
            "fun.tw93.kaku"
        )
        // 大小写归一化防御（推断入口统一 lowercased）
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "KAKU"),
            "fun.tw93.kaku"
        )
    }

    func testKakuBundleIsRegisteredTerminal() {
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("fun.tw93.kaku"))
    }

    func testKakuBundleResolvesDisplayName() {
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(bundleIdentifier: "fun.tw93.kaku", program: nil),
            "Kaku"
        )
    }

    func testKakuAppPathIsRecognizedAsTerminalHost() {
        // ProcessTreeBuilder 沿父链用 isTerminal(command) 找终端宿主
        XCTAssertTrue(TerminalAppRegistry.isTerminal("/Applications/Kaku.app/Contents/MacOS/Kaku"))
    }

    func testWezTermRegistryEntriesRemainIntact() {
        // Kaku 落位不得影响 WezTerm 既有四表条目
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "wezterm"),
            "com.github.wez.wezterm"
        )
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "wezterm-gui"),
            "com.github.wez.wezterm"
        )
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("com.github.wez.wezterm"))
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(bundleIdentifier: "com.github.wez.wezterm", program: nil),
            "WezTerm"
        )
    }
}
