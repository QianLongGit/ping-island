//
//  KeroInventoryModels.swift
//  PingIsland
//
//  T25「kero 会话清单补全」：kero CLI 会话清单的纯数据模型与容错解码。
//
//  数据来源：`kero ls --json -a`（按主机分组的完整形状）与
//  `kero ls --json`（扁平形状）。两种形状都要能解，且对缺失字段
//  零容忍——kero 的字段集随版本漂移（records/progress/restored/
//  cols/rows/pin/lead/focus 均可能缺省），解析层只取本功能真正
//  需要的字段，其余一律忽略。
//
//  时间戳单位为 Unix 毫秒（kero 侧 `activity`/`created`/`since`
//  均为毫秒整数）。
//

import Foundation

// ═════════════════════════════════════════════════════════════════
// MARK: - 数据模型
// ═════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────
// 隔离说明：本文件全部类型标记 nonisolated——解码与合并要跑在
// KeroInventoryService 的后台 Task 里，不能被工程的默认 MainActor
// 隔离（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）拖回主线程。
// ─────────────────────────────────────────────────────────────────

/// kero 的 agent 会话凭据（AgentSession）
/// - `id` 即跨主机唯一的 AgentSession.ID，kero 跳转协议用它做
///   精确匹配（`kero://focus?session=<uuid>`）
nonisolated struct KeroAgentSession: Equatable {
    let agent: String?
    let id: String
}

/// kero pane —— 终端分屏，kero 会话的真实执行单元
/// - `agentSessionId` 可能缺失（该 pane 只跑了普通 shell）
nonisolated struct KeroPane: Equatable {
    let id: String
    let title: String?
    let dir: String?
    let status: String?
    let agent: String?
    let agentSessionId: String?
    let tty: String?
    let pid: Int?
    let activity: Date?
    let created: Date?
}

/// kero 会话 —— 一个窗口内的 pane 组
/// - `agentSessionId` 与 lead pane 的 agentSession.id 同源（重复信息）
nonisolated struct KeroSession: Equatable {
    let id: String
    let name: String?
    let title: String?
    let dir: String?
    let project: String?
    let status: String?
    let agent: String?
    let agentSessionId: String?
    let tty: String?
    let pid: Int?
    let activity: Date?
    let created: Date?
    let panes: [KeroPane]
}

/// 单台主机上的 kero 会话清单
/// - `host` 为 kero 侧的主机别名（"local" / "Home" / "165" …）
nonisolated struct KeroHostInventory: Equatable {
    let host: String
    let sessions: [KeroSession]
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 解析错误
// ═════════════════════════════════════════════════════════════════

nonisolated enum KeroInventoryError: Error {
    /// kero 二进制不存在（未安装 / 不在探测路径上）
    case binaryNotFound
    /// `kero ls --json -a` 执行超时
    case timedOut
    /// 返回体不是合法 JSON
    case malformedPayload
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 容错解码
// ═════════════════════════════════════════════════════════════════

nonisolated enum KeroInventoryDecoder {

    /// 解析 kero 会话清单 JSON
    /// - Parameter data: `kero ls --json -a` 或 `kero ls --json` 的原始返回体
    /// - Returns: 按主机分组的会话清单
    /// - Throws: `KeroInventoryError.malformedPayload`（JSON 非法或形状不可识别）
    static func decode(_ data: Data) throws -> [KeroHostInventory] {
        guard !data.isEmpty else {
            throw KeroInventoryError.malformedPayload
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KeroInventoryError.malformedPayload
        }

        // ── 形状一：host 分组（`kero ls --json -a`） ──────────────────
        if let elements = root as? [Any] {
            let grouped = elements.compactMap { element -> KeroHostInventory? in
                guard let dict = element as? [String: Any],
                      let rawSessions = dict["sessions"] as? [Any] else {
                    return nil
                }
                return KeroHostInventory(
                    host: nonEmptyString(dict["host"]) ?? "local",
                    sessions: rawSessions.compactMap { parseSession($0) }
                )
            }
            if !grouped.isEmpty {
                return grouped
            }

            // ── 形状二：扁平 session 数组（`kero ls --json`） ──────────
            // 没有 id 的条目是形状噪声（如 host 分组对象被误投到这里），
            // 先过滤再判空——全被过滤则按不可识别形状抛错，由 Reader
            // 降级为空清单，绝不产出 id 为空串的幽灵行。
            let sessions = elements.compactMap { parseSession($0) }
                .filter { !$0.id.isEmpty }
            guard !sessions.isEmpty else {
                throw KeroInventoryError.malformedPayload
            }
            return [KeroHostInventory(host: "local", sessions: sessions)]
        }

        // ── 形状三：单对象（{"host": ..., "sessions": [...]}） ────────
        if let dict = root as? [String: Any],
           let rawSessions = dict["sessions"] as? [Any] {
            return [
                KeroHostInventory(
                    host: nonEmptyString(dict["host"]) ?? "local",
                    sessions: rawSessions.compactMap { parseSession($0) }
                )
            ]
        }

        throw KeroInventoryError.malformedPayload
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 字段解析
    // ═════════════════════════════════════════════════════════════

    /// 解析单个 session 对象
    private static func parseSession(_ value: Any) -> KeroSession? {
        guard let dict = value as? [String: Any] else { return nil }
        let agentSession = dict["agentSession"] as? [String: Any]

        return KeroSession(
            id: nonEmptyString(dict["id"]) ?? "",
            name: nonEmptyString(dict["name"]),
            title: nonEmptyString(dict["title"]),
            dir: nonEmptyString(dict["dir"]),
            project: nonEmptyString(dict["project"]),
            status: nonEmptyString(dict["status"]),
            agent: nonEmptyString(dict["agent"]) ?? agentSession.flatMap { nonEmptyString($0["agent"]) },
            agentSessionId: agentSession.flatMap { nonEmptyString($0["id"]) },
            tty: nonEmptyString(dict["tty"]),
            pid: integerValue(dict["pid"]),
            activity: dateValue(dict["activity"]),
            created: dateValue(dict["created"]),
            panes: (dict["panes"] as? [Any] ?? []).compactMap { parsePane($0) }
        )
    }

    /// 解析单个 pane 对象
    private static func parsePane(_ value: Any) -> KeroPane? {
        guard let dict = value as? [String: Any] else { return nil }
        let agentSession = dict["agentSession"] as? [String: Any]

        return KeroPane(
            id: nonEmptyString(dict["id"]) ?? "",
            title: nonEmptyString(dict["title"]),
            dir: nonEmptyString(dict["dir"]),
            status: nonEmptyString(dict["status"]),
            agent: nonEmptyString(dict["agent"]) ?? agentSession.flatMap { nonEmptyString($0["agent"]) },
            agentSessionId: agentSession.flatMap { nonEmptyString($0["id"]) },
            tty: nonEmptyString(dict["tty"]),
            pid: integerValue(dict["pid"]),
            activity: dateValue(dict["activity"]),
            created: dateValue(dict["created"])
        )
    }

    /// 取非空字符串（kero 里空串等价于缺失）
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 取整数（JSON 数字可能是 Double）
    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let double = value as? Double {
            return Int(double)
        }
        return nil
    }

    /// 取时间（kero 用 Unix 毫秒整数；字符串时按 ISO8601 兜底）
    private static func dateValue(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let milliseconds = number.doubleValue
            // 毫秒与秒双判：> 1e11 视为毫秒
            return milliseconds > 100_000_000_000
                ? Date(timeIntervalSince1970: milliseconds / 1000)
                : Date(timeIntervalSince1970: milliseconds)
        }
        if let text = value as? String {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}
