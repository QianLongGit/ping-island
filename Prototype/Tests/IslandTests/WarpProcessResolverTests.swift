import Foundation
@testable import IslandShared
import Testing

// ─────────────────────────────────────────────────────────────────
// Warp 进程爬链解析（Task N2a）
//
// Warp 每个 pane 的 shell 是其 terminal-server 的直接子进程；
// 从 hook 进程沿 getppid 向上爬，遇到父进程是 Warp
// terminal-server 即锁定 (shellPID, terminalServerPID) 对。
// 全部以注入 provider 测试纯逻辑，不依赖真实进程树。
// ─────────────────────────────────────────────────────────────────

// ── 测试辅助：用字典模拟进程表 ──────────────────────────────────

private func makeProviders(
    parentOf: [pid_t: pid_t],
    commandOf: [pid_t: String]
) -> (parent: (pid_t) -> pid_t?, command: (pid_t) -> String?) {
    (
        { pid in parentOf[pid] },
        { pid in commandOf[pid] }
    )
}

private let warpServerCommand =
    "/Applications/Warp.app/Contents/MacOS/warp terminal-server"

// ─────────────────────────────────────────────────────────────────
// 爬链命中：祖先链中出现 Warp terminal-server
// ─────────────────────────────────────────────────────────────────

@Test
func testResolveFindsWarpShellDirectlyUnderTerminalServer() {
    // 链：hook(700) → claude(701) → zsh(702) → terminal-server(703)
    // 爬到 702 时发现父 703 是 terminal-server → shell=702
    let providers = makeProviders(
        parentOf: [700: 701, 701: 702, 702: 703, 703: 1],
        commandOf: [703: warpServerCommand]
    )

    let context = WarpProcessResolver.resolvePaneContext(
        startingFrom: 700,
        parentPIDProvider: providers.parent,
        commandProvider: providers.command
    )

    #expect(context?.shellPID == 702)
    #expect(context?.terminalServerPID == 703)
}

@Test
func testResolveStartingAtShellItself() {
    // 起点即 shell：父直接就是 terminal-server
    let providers = makeProviders(
        parentOf: [800: 801],
        commandOf: [801: warpServerCommand]
    )

    let context = WarpProcessResolver.resolvePaneContext(
        startingFrom: 800,
        parentPIDProvider: providers.parent,
        commandProvider: providers.command
    )

    #expect(context?.shellPID == 800)
    #expect(context?.terminalServerPID == 801)
}

// ─────────────────────────────────────────────────────────────────
// 非 Warp 环境静默返回 nil（零副作用）
// ─────────────────────────────────────────────────────────────────

@Test
func testResolveReturnsNilForNonWarpAncestry() {
    // Ghostty/Terminal.app 祖先链：爬到根无 terminal-server
    let providers = makeProviders(
        parentOf: [900: 901, 901: 902, 902: 1],
        commandOf: [
            901: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            902: "/sbin/launchd",
        ]
    )

    let context = WarpProcessResolver.resolvePaneContext(
        startingFrom: 900,
        parentPIDProvider: providers.parent,
        commandProvider: providers.command
    )

    #expect(context == nil)
}

@Test
func testResolveReturnsNilWhenChainBreaks() {
    // 父链断裂（进程已退出，ps 无行）→ 静默 nil
    let providers = makeProviders(
        parentOf: [:],
        commandOf: [:]
    )

    let context = WarpProcessResolver.resolvePaneContext(
        startingFrom: 950,
        parentPIDProvider: providers.parent,
        commandProvider: providers.command
    )

    #expect(context == nil)
}

@Test
func testResolveReturnsNilOnDepthCapExhaustion() {
    // 无环无限链：深度 16 截断保护，不悬挂
    let providers = makeProviders(
        parentOf: [:],
        commandOf: [:]
    )
    let climbing: (pid_t) -> pid_t? = { pid in pid + 1 }

    let context = WarpProcessResolver.resolvePaneContext(
        startingFrom: 1_000,
        parentPIDProvider: climbing,
        commandProvider: providers.command
    )

    #expect(context == nil)
}

// ─────────────────────────────────────────────────────────────────
// terminal-server 判定：/Warp.app/ + terminal-server 双条件
// ─────────────────────────────────────────────────────────────────

@Test
func testIsWarpTerminalServerMatching() {
    // 完整命中
    #expect(WarpProcessResolver.isWarpTerminalServer(command: warpServerCommand))
    // 大小写不敏感（ps 输出形态差异防御）
    #expect(WarpProcessResolver.isWarpTerminalServer(
        command: "/Applications/warp.app/contents/macos/warp Terminal-Server"
    ))
    // Preview 渠道同样命中（binary 均在 /Warp.app/ 下）
    #expect(WarpProcessResolver.isWarpTerminalServer(
        command: "/Applications/Warp.app/Contents/MacOS/warp-preview terminal-server"
    ))
}

@Test
func testIsWarpTerminalServerRejectsNearMisses() {
    // 缺 terminal-server 子命令 → 非 server 进程
    #expect(!WarpProcessResolver.isWarpTerminalServer(
        command: "/Applications/Warp.app/Contents/MacOS/warp"
    ))
    // 非 Warp.app 路径的 terminal-server（防误中其他工具）
    #expect(!WarpProcessResolver.isWarpTerminalServer(
        command: "/usr/local/bin/other-terminal-server"
    ))
    // 空串
    #expect(!WarpProcessResolver.isWarpTerminalServer(command: ""))
}
