//
//  KeroInventoryTests.swift
//  PingIslandTests
//
//  T25「kero 会话清单补全」的纯单测——不依赖真实 kero 二进制，
//  全部走注入的执行器闭包 / 固定时钟。
//
//  覆盖四组契约：
//    1. 解码容错：`kero ls --json -a`（host 分组形状）与
//       `kero ls --json`（扁平形状）都能解；可选字段缺失不炸；
//       非法 JSON / 无有效会话的形状显式抛错（由上层降级为空清单）。
//    2. 合并去重（产品裁定后语义）：agentSession.id 命中 → 不重复出行
//       （只补数据）；其余（含 dir/pid 相同）→ kero 独占行；
//       同一个 agent 会话在 kero 侧只出一行；纯 shell 会话不入列。
//    3. Reader 契约：TTL 内二次调用不重复 exec；TTL 到期重新 exec；
//       二进制缺失 / 执行失败 → 空清单（降级，不抛）；
//       全主机聚合（-a）超时或无会话 → 降级跑本机清单（不带 -a）。
//    4. 排序：kero 行按 activity 混排进现有列表，不新增分区。
//

import XCTest
@testable import Ping_Island

final class KeroInventoryTests: XCTestCase {

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 测试夹具
    // ═════════════════════════════════════════════════════════════════

    /// `kero ls --json -a` 的真实形状裁剪版（host 分组 + pane 列表，
    /// 目录一律用合成路径，不携带本机绝对路径）
    private let groupedJSON = """
    [
      {
        "host": "local",
        "sessions": [
          {
            "id": "srjtf4q",
            "title": "Claude Code",
            "name": "AiDaily",
            "project": "bddv4qk",
            "dir": "/tmp/ai-daily",
            "agent": "claude",
            "status": "working",
            "pid": 2627715,
            "tty": "/dev/pts/0",
            "activity": 1795419601031,
            "created": 1792993818789,
            "agentSession": { "agent": "claude", "id": "uuid-1" },
            "lead": "w8dmddj",
            "panes": [
              {
                "id": "w8dmddj",
                "title": "Claude Code",
                "dir": "/tmp/ai-daily",
                "agent": "claude",
                "status": "working",
                "pid": 2627715,
                "tty": "/dev/pts/0",
                "activity": 1795419601031,
                "agentSession": { "agent": "claude", "id": "uuid-1" }
              }
            ]
          }
        ]
      }
    ]
    """

    /// `kero ls --json` 的真实形状裁剪版（扁平 session 数组 + panes，
    /// 与 2026-11 实测输出对齐；本例为纯 shell 会话，pane 无 agentSession）
    private let flatJSON = """
    [
      {
        "id": "9t6949p",
        "title": "ql@ubuntu-vm:~",
        "name": "Shell",
        "dir": "/tmp/dev-home",
        "shell": "zsh",
        "status": "idle",
        "pid": 2627716,
        "tty": "/dev/pts/1",
        "activity": 1795418252867,
        "created": 1793238365081,
        "restored": true,
        "cols": 192,
        "rows": 69,
        "panes": [
          {
            "id": "b6b6nwv",
            "title": "ql@ubuntu-vm:~",
            "dir": "/tmp/dev-home",
            "shell": "zsh",
            "status": "idle",
            "pid": 2627716,
            "tty": "/dev/pts/1",
            "activity": 1795418252867
          }
        ]
      }
    ]
    """

    private func makeReader(
        executor: @escaping KeroInventoryReader.Executor,
        locator: @escaping KeroInventoryReader.BinaryLocator = { "/usr/local/bin/kero" },
        ttl: TimeInterval = 3,
        timeout: TimeInterval = 5,
        now: @escaping KeroInventoryReader.Clock = { Date() }
    ) -> KeroInventoryReader {
        KeroInventoryReader(executor: executor, locator: locator, ttl: ttl, timeout: timeout, now: now)
    }

    /// 构造一行 kero 数据（混排用例专用）
    private func makeKeroRow(id: String, activity: Date?) -> KeroSessionMerger.Row {
        KeroSessionMerger.Row(
            id: id,
            host: "local",
            hostLabel: nil,
            title: "kero 会话",
            dir: "/tmp/kero",
            status: "idle",
            agent: "claude",
            agentSessionId: nil,
            paneId: nil,
            tty: nil,
            pid: nil,
            activity: activity
        )
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 1. 解码容错
    // ═════════════════════════════════════════════════════════════════

    func testDecodesGroupedInventoryShape() throws {
        let inventory = try KeroInventoryDecoder.decode(Data(groupedJSON.utf8))

        XCTAssertEqual(inventory.count, 1)
        let hostInventory = try XCTUnwrap(inventory.first)
        XCTAssertEqual(hostInventory.host, "local")
        XCTAssertEqual(hostInventory.sessions.count, 1)

        let session = try XCTUnwrap(hostInventory.sessions.first)
        XCTAssertEqual(session.id, "srjtf4q")
        XCTAssertEqual(session.title, "Claude Code")
        XCTAssertEqual(session.dir, "/tmp/ai-daily")
        XCTAssertEqual(session.status, "working")
        XCTAssertEqual(session.agentSessionId, "uuid-1")
        XCTAssertEqual(session.pid, 2627715)
        XCTAssertEqual(session.tty, "/dev/pts/0")
        XCTAssertEqual(session.activity, Date(timeIntervalSince1970: 1_795_419_601.031))
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(session.panes[0].id, "w8dmddj")
        XCTAssertEqual(session.panes[0].agentSessionId, "uuid-1")
    }

    func testDecodesFlatInventoryShape() throws {
        let inventory = try KeroInventoryDecoder.decode(Data(flatJSON.utf8))

        XCTAssertEqual(inventory.count, 1)
        let hostInventory = try XCTUnwrap(inventory.first)
        XCTAssertEqual(hostInventory.host, "local")
        XCTAssertEqual(hostInventory.sessions.count, 1)

        let session = try XCTUnwrap(hostInventory.sessions.first)
        XCTAssertEqual(session.id, "9t6949p")
        XCTAssertEqual(session.title, "ql@ubuntu-vm:~")
        XCTAssertEqual(session.dir, "/tmp/dev-home")
        XCTAssertEqual(session.status, "idle")
        XCTAssertNil(session.agentSessionId)
        XCTAssertEqual(session.panes.count, 1, "纯 shell 会话也带 panes（2026-11 实测形状）")
        XCTAssertNil(session.panes.first?.agentSessionId)
    }

    func testDecodesTolerantlyWhenOptionalFieldsAreMissing() throws {
        let json = #"[{"host":"Home","sessions":[{"id":"s1"}]}]"#
        let inventory = try KeroInventoryDecoder.decode(Data(json.utf8))

        XCTAssertEqual(inventory.count, 1)
        let hostInventory = try XCTUnwrap(inventory.first)
        XCTAssertEqual(hostInventory.host, "Home")

        let session = try XCTUnwrap(hostInventory.sessions.first)
        XCTAssertEqual(session.id, "s1")
        XCTAssertNil(session.title)
        XCTAssertNil(session.dir)
        XCTAssertNil(session.status)
        XCTAssertNil(session.agentSessionId)
        XCTAssertNil(session.activity)
        XCTAssertTrue(session.panes.isEmpty)
    }

    func testDecodeThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try KeroInventoryDecoder.decode(Data("not-json".utf8)))
    }

    /// 形状二（扁平数组）里没有 id 的条目是形状噪声——过滤后无有效会话
    /// 必须显式抛错，由 Reader 降级为空清单，而不是产出幽灵行。
    func testDecodeDropsFlatSessionsWithoutID() {
        XCTAssertThrowsError(try KeroInventoryDecoder.decode(Data(#"[{"foo":1},{"bar":2}]"#.utf8)))
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 2. 合并去重
    // ═════════════════════════════════════════════════════════════════

    func testMergeDeduplicatesByAgentSessionID() {
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s1",
                        name: nil,
                        title: "Claude Code",
                        dir: "/tmp/a",
                        project: nil,
                        status: "working",
                        agent: "claude",
                        agentSessionId: "uuid-1",
                        tty: "/dev/pts/0",
                        pid: 42,
                        activity: Date(timeIntervalSince1970: 100),
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]
        let hookSessions = [
            KeroSessionMerger.HookSessionRef(sessionId: "uuid-1", cwd: "/tmp/a", pid: 42)
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: hookSessions)

        XCTAssertTrue(result.exclusiveRows.isEmpty, "agentSession.id 命中已有行时不得重复出行")
        XCTAssertEqual(result.enrichmentByHookSessionId["uuid-1"]?.host, "local")
        XCTAssertEqual(result.enrichmentByHookSessionId["uuid-1"]?.status, "working")
    }

    /// 产品裁定后的语义：(dir, pid) 相同但 agentSession.id 不同 → 不再
    /// 视为同一会话（近似匹配规则已删），kero 会话仍出独立行。
    /// 原因：hook 侧 pid 是 agent 进程树 PID，kero 侧 pid 是 pane 的
    /// shell PID，两者在真实数据上永不相等——近似匹配是死规则，
    /// 反而可能把合法独占行压掉。
    func testMergeKeepsExclusiveRowWhenOnlyDirectoryAndPIDMatch() {
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s1",
                        name: nil,
                        title: "Claude Code",
                        dir: "/tmp/a",
                        project: nil,
                        status: "working",
                        agent: "claude",
                        agentSessionId: "uuid-k",
                        tty: "/dev/pts/0",
                        pid: 42,
                        activity: nil,
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]
        let hookSessions = [
            KeroSessionMerger.HookSessionRef(sessionId: "hook-uuid", cwd: "/tmp/a", pid: 42)
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: hookSessions)

        XCTAssertEqual(result.exclusiveRows.count, 1, "仅 dir/pid 相同不得吞掉 kero 独占行")
        XCTAssertEqual(result.exclusiveRows.first?.agentSessionId, "uuid-k")
        XCTAssertTrue(result.enrichmentByHookSessionId.isEmpty, "近似命中不再产出 enrichment")
    }

    func testMergeAddsExclusiveRowForUnknownKeroSession() {
        let inventory = [
            KeroHostInventory(
                host: "165",
                sessions: [
                    KeroSession(
                        id: "s9",
                        name: "RemoteShell",
                        title: "codex on 165",
                        dir: "/srv/app",
                        project: nil,
                        status: "idle",
                        agent: "codex",
                        agentSessionId: "uuid-9",
                        tty: "/dev/pts/7",
                        pid: 99,
                        activity: Date(timeIntervalSince1970: 200),
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        let row = try? XCTUnwrap(result.exclusiveRows.first)
        XCTAssertEqual(row?.title, "codex on 165")
        XCTAssertEqual(row?.dir, "/srv/app")
        XCTAssertEqual(row?.status, "idle")
        XCTAssertEqual(row?.host, "165")
        XCTAssertEqual(row?.hostLabel, "165")
        XCTAssertEqual(row?.agentSessionId, "uuid-9")
    }

    func testMergeFallsBackToDirectoryBasenameWhenTitleMissing() {
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s2",
                        name: nil,
                        title: nil,
                        dir: "/tmp/projects/aurora-panel",
                        project: nil,
                        status: nil,
                        agent: nil,
                        agentSessionId: "uuid-b",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertEqual(result.exclusiveRows.first?.title, "aurora-panel", "标题兜底链：title → name → 目录 basename")
    }

    func testMergeEmitsOneRowPerAgentPaneAndSkipsDuplicateAgentSessions() {
        let paneA = KeroPane(
            id: "p1",
            title: "Claude Code",
            dir: "/tmp/a",
            status: "working",
            agent: "claude",
            agentSessionId: "uuid-a",
            tty: "/dev/pts/0",
            pid: 11,
            activity: Date(timeIntervalSince1970: 300),
            created: nil
        )
        let paneB = KeroPane(
            id: "p2",
            title: "Codex",
            dir: "/tmp/a",
            status: "working",
            agent: "codex",
            agentSessionId: "uuid-b",
            tty: "/dev/pts/1",
            pid: 12,
            activity: Date(timeIntervalSince1970: 250),
            created: nil
        )
        let paneDuplicate = KeroPane(
            id: "p3",
            title: "Claude Code (mirror)",
            dir: "/tmp/a",
            status: "working",
            agent: "claude",
            agentSessionId: "uuid-a",
            tty: "/dev/pts/2",
            pid: 13,
            activity: Date(timeIntervalSince1970: 240),
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s3",
                        name: nil,
                        title: "Multi",
                        dir: "/tmp/a",
                        project: nil,
                        status: "working",
                        agent: "claude",
                        agentSessionId: "uuid-a",
                        tty: nil,
                        pid: nil,
                        activity: Date(timeIntervalSince1970: 300),
                        created: nil,
                        panes: [paneA, paneB, paneDuplicate]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 2, "同一 agent 会话（uuid-a）只出一行")
        XCTAssertEqual(Set(result.exclusiveRows.map(\.agentSessionId)), Set(["uuid-a", "uuid-b"]))
    }

    func testMergeMarksLocalHostWithoutHostLabel() {
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s4",
                        name: nil,
                        title: "Local",
                        dir: "/tmp/a",
                        project: nil,
                        status: "idle",
                        agent: nil,
                        agentSessionId: "uuid-l",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertNil(result.exclusiveRows.first?.hostLabel, "本机不显示主机徽标")
    }

    /// 产品裁定：纯 shell 会话（无任何 agentSession.id）不入列——
    /// 无 id 的行既无法参与去重，点击也无法精确跳转。
    func testMergeSkipsPureShellSessionWithoutAgentSessionID() {
        let plainPane = KeroPane(
            id: "p-shell",
            title: nil,
            dir: "/tmp/plain",
            status: "idle",
            agent: nil,
            agentSessionId: nil,
            tty: "/dev/pts/9",
            pid: 5,
            activity: Date(timeIntervalSince1970: 100),
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s-shell",
                        name: "Shell",
                        title: nil,
                        dir: "/tmp/plain",
                        project: nil,
                        status: "idle",
                        agent: nil,
                        agentSessionId: nil,
                        tty: nil,
                        pid: 5,
                        activity: Date(timeIntervalSince1970: 100),
                        created: nil,
                        panes: [plainPane]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertTrue(result.exclusiveRows.isEmpty, "纯 shell 会话（无 agentSession.id）不入列")
    }

    /// pane id 缺失时 Row.id 必须用序号兜底——ForEach 依赖 id 唯一。
    func testMergeGeneratesUniqueRowIDsWhenPaneIDsMissing() {
        let paneA = KeroPane(
            id: "",
            title: "A",
            dir: nil,
            status: nil,
            agent: "claude",
            agentSessionId: "uuid-1",
            tty: nil,
            pid: nil,
            activity: nil,
            created: nil
        )
        let paneB = KeroPane(
            id: "",
            title: "B",
            dir: nil,
            status: nil,
            agent: "claude",
            agentSessionId: "uuid-2",
            tty: nil,
            pid: nil,
            activity: nil,
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s-multi",
                        name: nil,
                        title: nil,
                        dir: nil,
                        project: nil,
                        status: nil,
                        agent: nil,
                        agentSessionId: nil,
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: [paneA, paneB]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 2)
        XCTAssertEqual(Set(result.exclusiveRows.map(\.id)).count, 2, "pane id 缺失时 Row.id 必须用序号兜底保证唯一")
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 3. Reader 契约（TTL 缓存 / 降级）
    // ═════════════════════════════════════════════════════════════════

    func testReaderCachesWithinTTLAndRefreshesAfterExpiry() {
        var execCount = 0
        var now = Date(timeIntervalSince1970: 1_000)
        let reader = makeReader(
            executor: { _, _, _ in
                execCount += 1
                return Data(self.groupedJSON.utf8)
            },
            ttl: 3,
            now: { now }
        )

        let first = reader.readInventory()
        let second = reader.readInventory()

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(execCount, 1, "TTL 内二次调用不得重复 exec")

        now = now.addingTimeInterval(4)
        let third = reader.readInventory()

        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(execCount, 2, "TTL 到期后应重新 exec")
    }

    func testReaderForceRefreshBypassesCache() {
        var execCount = 0
        let reader = makeReader(
            executor: { _, _, _ in
                execCount += 1
                return Data(self.groupedJSON.utf8)
            }
        )

        _ = reader.readInventory()
        _ = reader.readInventory(forceRefresh: true)

        XCTAssertEqual(execCount, 2)
    }

    func testReaderReturnsEmptyInventoryWhenBinaryIsMissing() {
        var execCount = 0
        let reader = makeReader(
            executor: { _, _, _ in
                execCount += 1
                return Data(self.groupedJSON.utf8)
            },
            locator: { nil }
        )

        let inventory = reader.readInventory()

        XCTAssertTrue(inventory.isEmpty, "二进制缺失应降级为空清单")
        XCTAssertEqual(execCount, 0, "二进制缺失时不应执行命令")
    }

    func testReaderReturnsEmptyInventoryWhenExecutorThrows() {
        struct Boom: Error {}
        let reader = makeReader(executor: { _, _, _ in throw Boom() })

        let inventory = reader.readInventory()

        XCTAssertTrue(inventory.isEmpty, "执行失败应降级为空清单")
    }

    func testReaderReturnsEmptyInventoryWhenPayloadIsMalformed() {
        let reader = makeReader(executor: { _, _, _ in Data("not-json".utf8) })

        let inventory = reader.readInventory()

        XCTAssertTrue(inventory.isEmpty, "解析失败应降级为空清单")
    }

    /// MF-3 兜底契约①：全主机聚合（-a）超时/执行失败 → 降级跑本机清单。
    /// kero 的 -a 对每台主机最多等待 10s，聚合超时属正常代价而非终态失败。
    func testReaderFallsBackToLocalListWhenAllHostsQueryTimesOut() {
        struct Boom: Error {}
        var calls: [[String]] = []
        let reader = makeReader(
            executor: { _, arguments, _ in
                calls.append(arguments)
                if arguments.contains("-a") { throw Boom() }
                return Data(self.flatJSON.utf8)
            }
        )

        let inventory = reader.readInventory()

        XCTAssertEqual(calls.count, 2, "-a 失败后应降级再跑一次本机清单")
        XCTAssertEqual(calls.first, ["ls", "--json", "-a"])
        XCTAssertEqual(calls.last, ["ls", "--json"])
        XCTAssertEqual(inventory.count, 1, "兜底结果应被采用")
        XCTAssertEqual(inventory.first?.host, "local")
    }

    /// MF-3 兜底契约②：-a 返回的聚合清单里没有任何会话（如远程主机全部
    /// 无应答）→ 同样降级跑本机清单，而不是把空聚合当最终结果。
    func testReaderFallsBackToLocalListWhenAllHostsYieldNoSessions() {
        let emptyHostsJSON = #"[{"host":"165","error":"no answer in 10s","sessions":[]}]"#
        var calls: [[String]] = []
        let reader = makeReader(
            executor: { _, arguments, _ in
                calls.append(arguments)
                if arguments.contains("-a") { return Data(emptyHostsJSON.utf8) }
                return Data(self.flatJSON.utf8)
            }
        )

        let inventory = reader.readInventory()

        XCTAssertEqual(calls.count, 2, "聚合结果无任何会话时应降级跑本机清单")
        XCTAssertEqual(calls.last, ["ls", "--json"])
        XCTAssertEqual(inventory.first?.sessions.count, 1, "应采用本机清单而非空聚合")
    }

    /// MF-3 兜底契约③：聚合成功且有会话 → 不得再跑本机清单（避免双倍 exec）。
    func testReaderSkipsFallbackWhenAllHostsAggregateHasSessions() {
        var calls: [[String]] = []
        let reader = makeReader(
            executor: { _, arguments, _ in
                calls.append(arguments)
                return Data(self.groupedJSON.utf8)
            }
        )

        let inventory = reader.readInventory()

        XCTAssertEqual(calls.count, 1, "聚合成功且有会话时不得再跑本机清单")
        XCTAssertEqual(calls.first, ["ls", "--json", "-a"])
        XCTAssertEqual(inventory.count, 1)
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 4. 列表排序混排
    // ═════════════════════════════════════════════════════════════════

    func testComposerInterleavesKeroRowsByActivity() {
        let hookGroups = [
            KeroSessionListComposer.HookGroup(id: "hook-a", activity: Date(timeIntervalSince1970: 300)),
            KeroSessionListComposer.HookGroup(id: "hook-b", activity: Date(timeIntervalSince1970: 100))
        ]
        let keroRows = [
            KeroSessionMerger.Row(
                id: "kero:local:s1:p1",
                host: "local",
                hostLabel: nil,
                title: "kero 新",
                dir: "/tmp/a",
                status: "working",
                agent: "claude",
                agentSessionId: "uuid-1",
                paneId: "p1",
                tty: nil,
                pid: nil,
                activity: Date(timeIntervalSince1970: 200)
            )
        ]

        let entries = KeroSessionListComposer.compose(hookGroups: hookGroups, keroRows: keroRows)

        XCTAssertEqual(entries.count, 3)

        // 取值越界安全：条目数不足时后续断言自然失败，而不是触发运行时 trap
        let first = entries.first
        let second = entries.count > 1 ? entries[1] : nil
        let third = entries.count > 2 ? entries[2] : nil

        if case .some(.hook(let id)) = first {
            XCTAssertEqual(id, "hook-a")
        } else {
            XCTFail("首项应是 hook 组")
        }
        if case .some(.kero(let row)) = second {
            XCTAssertEqual(row.id, "kero:local:s1:p1")
        } else {
            XCTFail("第二项应是 kero 行")
        }
        if case .some(.hook(let id)) = third {
            XCTAssertEqual(id, "hook-b")
        } else {
            XCTFail("末项应是 hook 组")
        }
    }
    // ═════════════════════════════════════════════════════════════════
    // MARK: - 5. 补充契约（命令参数 / 失败缓存 / 时间戳单位 / 字段兜底 / 混排边界）
    // ═════════════════════════════════════════════════════════════════

    func testReaderExecutesKeroListJSONAllCommand() {
        var capturedBinary: String?
        var capturedArguments: [String] = []
        var capturedTimeout: TimeInterval = 0

        let reader = makeReader(
            executor: { binary, arguments, timeout in
                capturedBinary = binary
                capturedArguments = arguments
                capturedTimeout = timeout
                return Data(self.groupedJSON.utf8)
            },
            locator: { "/usr/local/bin/kero" },
            timeout: 7
        )

        _ = reader.readInventory()

        XCTAssertEqual(capturedBinary, "/usr/local/bin/kero")
        XCTAssertEqual(capturedArguments, ["ls", "--json", "-a"], "必须执行 kero ls --json -a（-a 含全部主机）")
        XCTAssertEqual(capturedTimeout, 7, "超时必须透传给执行器")
    }

    func testReaderCachesFailedResultWithinTTL() {
        struct Boom: Error {}
        var execCount = 0
        let reader = makeReader(
            executor: { _, _, _ in
                execCount += 1
                throw Boom()
            }
        )

        let first = reader.readInventory()
        let second = reader.readInventory()

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        // 兜底契约：一次 readInventory 最多两跳（-a 失败 → 本机清单也失败）
        XCTAssertEqual(execCount, 2, "两跳都失败后，失败结果进 TTL 缓存，避免反复 exec 抖动")
    }

    func testDecoderAcceptsSecondUnitTimestamps() throws {
        let json = #"[{"host":"local","sessions":[{"id":"s1","activity":1795419601,"created":1792993818}]}]"#
        let inventory = try KeroInventoryDecoder.decode(Data(json.utf8))
        let session = try XCTUnwrap(inventory.first?.sessions.first)

        XCTAssertEqual(session.activity, Date(timeIntervalSince1970: 1_795_419_601))
        XCTAssertEqual(session.created, Date(timeIntervalSince1970: 1_792_993_818))
    }

    func testDecoderAcceptsISO8601TimestampStrings() throws {
        let json = #"[{"host":"local","sessions":[{"id":"s1","activity":"2026-11-23T08:00:00Z"}]}]"#
        let inventory = try KeroInventoryDecoder.decode(Data(json.utf8))
        let session = try XCTUnwrap(inventory.first?.sessions.first)

        XCTAssertEqual(session.activity, ISO8601DateFormatter().date(from: "2026-11-23T08:00:00Z"))
    }

    func testMergeFallsBackToSessionNameWhenTitleMissing() {
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s5",
                        name: "RemoteShell",
                        title: nil,
                        dir: "/srv/app",
                        project: nil,
                        status: "idle",
                        agent: nil,
                        agentSessionId: "uuid-s",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertEqual(result.exclusiveRows.first?.title, "RemoteShell", "标题兜底链：title → name → 目录 basename")
    }

    func testMergeFallsBackToSessionNameWhenPaneTitleMissing() {
        let pane = KeroPane(
            id: "p1",
            title: nil,
            dir: "/pane/dir",
            status: "working",
            agent: "claude",
            agentSessionId: "uuid-n",
            tty: "/dev/pts/3",
            pid: 55,
            activity: Date(timeIntervalSince1970: 400),
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s7",
                        name: "Session Name",
                        title: nil,
                        dir: "/session/dir",
                        project: nil,
                        status: "idle",
                        agent: "claude",
                        agentSessionId: "uuid-n",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: [pane]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertEqual(result.exclusiveRows.first?.title, "Session Name")
    }

    func testMergePrefersPaneFieldsOverSessionFields() {
        let pane = KeroPane(
            id: "p1",
            title: "Pane Title",
            dir: "/pane/dir",
            status: "working",
            agent: "codex",
            agentSessionId: "uuid-p",
            tty: "/dev/pts/9",
            pid: 77,
            activity: Date(timeIntervalSince1970: 500),
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s6",
                        name: "Session Name",
                        title: "Session Title",
                        dir: "/session/dir",
                        project: nil,
                        status: "idle",
                        agent: "claude",
                        agentSessionId: "uuid-s",
                        tty: "/dev/pts/0",
                        pid: 11,
                        activity: Date(timeIntervalSince1970: 100),
                        created: nil,
                        panes: [pane]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])
        let row = result.exclusiveRows.first

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertEqual(row?.title, "Pane Title")
        XCTAssertEqual(row?.dir, "/pane/dir")
        XCTAssertEqual(row?.status, "working")
        XCTAssertEqual(row?.agent, "codex")
        XCTAssertEqual(row?.pid, 77)
        XCTAssertEqual(row?.activity, Date(timeIntervalSince1970: 500))
    }

    func testMergeKeepsRemoteHostLabel() {
        let inventory = [
            KeroHostInventory(
                host: "Home",
                sessions: [
                    KeroSession(
                        id: "s8",
                        name: nil,
                        title: "Remote",
                        dir: "/Users/dev/code",
                        project: nil,
                        status: "idle",
                        agent: "claude",
                        agentSessionId: "uuid-r",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: []
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1)
        XCTAssertEqual(result.exclusiveRows.first?.host, "Home")
        XCTAssertEqual(result.exclusiveRows.first?.hostLabel, "Home", "非本机应显示主机徽标")
    }

    func testMergeEmitsSingleRowForSameAgentSessionAcrossHosts() {
        let paneLocal = KeroPane(
            id: "p1",
            title: "Claude Code",
            dir: "/tmp/a",
            status: "working",
            agent: "claude",
            agentSessionId: "uuid-x",
            tty: "/dev/pts/0",
            pid: 11,
            activity: Date(timeIntervalSince1970: 300),
            created: nil
        )
        let paneRemote = KeroPane(
            id: "p2",
            title: "Claude Code",
            dir: "/tmp/a",
            status: "working",
            agent: "claude",
            agentSessionId: "uuid-x",
            tty: nil,
            pid: nil,
            activity: Date(timeIntervalSince1970: 250),
            created: nil
        )
        let inventory = [
            KeroHostInventory(
                host: "local",
                sessions: [
                    KeroSession(
                        id: "s9",
                        name: nil,
                        title: "Local",
                        dir: "/tmp/a",
                        project: nil,
                        status: "working",
                        agent: "claude",
                        agentSessionId: "uuid-x",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: [paneLocal]
                    )
                ]
            ),
            KeroHostInventory(
                host: "165",
                sessions: [
                    KeroSession(
                        id: "s10",
                        name: nil,
                        title: "Remote",
                        dir: "/tmp/a",
                        project: nil,
                        status: "working",
                        agent: "claude",
                        agentSessionId: "uuid-x",
                        tty: nil,
                        pid: nil,
                        activity: nil,
                        created: nil,
                        panes: [paneRemote]
                    )
                ]
            )
        ]

        let result = KeroSessionMerger.merge(inventory: inventory, hookSessions: [])

        XCTAssertEqual(result.exclusiveRows.count, 1, "同一 agent 会话跨主机也只出一行")
    }

    func testComposerPlacesNewestKeroRowFirstAndOldestLast() {
        let hookGroups = [
            KeroSessionListComposer.HookGroup(id: "hook-mid", activity: Date(timeIntervalSince1970: 200))
        ]
        let newer = makeKeroRow(id: "kero:local:s1:newer", activity: Date(timeIntervalSince1970: 300))
        let older = makeKeroRow(id: "kero:local:s1:older", activity: Date(timeIntervalSince1970: 100))

        let entries = KeroSessionListComposer.compose(hookGroups: hookGroups, keroRows: [older, newer])

        XCTAssertEqual(entries.count, 3)
        if case .some(.kero(let row)) = entries.first {
            XCTAssertEqual(row.id, "kero:local:s1:newer", "比 hook 组新的 kero 行应排在最前")
        } else {
            XCTFail("首项应是较新的 kero 行")
        }
        if case .some(.kero(let row)) = entries.last {
            XCTAssertEqual(row.id, "kero:local:s1:older", "比 hook 组旧的 kero 行应排在末尾")
        } else {
            XCTFail("末项应是较旧的 kero 行")
        }
    }

    func testComposerKeepsHookOrderWhenKeroRowsAreEmpty() {
        let hookGroups = [
            KeroSessionListComposer.HookGroup(id: "hook-a", activity: Date(timeIntervalSince1970: 300)),
            KeroSessionListComposer.HookGroup(id: "hook-b", activity: Date(timeIntervalSince1970: 100))
        ]

        let entries = KeroSessionListComposer.compose(hookGroups: hookGroups, keroRows: [])

        XCTAssertEqual(entries.count, 2)
        if case .some(.hook(let id)) = entries.first {
            XCTAssertEqual(id, "hook-a")
        } else {
            XCTFail("首项应是 hook-a")
        }
        if case .some(.hook(let id)) = entries.last {
            XCTAssertEqual(id, "hook-b")
        } else {
            XCTFail("末项应是 hook-b")
        }
    }

    func testComposerReturnsOnlyKeroRowsWhenNoHookGroups() {
        let row = makeKeroRow(id: "kero:local:s1:p1", activity: Date(timeIntervalSince1970: 100))

        let entries = KeroSessionListComposer.compose(hookGroups: [], keroRows: [row])

        XCTAssertEqual(entries.count, 1)
        if case .some(.kero(let keroRow)) = entries.first {
            XCTAssertEqual(keroRow.id, "kero:local:s1:p1")
        } else {
            XCTFail("应只有 kero 行")
        }
    }
}
