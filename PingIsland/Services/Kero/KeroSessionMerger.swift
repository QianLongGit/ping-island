//
//  KeroSessionMerger.swift
//  PingIsland
//
//  T25「kero 会话清单补全」：kero 清单与 hook 会话列表的合并去重
//  （纯函数，无 IO，可直接单测）。
//
//  合并键优先级（修复轮 1 定案）：
//    ① agentSession.id 相同 → kero 数据补充已有行，不重复出行
//    ② 不中 → 新增 kero 独占行
//    （原 (dir, pid) 近似匹配规则已删：hook 侧 pid 是 agent 进程树
//     PID、kero 侧 pane pid 是 shell PID，两套 PID 空间在真实数据上
//     永不相等——死规则非但从未命中，还会在人工构造的相同值下
//     误杀合法独占行）
//
//  行单元：kero 会话里每个带 agent 的 pane 各占一行（hook 列表的
//  粒度也是 agent 会话）；纯 shell 会话（无 agent pane 且无会话级
//  agentSessionId）不入列——没有 agent 凭据的行既无法去重也无从
//  跳转，列出只会制造噪声。
//

import Foundation

// ═════════════════════════════════════════════════════════════════
// MARK: - 合并器
// ═════════════════════════════════════════════════════════════════

nonisolated enum KeroSessionMerger {

    // ═════════════════════════════════════════════════════════════
    // MARK: - 输入 / 输出模型
    // ═════════════════════════════════════════════════════════════

    /// hook 侧已有会话的最小匹配信息
    nonisolated struct HookSessionRef: Equatable {
        let sessionId: String
        let cwd: String?
        let pid: Int?
    }

    /// kero 侧对已有 hook 行的补充信息（仅数据，不改既有行渲染）
    nonisolated struct Enrichment: Equatable {
        let host: String
        let hostLabel: String?
        let dir: String?
        let status: String?
        let agentSessionId: String?
        let paneId: String?
        let tty: String?
        let pid: Int?
    }

    /// kero 独占行（面板中的一行）
    nonisolated struct Row: Identifiable, Equatable {
        let id: String
        let host: String
        /// 主机徽标文案；本机（local）为 nil
        let hostLabel: String?
        let title: String
        let dir: String?
        let status: String?
        let agent: String?
        let agentSessionId: String?
        let paneId: String?
        let tty: String?
        let pid: Int?
        let activity: Date?
    }

    /// 合并结果
    nonisolated struct MergeResult: Equatable {
        /// 需要新增到面板的 kero 独占行
        let exclusiveRows: [Row]
        /// 按 hook 会话 id 索引的补充信息（不新增行）
        let enrichmentByHookSessionId: [String: Enrichment]
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 合并
    // ═════════════════════════════════════════════════════════════

    /// 合并 kero 清单与 hook 会话列表
    /// - Parameters:
    ///   - inventory: kero 侧按主机分组的会话清单
    ///   - hookSessions: hook 侧已知的会话（用于去重）
    /// - Returns: kero 独占行 + 按 hook 会话 id 索引的补充信息
    static func merge(
        inventory: [KeroHostInventory],
        hookSessions: [HookSessionRef]
    ) -> MergeResult {
        // ── hook 索引：hook 侧会话 id 即 agentSession.id ────────────
        var hookByAgentSessionId: [String: HookSessionRef] = [:]
        for hook in hookSessions where !hook.sessionId.isEmpty {
            hookByAgentSessionId[hook.sessionId] = hook
        }

        var exclusiveRows: [Row] = []
        var enrichments: [String: Enrichment] = [:]
        /// kero 侧已出行的 agent 会话（同一 agent 会话只出一行）
        var seenAgentSessionIds: Set<String> = []

        for hostInventory in inventory {
            let label = hostLabel(for: hostInventory.host)

            for session in hostInventory.sessions {
                for row in rowCandidates(session: session, host: hostInventory.host, hostLabel: label) {
                    // ① agentSession.id 命中 hook 会话 → 只补充数据，不重复出行
                    if let agentSessionId = row.agentSessionId, !agentSessionId.isEmpty {
                        if seenAgentSessionIds.contains(agentSessionId) {
                            continue
                        }
                        seenAgentSessionIds.insert(agentSessionId)

                        if let hook = hookByAgentSessionId[agentSessionId] {
                            enrichments[hook.sessionId] = enrichment(for: row)
                            continue
                        }
                    }

                    // ② 未命中 hook 会话 → kero 独占行
                    exclusiveRows.append(row)
                }
            }
        }

        return MergeResult(
            exclusiveRows: exclusiveRows,
            enrichmentByHookSessionId: enrichments
        )
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 内部工具
    // ═════════════════════════════════════════════════════════════

    /// 主机徽标文案：本机（local）不显示，其余显示别名
    private static func hostLabel(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "local" else { return nil }
        return trimmed
    }

    /// 把一个 kero 会话拆成若干候选行
    /// - Note: 带 agent 的 pane 各占一行；无 agent pane 时保留会话级兜底行
    private static func rowCandidates(
        session: KeroSession,
        host: String,
        hostLabel: String?
    ) -> [Row] {
        let agentPanes = session.panes.filter { !($0.agentSessionId ?? "").isEmpty }

        struct Base {
            let pane: KeroPane?
            let agentSessionId: String?
            let title: String?
            let dir: String?
            let status: String?
            let agent: String?
            let tty: String?
            let pid: Int?
            let activity: Date?
        }

        let bases: [Base]
        if !agentPanes.isEmpty {
            bases = agentPanes.map { pane in
                Base(
                    pane: pane,
                    agentSessionId: pane.agentSessionId,
                    title: pane.title ?? session.title ?? session.name,
                    dir: pane.dir ?? session.dir,
                    status: pane.status ?? session.status,
                    agent: pane.agent ?? session.agent,
                    tty: pane.tty ?? session.tty,
                    pid: pane.pid ?? session.pid,
                    activity: pane.activity ?? session.activity
                )
            }
        } else {
            // 纯 shell 会话不入列：无 agent pane 且会话级无 agentSessionId
            // 时，没有任何 agent 凭据可供去重或跳转，列出只会制造噪声行。
            // （panes 缺失但会话级带 agentSessionId 的形状真实存在，仍兜底。）
            guard let sessionAgentId = session.agentSessionId, !sessionAgentId.isEmpty else {
                return []
            }
            bases = [
                Base(
                    pane: nil,
                    agentSessionId: session.agentSessionId,
                    title: session.title ?? session.name,
                    dir: session.dir,
                    status: session.status,
                    agent: session.agent,
                    tty: session.tty,
                    pid: session.pid,
                    activity: session.activity
                )
            ]
        }

        return bases.enumerated().map { index, base in
            // pane id 缺失（空串）时用序号兜底，保证 ForEach 的 id 唯一
            //（空串会与同会话其它缺 id 的 pane 撞出重复 id）
            let paneKey: String
            if let pane = base.pane, !pane.id.isEmpty {
                paneKey = pane.id
            } else {
                paneKey = "session-\(index)"
            }
            return Row(
                id: "kero:\(host):\(session.id):\(paneKey)",
                host: host,
                hostLabel: hostLabel,
                title: resolvedTitle(title: base.title, dir: base.dir),
                dir: base.dir,
                status: base.status,
                agent: base.agent,
                agentSessionId: base.agentSessionId,
                paneId: base.pane?.id,
                tty: base.tty,
                pid: base.pid,
                activity: base.activity
            )
        }
    }

    /// 标题兜底链：title → name → 目录 basename
    private static func resolvedTitle(title: String?, dir: String?) -> String {
        if let title, !title.isEmpty {
            return title
        }
        if let dir, !dir.isEmpty {
            let base = (dir as NSString).lastPathComponent
            if !base.isEmpty {
                return base
            }
        }
        return "kero 会话"
    }

    /// 由 kero 行构造补充信息
    private static func enrichment(for row: Row) -> Enrichment {
        Enrichment(
            host: row.host,
            hostLabel: row.hostLabel,
            dir: row.dir,
            status: row.status,
            agentSessionId: row.agentSessionId,
            paneId: row.paneId,
            tty: row.tty,
            pid: row.pid
        )
    }
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 列表混排
// ═════════════════════════════════════════════════════════════════

/// kero 行按 activity 混排进现有列表（不新增分区）
nonisolated enum KeroSessionListComposer {

    /// 现有 hook 分组（保持既有相对顺序）
    nonisolated struct HookGroup: Equatable {
        let id: String
        let activity: Date?
    }

    /// 列表条目
    nonisolated enum Entry: Equatable {
        case hook(String)
        case kero(KeroSessionMerger.Row)
    }

    /// 把 kero 行按 activity 插入 hook 分组序列
    /// - Note: hook 分组保持既有相对顺序；kero 行按 activity 降序
    ///         稳定插入其间（activity 相同的按 id 升序保证确定性）。
    static func compose(
        hookGroups: [HookGroup],
        keroRows: [KeroSessionMerger.Row]
    ) -> [Entry] {
        guard !keroRows.isEmpty else {
            return hookGroups.map { .hook($0.id) }
        }

        var pending = keroRows.sorted { lhs, rhs in
            let left = lhs.activity ?? .distantPast
            let right = rhs.activity ?? .distantPast
            if left != right {
                return left > right
            }
            return lhs.id < rhs.id
        }

        var entries: [Entry] = []
        for group in hookGroups {
            let groupActivity = group.activity ?? .distantPast

            // 比当前 hook 分组更新的 kero 行插到它前面
            while let first = pending.first, (first.activity ?? .distantPast) >= groupActivity {
                pending.removeFirst()
                entries.append(.kero(first))
            }
            entries.append(.hook(group.id))
        }

        // 剩余 kero 行（比所有 hook 分组都旧）追加在末尾
        entries.append(contentsOf: pending.map { Entry.kero($0) })
        return entries
    }
}
