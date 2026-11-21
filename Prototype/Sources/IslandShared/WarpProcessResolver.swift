import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// ═══════════════════════════════════════════════════════════════
// WarpProcessResolver —— 沿调用进程祖先链定位宿主 Warp pane
// （终端扩充 Task N2a；参照 open-vibe-island 同名实现移植）
//
// 核心观察：Warp 为每个 pane 生成一个 shell 子进程，均是其
// `terminal-server` 进程的直接子进程。从该 shell 的任意后代
// （如在 `claude` 进程内运行的 bridge hook 进程）沿 `getppid`
// 向上爬，终会遇到一个父进程是 terminal-server 的进程——该
// 进程的 pid 即可唯一标识 pane，即使两个兄弟 pane 共享同一
// 工作目录。
//
// 这正是区分共享相同 `terminal_panes.cwd` 的兄弟 tab 的手段——
// Warp 的 SQLite 自身无法解决（不存 per-pane PID 或 TTY）。
//
// ▸ 纯逻辑与进程枚举分离：providers 可注入，测试无需真实
//   进程树
// ▸ 任何一环失败（进程退出/链断/非 Warp）静默返回 nil
// ═══════════════════════════════════════════════════════════════

public enum WarpProcessResolver {

    /// 经宿主 shell 进程链标识一个具体 Warp pane。
    public struct PaneContext: Sendable, Equatable {
        /// `terminalServerPID` 的直接子 shell 的 PID。运行中的
        /// Warp 实例内每个 pane 唯一。
        public let shellPID: pid_t
        /// `stable terminal-server` 助手进程的 PID。Warp 运行期
        /// 间稳定。
        public let terminalServerPID: pid_t

        public init(shellPID: pid_t, terminalServerPID: pid_t) {
            self.shellPID = shellPID
            self.terminalServerPID = terminalServerPID
        }
    }

    /// 解析调用进程（通常为 Warp shell 的 Claude/Codex 子进程内
    /// 运行的 bridge hook 进程）的 pane 上下文。调用进程不是
    /// Warp terminal-server 的后代时（如 Ghostty / Terminal.app
    /// 环境）返回 nil。
    public static func resolveCurrentPaneContext() -> PaneContext? {
        resolveCurrentPaneContext(
            parentPIDProvider: defaultParentPIDProvider,
            commandProvider: defaultCommandProvider
        )
    }

    /// 接受注入 providers 的可测变体。生产调用方用零参版本。
    public static func resolveCurrentPaneContext(
        parentPIDProvider: (pid_t) -> pid_t?,
        commandProvider: (pid_t) -> String?
    ) -> PaneContext? {
        resolvePaneContext(
            startingFrom: getppid(),
            parentPIDProvider: parentPIDProvider,
            commandProvider: commandProvider
        )
    }

    /// 内部爬链器。从 `startingFrom` 沿父链上行，直到找到父进程
    /// 是 Warp terminal-server 的进程，或触及深度上限。
    ///
    /// 深度上限（16）足以覆盖现实嵌套（bridge hook → claude →
    /// zsh → 可选包装层 → Warp shell），同时防止坏 ps 链死循环。
    static func resolvePaneContext(
        startingFrom initial: pid_t,
        parentPIDProvider: (pid_t) -> pid_t?,
        commandProvider: (pid_t) -> String?
    ) -> PaneContext? {
        var current = initial
        for _ in 0..<16 {
            guard current > 1 else { return nil }
            guard let parent = parentPIDProvider(current), parent > 1 else {
                return nil
            }
            if let parentCommand = commandProvider(parent),
               isWarpTerminalServer(command: parentCommand) {
                return PaneContext(shellPID: current, terminalServerPID: parent)
            }
            current = parent
        }
        return nil
    }

    /// `command` 是否形如 Warp `terminal-server` 助手的调用。
    /// Warp Stable 与 Preview 均命中——两者的 binary 都在
    /// `/Warp.app/` 下且 argv 行带 `terminal-server` 子命令。
    static func isWarpTerminalServer(command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("/warp.app/") && lower.contains("terminal-server")
    }

    // MARK: - 默认 providers（生产）

    static let defaultParentPIDProvider: @Sendable (pid_t) -> pid_t? = { pid in
        guard let output = runSubprocess(
            executable: "/bin/ps",
            arguments: ["-o", "ppid=", "-p", "\(pid)"]
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(trimmed)
    }

    static let defaultCommandProvider: @Sendable (pid_t) -> String? = { pid in
        guard let output = runSubprocess(
            executable: "/bin/ps",
            arguments: ["-o", "command=", "-p", "\(pid)"]
        ) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runSubprocess(executable: String, arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
