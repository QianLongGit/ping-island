import Foundation
@testable import IslandShared
import SQLite3
import Testing

// ─────────────────────────────────────────────────────────────────
// Warp SQLite 读取器（Task N2a 数据层）
//
// 以临时 SQLite fixture 文件验证全部查询路径，不依赖真 Warp
// 安装：DB 缺失/表缺失/查询失败一律静默 nil/0（hook 零崩溃）。
// 表结构仅含读取器实际查询的列子集（fixture 精简原则）。
// ─────────────────────────────────────────────────────────────────

// MARK: - Fixture

/// 构造最小合成 warp.sqlite：schema 与读取器查询列一一对应。
enum WarpSQLiteFixture {
    static func write(to path: String, scenario: Scenario) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE app (id INTEGER PRIMARY KEY, active_window_id INTEGER);
        CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL);
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
        CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL, is_leaf BOOLEAN NOT NULL);
        CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, uuid BLOB NOT NULL, cwd TEXT);
        CREATE TABLE commands (id INTEGER PRIMARY KEY, session_id INTEGER, command TEXT, pwd TEXT);
        CREATE TABLE blocks (id INTEGER PRIMARY KEY, pane_leaf_uuid BLOB, block_id TEXT);
        CREATE TABLE pane_leaves (pane_node_id INTEGER PRIMARY KEY, is_focused BOOLEAN NOT NULL DEFAULT 0);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "WarpSQLiteFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "schema failed: \(String(cString: sqlite3_errmsg(db)))"])
        }

        for row in scenario.rows {
            guard sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "WarpSQLiteFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "insert failed: \(String(cString: sqlite3_errmsg(db)))"])
            }
        }
    }

    struct Scenario {
        var rows: [String]

        /// 三 tab 双 claude：tab1 cwd=giftcard(uuid AAAA)、tab2
        /// cwd=open-vibe-island(uuid BBBB)、tab3 cwd=/tmp(uuid CCCC)，
        /// 活动窗口 1 / 活动 tab 序号 1（第二个 tab）。
        static let threeTabsTwoClaudes = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 1);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1), (3, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '/Users/u/giftcard')," +
                "(2, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', '/Users/u/open-vibe-island')," +
                "(3, x'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC', '/tmp');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(100, 1001, 'cd giftcard', '/Users/u')," +
                "(101, 1001, 'claude --dangerously-skip-permissions', '/Users/u/giftcard')," +
                "(200, 1002, 'claude --dangerously-skip-permissions', '/Users/u/open-vibe-island');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-1')," +
                "(2, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-1001-2')," +
                "(3, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', 'precmd-1002-1');",
        ])

        /// 复合命令流：`mkdir -p X && cd X && claude` 一行粘贴，
        /// TUI 抢占 TTY 前只渲染过首 prompt，terminal_panes.cwd
        /// 停留在初始 /Users/u，仅 commands 史留有 `cd` 文本。
        /// pane D 是目标；pane E 是近失配（-extended 后缀）防子串
        /// 误命中；session 9003 是已关 tab 的孤儿数据。
        static let compoundCommandFlow = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD', '/Users/u')," +
                "(2, x'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', '/Users/u');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(300, 9001, 'mkdir -p /tmp/compound-test && cd /tmp/compound-test && claude', '/Users/u')," +
                "(301, 9002, 'mkdir -p /tmp/compound-test-extended && cd /tmp/compound-test-extended && claude', '/Users/u')," +
                "(302, 9003, 'cd /tmp/closed-tab-cwd && claude', '/Users/u');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD', 'precmd-9001-1')," +
                "(2, x'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', 'precmd-9002-1')," +
                "(3, x'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF', 'precmd-9003-1');",
        ])

        /// 兄弟 tab 复合命令流：新 tab 继承 cwd /tmp/sibling 且未
        /// 写过任何 precmd 块；老 tab(AAAA) 有自己的 precmd 块。
        /// 回退须经 commands.pwd → terminal_panes.cwd 关联并借
        /// NOT EXISTS 外块排除老 tab，只留新 tab(CCCC)。
        static let compoundCommandInSiblingTabFlow = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '/tmp/sibling')," +
                "(2, x'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC', '/tmp/sibling');",
            "INSERT INTO commands (id, session_id, command, pwd) VALUES " +
                "(400, 10001, 'pwd', '/tmp/sibling')," +
                "(401, 10001, 'claude', '/tmp/sibling')," +
                "(402, 10002, 'mkdir -p /tmp/target && cd /tmp/target && claude', '/tmp/sibling');",
            "INSERT INTO blocks (id, pane_leaf_uuid, block_id) VALUES " +
                "(1, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-10001-1')," +
                "(2, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'precmd-10001-2');",
        ])

        /// 双窗口四 pane：窗口 1 活动，每窗两 tab。pid 关联索引
        /// 落在窗口 2 的 pane 必须被拒（跳转只在前台窗内循环）。
        static let twoWindowsFourPanes = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0), (2, 0);",
            "INSERT INTO tabs (id, window_id) VALUES " +
                "(1, 1), (2, 1)," +
                "(3, 2), (4, 2);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES " +
                "(1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 4, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'11111111111111111111111111111111', '/window-1-tab-1')," +
                "(2, x'22222222222222222222222222222222', '/window-1-tab-2')," +
                "(3, x'33333333333333333333333333333333', '/window-2-tab-1')," +
                "(4, x'44444444444444444444444444444444', '/window-2-tab-2');",
        ])

        /// 同 twoWindowsFourPanes 但 active_window_id 为 NULL：
        /// 回退 MIN(window_id) 保证单窗场景不被全拒。
        static let twoWindowsActiveNull = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, NULL);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0), (2, 0);",
            "INSERT INTO tabs (id, window_id) VALUES " +
                "(1, 1), (2, 1)," +
                "(3, 2), (4, 2);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES " +
                "(1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 4, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'11111111111111111111111111111111', '/window-1-tab-1')," +
                "(2, x'22222222222222222222222222222222', '/window-1-tab-2')," +
                "(3, x'33333333333333333333333333333333', '/window-2-tab-1')," +
                "(4, x'44444444444444444444444444444444', '/window-2-tab-2');",
        ])

        /// 首 tab 分屏三 tab 场景：tab1 分两 leaf(10/11)、tab2
        /// 单 leaf(20)、tab3 单 leaf(30)，active_tab_index=1 指
        /// 向第二个 tab（tab_id=2，pane 20）。焦点查询须按 tab
        /// 定位后再取 leaf，不被分屏 leaf 挤偏。
        static let threeTabsWithFirstSplit = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 1);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1), (3, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES " +
                "(10, 1, 1), (11, 1, 1), (20, 2, 1), (30, 3, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(10, x'44444444444444444444444444444444', '/tab-1-left')," +
                "(11, x'55555555555555555555555555555555', '/tab-1-right')," +
                "(20, x'66666666666666666666666666666666', '/tab-2')," +
                "(30, x'77777777777777777777777777777777', '/tab-3');",
            "INSERT INTO pane_leaves (pane_node_id, is_focused) VALUES " +
                "(10, 0), (11, 0), (20, 1), (30, 0);",
        ])

        /// 单窗 active_window_id NULL + active_tab_index=1：
        /// MIN(window_id) 回退取窗 1，再钻到 tab2 的 leaf。
        static let singleWindowActiveNull = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, NULL);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 1);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1), (2, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (1, 1, 1), (2, 2, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(1, x'11111111111111111111111111111111', '/tab-1')," +
                "(2, x'22222222222222222222222222222222', '/tab-2');",
        ])

        /// 单 tab 分屏、右 leaf(BBBB) is_focused=1：
        /// 焦点查询须优先聚焦 leaf，而非按 id 取最小者。
        static let singleTabSplitLeftFocused = Scenario(rows: [
            "INSERT INTO app (id, active_window_id) VALUES (1, 1);",
            "INSERT INTO windows (id, active_tab_index) VALUES (1, 0);",
            "INSERT INTO tabs (id, window_id) VALUES (1, 1);",
            "INSERT INTO pane_nodes (id, tab_id, is_leaf) VALUES (10, 1, 1), (11, 1, 1);",
            "INSERT INTO terminal_panes (id, uuid, cwd) VALUES " +
                "(10, x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '/left')," +
                "(11, x'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', '/right');",
            "INSERT INTO pane_leaves (pane_node_id, is_focused) VALUES (10, 0), (11, 1);",
        ])
    }
}

// MARK: - 测试辅助

private func withFixture(_ scenario: WarpSQLiteFixture.Scenario, _ body: (WarpSQLiteReader) throws -> Void) throws {
    let path = NSTemporaryDirectory() + "warp-fixture-\(UUID().uuidString).sqlite"
    try WarpSQLiteFixture.write(to: path, scenario: scenario)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try body(WarpSQLiteReader(databasePath: path))
}

// MARK: - DB 路径

@Suite
struct WarpSQLiteReaderPathTests {
    @Test
    func defaultDatabasePathPointsToWarpGroupContainer() {
        let path = WarpSQLiteReader.defaultDatabasePath()
        #expect(path.hasSuffix("/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"))
        #expect(path.hasPrefix(NSHomeDirectory()))
    }

    @Test
    func readerAcceptsExplicitPathOverride() {
        let reader = WarpSQLiteReader(databasePath: "/tmp/warp-fixture-override.sqlite")
        #expect(reader.databasePath == "/tmp/warp-fixture-override.sqlite")
    }
}

// MARK: - cwd 查询（主路径 + 命令史回退）

@Suite
struct WarpSQLiteReaderCwdLookupTests {
    @Test
    func lookupPaneUUIDReturnsUppercaseHexForKnownCwd() throws {
        try withFixture(.threeTabsTwoClaudes) { reader in
            #expect(reader.lookupPaneUUID(forCwd: "/Users/u/open-vibe-island") == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        }
    }

    @Test
    func lookupPaneUUIDReturnsNilForUnknownCwd() throws {
        try withFixture(.threeTabsTwoClaudes) { reader in
            #expect(reader.lookupPaneUUID(forCwd: "/nonexistent") == nil)
        }
    }

    @Test
    func lookupPaneUUIDReturnsNilForMissingDatabaseFile() {
        // 无 Warp 安装环境：DB 缺失静默 nil，绝不崩溃
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.lookupPaneUUID(forCwd: "/any") == nil)
    }

    @Test
    func lookupPaneUUIDFallsBackToCommandHistoryWhenCwdIsStale() throws {
        try withFixture(.compoundCommandFlow) { reader in
            #expect(reader.lookupPaneUUID(forCwd: "/tmp/compound-test") == "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
        }
    }

    @Test
    func lookupPaneUUIDFallbackAcceptsFirmlinkFlippedInput() throws {
        // getcwd() 解析 firmlink 得 /private/tmp/...，命令史里是
        // /tmp/...，两种形态都要试
        try withFixture(.compoundCommandFlow) { reader in
            #expect(reader.lookupPaneUUID(forCwd: "/private/tmp/compound-test") == "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
        }
    }

    @Test
    func lookupPaneUUIDFallbackExcludesForeignSessionPane() throws {
        // 兄弟 tab 同 cwd：老 tab 有 precmd 外块须被排除，
        // 只剩无块的新 tab（CCCC）
        try withFixture(.compoundCommandInSiblingTabFlow) { reader in
            #expect(reader.lookupPaneUUID(forCwd: "/tmp/target") == "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")
        }
    }

    @Test
    func cwdLookupCandidatesFlipFirmlinkForms() {
        // 纯函数：/tmp 与 /private/tmp 互为翻转发式
        #expect(WarpSQLiteReader.cwdLookupCandidates(for: "/tmp/foo") == ["/tmp/foo", "/private/tmp/foo"])
        #expect(WarpSQLiteReader.cwdLookupCandidates(for: "/private/tmp/foo") == ["/private/tmp/foo", "/tmp/foo"])
        #expect(WarpSQLiteReader.cwdLookupCandidates(for: "/var/log") == ["/var/log", "/private/var/log"])
        #expect(WarpSQLiteReader.cwdLookupCandidates(for: "/Users/u") == ["/Users/u"])
    }
}

// MARK: - shellPID 查询（sibling 索引关联）

@Suite
struct WarpSQLiteReaderPIDLookupTests {
    @Test
    func pidLookupReturnsUUIDAtSortedSiblingIndex() throws {
        // 核心关联：terminal-server 第 N 个子进程（pid 升序）
        // 拥有第 N 个 pane（tab_id 升序）
        try withFixture(.threeTabsTwoClaudes) { reader in
            let uuid = reader.lookupPaneUUIDByShellPID(5002, siblings: [5001, 5002, 5003])
            #expect(uuid == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        }
    }

    @Test
    func pidLookupReturnsNilWhenShellNotInSiblings() throws {
        try withFixture(.threeTabsTwoClaudes) { reader in
            #expect(reader.lookupPaneUUIDByShellPID(9999, siblings: [5001, 5002]) == nil)
        }
    }

    @Test
    func pidLookupRejectsBackgroundWindowPane() throws {
        // 索引 2 → tab3 → 窗口 2（后台窗）：须拒绝
        try withFixture(.twoWindowsFourPanes) { reader in
            #expect(reader.lookupPaneUUIDByShellPID(5003, siblings: [5001, 5002, 5003, 5004]) == nil)
        }
    }

    @Test
    func pidLookupFallsBackToMinWindowWhenActivePointerNull() throws {
        // active_window_id NULL → MIN(window_id)=1：
        // 索引 0 命中窗口 1 pane；索引 2 落窗口 2 仍拒
        try withFixture(.twoWindowsActiveNull) { reader in
            #expect(reader.lookupPaneUUIDByShellPID(5001, siblings: [5001, 5002, 5003, 5004]) == "11111111111111111111111111111111")
            #expect(reader.lookupPaneUUIDByShellPID(5003, siblings: [5001, 5002, 5003, 5004]) == nil)
        }
    }

    @Test
    func pidLookupReturnsNilForMissingDatabaseFile() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.lookupPaneUUIDByShellPID(100, siblings: [100, 200]) == nil)
    }
}

// MARK: - 焦点 pane / tab 计数（N2b 跳转依赖）

@Suite
struct WarpSQLiteReaderFocusTests {
    @Test
    func focusedPaneUUIDDrillsIntoActiveTabLeaf() throws {
        // 首 tab 分屏场景：active_tab_index=1 → tab2 → pane 20
        try withFixture(.threeTabsWithFirstSplit) { reader in
            #expect(reader.currentFocusedPaneUUID() == "66666666666666666666666666666666")
        }
    }

    @Test
    func focusedPaneUUIDWorksWithActiveWindowNull() throws {
        try withFixture(.singleWindowActiveNull) { reader in
            #expect(reader.currentFocusedPaneUUID() == "22222222222222222222222222222222")
        }
    }

    @Test
    func focusedPaneUUIDPrefersFocusedLeafInSplitTab() throws {
        try withFixture(.singleTabSplitLeftFocused) { reader in
            #expect(reader.currentFocusedPaneUUID() == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        }
    }

    @Test
    func focusedPaneUUIDReturnsNilForMissingDatabaseFile() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.currentFocusedPaneUUID() == nil)
    }

    @Test
    func tabCountInActiveWindowCountsTabs() throws {
        try withFixture(.threeTabsTwoClaudes) { reader in
            #expect(reader.tabCountInActiveWindow() == 3)
        }
    }

    @Test
    func tabCountReturnsZeroForMissingDatabaseFile() {
        let reader = WarpSQLiteReader(databasePath: "/nonexistent/path/warp.sqlite")
        #expect(reader.tabCountInActiveWindow() == 0)
    }
}
