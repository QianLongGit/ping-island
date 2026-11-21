//
//  WarpFocusStore.swift
//  PingIsland
//
//  Warp 精确跳转（N2b）的焦点轮询数据源：只读访问 Warp live
//  SQLite 状态。Xcode target 无法直接引用 SPM IslandShared 的
//  WarpSQLiteReader，此处镜像跳转链路所需的两个查询。
//

import Foundation
import SQLite3

// ═══════════════════════════════════════════════════════════════
// WarpFocusStore —— Warp 跳转焦点轮询查询（App 侧镜像）
//
// ▸ 仅承载 N2b 跳转所需：currentFocusedPaneUUID / tabCountInActiveWindow
// ▸ SQL 与 Prototype/Sources/IslandShared/WarpSQLiteReader.swift 逐字
//   一致（N2a 已用 fixture 测试锁定 schema）；Warp schema 变更时
//   两处同步维护
// ▸ 依赖 Warp 内部 schema，非官方支持 API；只读打开（READONLY +
//   60ms busy_timeout），Warp 运行中持锁亦不阻塞调用方
// ▸ 一切查询失败静默降级：返回 nil / 0，调用方按"无精确映射"
//   处理（无 Warp 安装环境零崩溃零副作用）
// ═══════════════════════════════════════════════════════════════

struct WarpFocusStore: Sendable {
    let databasePath: String

    init(databasePath: String = WarpFocusStore.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    /// Warp stable 渠道 SQLite 库的标准磁盘位置。
    /// Warp 被沙盒化，状态存于 Group Container 而非每 App 的
    /// Application Support。
    static func defaultDatabasePath() -> String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    /// 解析当前活动 Warp 窗口中当前聚焦 pane 的 UUID——精确跳转
    /// 期间轮询循环的驱动信号。
    ///
    /// 返回可直接与 `SessionClientInfo.warpPaneIdentifier` 比对的
    /// 大写十六进制串。任何错误或无活动窗口时返回 nil。
    func currentFocusedPaneUUID() -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        // 解析分三个显式 SQL 步骤而非单条嵌套查询：真机上
        // `app.active_window_id` 在 Warp 瞬态频繁为 NULL，嵌套形式
        // 会把 NULL 传播进 OFFSET 表达式抛 "datatype mismatch"。
        // 分步后在主指针缺失时回退 MIN(window_id)，保住单窗口场景。
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
        // 而为的偏好信号（实测常对每个 leaf 都置 1），分屏 tab 下
        // 排序退化为 `pn.id ASC` 决胜——单 leaf tab 仍返回正确
        // uuid，可接受的优雅降级。
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

    /// 当前活动 Warp 窗口的 tab 数——精确跳转期间 AX 循环重试
    /// 上限。任何错误返回 0。
    func tabCountInActiveWindow() -> Int {
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

    /// 读取 Warp 当前"活动窗口"指针。
    ///
    /// 主来源 `app.active_window_id` 在 Warp 瞬态下常留 NULL，此时
    /// 回退 tabs 的 MIN(window_id)——单窗口场景下即唯一窗口。
    /// 两者都无可用值时返回 nil。
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
