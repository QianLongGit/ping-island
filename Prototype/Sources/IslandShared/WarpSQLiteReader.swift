import Foundation
import SQLite3

// ═══════════════════════════════════════════════════════════════
// WarpSQLiteReader —— Warp live SQLite 状态的只读访问层
// （终端扩充 Task N2a，数据层；参照 open-vibe-island 同名实现移植）
//
// ▸ 依赖 Warp 内部 schema，非 Warp 官方支持的 API
// ▸ 只读打开（READONLY + 60ms busy_timeout），Warp 运行中持锁
//   亦不阻塞调用方
// ▸ 一切查询失败静默降级：返回 nil/0，调用方回退原有非 Warp 行为
//   （无 Warp 安装环境零崩溃零副作用）
//
// 查询能力（按跳转链路分工）：
// ▸ lookupPaneUUID(forCwd:)               —— cwd 定位 pane（N2a 兜底）
// ▸ lookupPaneUUIDByShellPID(_:siblings:) —— 进程索引定位 pane（N2a 主路径）
// ▸ currentFocusedPaneUUID() / tabCountInActiveWindow() —— 焦点轮询（N2b）
// ═══════════════════════════════════════════════════════════════

public struct WarpSQLiteReader: Sendable {
    public let databasePath: String

    public init(databasePath: String = WarpSQLiteReader.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    /// Warp stable 渠道 SQLite 库的标准磁盘位置。
    /// Warp 被沙盒化，状态存于 Group Container 而非每 App 的
    /// Application Support。
    public static func defaultDatabasePath() -> String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    /// 解析承载 Claude/Codex agent 的 Warp pane UUID（运行于 `cwd`）。
    /// 返回大写十六进制串（32 字符无分隔符）；任何错误或无法定位时
    /// 返回 nil。
    ///
    /// 两级查找策略（按序尝试）：
    ///
    /// **主路径 —— `terminal_panes.cwd` 直接匹配。** 查询 Warp 每
    /// pane 的 cwd 列。当 Warp 的 shell 集成有机会更新该列时（shell
    /// 渲染 prompt 且 cwd 与初始启动 cwd 不同即触发）快速且精确。
    /// 输入 cwd 的两种 firmlink 形式都会尝试——Claude Code 经
    /// `getcwd()` 捕获的是解析后形态（`/private/tmp/foo`），而 Warp
    /// 通常存 shell 经 OSC 发来的未解析形态（`/tmp/foo`）。
    ///
    /// **回退 —— `commands → blocks` 交叉引用。** 主路径落空时，
    /// 在命令史中找文本包含 `cd <目标>`（两种 firmlink 形式，边界
    /// 约束防止 `/tmp/foo` 误命中 `/tmp/foo-extended`）的行，取其
    /// `session_id`，再连接 `precmd-<session_id>-*` 块取得 pane
    /// uuid。覆盖常见"复合命令"流：用户粘贴
    /// `mkdir -p /tmp/foo && cd /tmp/foo && claude` 单行——Warp 渲染
    /// 首 prompt（写入 `precmd-<session>-1` 并把 shell session 关联
    /// 到 pane uuid）后 claude 的 TUI 抢占 TTY，第二个 prompt 不再
    /// 渲染，terminal_panes.cwd 停留在初始 `/Users/u`；commands 表
    /// 仍留有完整粘贴文本，靠匹配 `cd /tmp/foo` 恢复映射。
    ///
    /// 已知限制：
    /// - 回退中的子串碰撞以 shell 分隔符（空格 / `;` / `&` / `|`）
    ///   或命令结尾为界缓解；异形分隔符（纯换行、尾斜杠路径归一）
    ///   不处理。
    /// - 两个 Warp tab 在任一表共享同一 cwd 时，最新创建的行
    ///   （`id DESC`）胜出。仅凭 SQLite 无法进一步区分同 cwd pane，
    ///   因为 Warp 不暴露 per-pane PID 或 TTY。
    /// - 路径含 SQLite GLOB 元字符（`*` `?` `[` `]`）时回退静默
    ///   落空——实践中极罕见，主路径仍能正确处理。
    public func lookupPaneUUID(forCwd cwd: String) -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        if let uuid = lookupViaTerminalPanesCwd(db: db, cwd: cwd) {
            return uuid
        }
        if let uuid = lookupViaCommandsHistory(db: db, cwd: cwd) {
            return uuid
        }
        return nil
    }

    private func lookupViaTerminalPanesCwd(db: OpaquePointer, cwd: String) -> String? {
        let candidates = Self.cwdLookupCandidates(for: cwd)

        let sql = """
        SELECT hex(uuid)
        FROM terminal_panes
        WHERE cwd IN (\(Array(repeating: "?", count: candidates.count).joined(separator: ", ")))
        ORDER BY id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var heldCStrings: [UnsafeMutablePointer<CChar>?] = []
        defer { heldCStrings.forEach { free($0) } }

        for (index, candidate) in candidates.enumerated() {
            let cString = candidate.withCString { strdup($0) }
            heldCStrings.append(cString)
            sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    private func lookupViaCommandsHistory(db: OpaquePointer, cwd: String) -> String? {
        let candidates = Self.cwdLookupCandidates(for: cwd)

        // 任一候选含 GLOB 元字符则整体跳过回退——安全转义此类
        // 实践中几乎不用的路径，代价超过回退本身的价值。
        if candidates.contains(where: { path in path.contains(where: { "*?[".contains($0) }) }) {
            return nil
        }

        // 每候选两个 GLOB 模式：
        //   1. `*cd <path>[ ;&|]*` —— `cd <path>` 后跟 shell 分隔符
        //      （标准场景，如 `cd /tmp/foo && claude`）
        //   2. `*cd <path>`       —— `cd <path>` 恰在命令串末尾
        // 字符类 `[ ;&|]` 防子串碰撞：查 `/tmp/foo` 不会命中含
        // `cd /tmp/foo-extended` 的命令，因为 `foo` 后是 `-`
        // 而非分隔符。
        var globPatterns: [String] = []
        for candidate in candidates {
            globPatterns.append("*cd \(candidate)[ ;&|]*")
            globPatterns.append("*cd \(candidate)")
        }

        let whereClause = Array(repeating: "c.command GLOB ?", count: globPatterns.count)
            .joined(separator: " OR ")

        // 连接链经命令史关联定位 Warp pane，结构上兼容"shell 在
        // claude 抢占 TTY 前从未渲染 prompt、Warp 未为该 shell 写过
        // 任何 `precmd-<session>-*` 块"的场景——仅靠块关联会在该
        // 场景失败。技巧是经 `commands.pwd`（命令执行时刻 shell 的
        // cwd，新开 tab 中复合命令的 pwd 等于 pane 继承的初始 cwd）
        // 关联到 `terminal_panes.cwd`（shell 未 OSC 新 cwd 时保持
        // 继承值）。
        //
        // 三个排序信号区分多 pane 共享同一初始 cwd 的场景（常见：
        // Warp 新开 tab 继承前一聚焦 tab 的 cwd，两个兄弟 tab 同起
        // 于 /tmp/foo 时 terminal_panes 里两行 cwd 相同）：
        //
        // 1. `has_matching_block DESC` —— 优先已被 precmd 块关联到
        //    命令自身 shell session 的 pane。块存在时 pane 归属已
        //    定论，必取。
        // 2. WHERE 中 `NOT EXISTS (... foreign block ...)` —— 排除
        //    已被其他 shell session 经 precmd 块"认领"的 pane。无
        //    此过滤时查 test-c 会返回 test-b 的 pane（共享过期
        //    cwd 且 test-b pane id 更大）。test-b 明显错误——它的
        //    块关联 test-b 的 session_id 而非 test-c 的。
        // 3. `c.id DESC, tp.id DESC` —— 最新命令、最新 pane 胜出，
        //    前两个信号都无法区分时的决胜规则。
        //
        // 与 `terminal_panes` 的外 JOIN 同样关键：用户关 tab 时
        // Warp 修剪 terminal_panes 行但保留 commands/blocks 史。
        // 真实库中孤儿 blocks 与存活 pane 的比例约 1000:1。JOIN
        // 把结果约束在当前存活 pane 内，落空时干净降级为"无精确
        // pane 映射"而非追幽灵 uuid。
        let sql = """
        SELECT hex(tp.uuid)
        FROM commands c
        JOIN terminal_panes tp ON tp.cwd = c.pwd
        LEFT JOIN blocks b_match
            ON b_match.pane_leaf_uuid = tp.uuid
            AND b_match.block_id GLOB 'precmd-' || c.session_id || '-*'
        WHERE (\(whereClause))
          AND NOT EXISTS (
              SELECT 1 FROM blocks b_foreign
              WHERE b_foreign.pane_leaf_uuid = tp.uuid
                AND b_foreign.block_id GLOB 'precmd-*-*'
                AND b_foreign.block_id NOT GLOB 'precmd-' || c.session_id || '-*'
          )
        ORDER BY (b_match.id IS NOT NULL) DESC,
                 c.id DESC,
                 tp.id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var heldCStrings: [UnsafeMutablePointer<CChar>?] = []
        defer { heldCStrings.forEach { free($0) } }

        for (index, pattern) in globPatterns.enumerated() {
            let cString = pattern.withCString { strdup($0) }
            heldCStrings.append(cString)
            sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// 生成用于查询 Warp SQLite 的等价 cwd 字符串集合。macOS
    /// firmlink `/tmp` → `/private/tmp`（`/var` → `/private/var`），
    /// 同一目录有两种合法字符串形态。恒返回输入原值，适当时附上
    /// firmlink 翻转的孪生形态。
    static func cwdLookupCandidates(for cwd: String) -> [String] {
        var result: [String] = [cwd]
        if cwd.hasPrefix("/private/tmp/") || cwd == "/private/tmp" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/tmp/") || cwd == "/tmp" {
            result.append("/private" + cwd)
        } else if cwd.hasPrefix("/private/var/") || cwd == "/private/var" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/var/") || cwd == "/var" {
            result.append("/private" + cwd)
        }
        return result
    }

    /// 按 shell 进程在其 `terminal-server` 子进程列表中的位置解析
    /// 其所属 Warp pane 的 UUID。
    ///
    /// Warp 为每个 pane 生成一个 shell 子进程，均为其
    /// `terminal-server` 助手的直接子进程。shell 子进程与
    /// `terminal_panes` 行按同一顺序成对创建（每次"开新 tab"一对），
    /// 故 shell 在 terminal-server 子进程中的序号等于对应 pane 在
    /// `tabs` 按 `tab_id ASC` 连接后的序号。即使两个 pane 共享同一
    /// `cwd`——恰是 cwd 查询失效处——该关联也足以锁定正确 pane。
    ///
    /// 此方法刻意保持*纯函数*：接受 siblings 列表而非自行枚举，
    /// 令测试无需 spawn 子进程即可钉死索引逻辑。生产包装
    /// `lookupPaneUUIDByShellPID(_:terminalServerPID:)` 经 `pgrep`
    /// 完成枚举。
    ///
    /// `shellPID` 不在 `siblings` 内、索引超出 tab 列表范围、解析
    /// 出的 pane 位于后台 Warp 窗口（`jumpToWarpPane` 循环不可达）、
    /// 或任何 SQLite 错误时返回 nil。
    public func lookupPaneUUIDByShellPID(
        _ shellPID: pid_t,
        siblings: [pid_t]
    ) -> String? {
        let sorted = siblings.sorted()
        guard let index = sorted.firstIndex(of: shellPID) else {
            return nil
        }

        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        // 跨全部窗口按 tab_id 序枚举存活 leaf pane。在 SQL 内按窗
        // 口过滤会破坏索引算术——pid 关联建立在 shell 子进程的全局
        // 创建序列上，shell 顺序匹配全局 tab_id 序而非单窗内序。
        // 因此取行时一并拉出 `window_id`，pane 落在后台窗口时在
        // Swift 侧拒绝——`jumpToWarpPane` 只在前台窗口内循环切
        // tab，其他窗口的 pane uuid 永远等不到
        // `currentFocusedPaneUUID()` 匹配，循环会空转到超时。
        let sql = """
        SELECT hex(tp.uuid), t.window_id
        FROM tabs t
        JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        JOIN terminal_panes tp ON tp.id = pn.id
        ORDER BY t.id ASC
        LIMIT 1 OFFSET ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(index))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        let uuid = String(cString: cString)
        let paneWindowID = sqlite3_column_int64(stmt, 1)

        // 拒绝非活动窗口的 pane。完全无法确定活动窗口时（Warp 瞬
        // 态下 `app.active_window_id` 为 NULL、tabs 表又为空）尽最
        // 大努力接受任意窗口——单窗口场景下该行显然可达，拒绝反而
        // 破坏正确行为。
        if let activeWindowID = fetchActiveWindowID(db: db), activeWindowID != paneWindowID {
            return nil
        }
        return uuid
    }

    /// 读取 Warp 当前"活动窗口"指针。
    ///
    /// 主来源：`app.active_window_id`。Warp 瞬态下常留 NULL，此时
    /// 回退到 tabs 的 `MIN(window_id)`——压倒性常见的单窗口场景
    /// 中它就是唯一窗口。两者都无可用值时返回 nil，调用方应跳过
    /// 活动窗过滤而非全拒。
    private func fetchActiveWindowID(db: OpaquePointer) -> Int64? {
        if let value = fetchSingleInt64(db: db, sql: "SELECT active_window_id FROM app LIMIT 1") {
            return value
        }
        return fetchSingleInt64(db: db, sql: "SELECT MIN(window_id) FROM tabs")
    }

    /// 执行预期返回单整数列单行的 SQL。无行或列为 NULL 时返回
    /// nil——如何解读缺席由调用方决定。
    private func fetchSingleInt64(db: OpaquePointer, sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// 生产包装：经 `pgrep -P <terminalServerPID>` 枚举
    /// terminal-server 的子进程，再委托纯函数变体。
    ///
    /// 与纯函数变体分离，令测试无需 spawn 子进程即可钉死
    /// pid → index 关联逻辑。
    public func lookupPaneUUIDByShellPID(
        _ shellPID: pid_t,
        terminalServerPID: pid_t
    ) -> String? {
        guard let siblings = Self.enumerateChildPIDs(of: terminalServerPID) else {
            return nil
        }
        return lookupPaneUUIDByShellPID(shellPID, siblings: siblings)
    }

    /// spawn `/usr/bin/pgrep -P <pid>` 枚举给定 pid 的直接子进程。
    /// 任何错误返回 nil。pgrep 退出码 1（无子进程）返回空数组——
    /// 合法结果而非错误。
    static func enumerateChildPIDs(of pid: pid_t) -> [pid_t]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        // pgrep：0 = 有匹配，1 = 无匹配（非错误），2+ = 真错误
        guard task.terminationStatus == 0 || task.terminationStatus == 1 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 解析当前活动 Warp 窗口中当前聚焦 pane 的 UUID——精确跳转
    /// 期间轮询循环的驱动信号。
    ///
    /// 返回可直接与 `lookupPaneUUID` 输出比较大写十六进制串。
    /// 任何错误或无活动窗口时返回 nil。
    public func currentFocusedPaneUUID() -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        // 解析分三个显式 SQL 步骤而非单条嵌套查询。动机：真机上
        // `app.active_window_id` 在 Warp 瞬态频繁为 NULL，旧的嵌套
        // 形式 `LIMIT 1 OFFSET (SELECT ... WHERE id = (SELECT
        // active_window_id ...))` 会把 NULL 传播进 OFFSET 表达式，
        // 抛 "datatype mismatch" 中止整个查询。分步后可经
        // `fetchActiveWindowID` 在主指针缺失时回退
        // `MIN(window_id)`，保住常见的单窗口场景。
        guard let activeWindowID = fetchActiveWindowID(db: db) else {
            return nil
        }
        let activeTabIndex = fetchActiveTabIndex(db: db, windowID: activeWindowID) ?? 0
        guard let activeTabID = fetchTabIDAtOffset(
            db: db,
            windowID: activeWindowID,
            offset: activeTabIndex
        ) else {
            return nil
        }

        // 取活动 tab 的聚焦 leaf。`pane_leaves.is_focused` 是尽力
        // 而为的偏好信号——真实 Warp 库的实测显示它常对每个 leaf
        // 都是 `1`（创建时无条件置位、从不清除），分屏 tab 下排序
        // 实际退化为 `pn.id ASC` 决胜。可接受的优雅降级：单 leaf
        // tab 仍返回正确 uuid，分屏 tab 返回确定但可能非聚焦的
        // leaf（用户可手动调整）。关键正确性在于不再按
        // `active_tab_index` 偏移 `tabs JOIN pane_nodes` 行集——
        // 之前分屏 tab 会错位后续 tab 的结果。
        let sql = """
        SELECT hex(tp.uuid)
        FROM pane_nodes pn
        LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
        JOIN terminal_panes tp ON tp.id = pn.id
        WHERE pn.tab_id = ?
          AND pn.is_leaf = 1
        ORDER BY COALESCE(pl.is_focused, 0) DESC, pn.id ASC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, activeTabID)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// 读给定窗口的 `windows.active_tab_index`；行缺失或列 NULL
    /// 时返回 nil。
    private func fetchActiveTabIndex(db: OpaquePointer, windowID: Int64) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT active_tab_index FROM windows WHERE id = ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, windowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 在给定窗口 tab 列表（`tabs.id ASC`，对应 Warp 左到右的
    /// tab 条布局）中取 `offset` 处的 tab_id。
    private func fetchTabIDAtOffset(
        db: OpaquePointer,
        windowID: Int64,
        offset: Int
    ) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id FROM tabs WHERE window_id = ? ORDER BY id ASC LIMIT 1 OFFSET ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, windowID)
        sqlite3_bind_int64(stmt, 2, Int64(offset))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// 当前活动 Warp 窗口的 tab 数——精确跳转期间按键循环重试
    /// 上限。任何错误返回 0。
    public func tabCountInActiveWindow() -> Int {
        guard let db = openReadOnly() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT COUNT(*) FROM tabs
        WHERE window_id = (SELECT active_window_id FROM app LIMIT 1);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Internal

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // 短 busy timeout：Warp 事务进行中不悬挂调用方
        sqlite3_busy_timeout(db, 60) // ms
        return db
    }
}
