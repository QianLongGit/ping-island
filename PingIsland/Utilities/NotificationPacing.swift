//
//  NotificationPacing.swift
//  PingIsland
//
//  完成提示洪峰治理（Task 31）：节流参数表 + 纯决策函数。
//
//  App 隔一段时间再打开 / 睡眠唤醒 / 远程重连后，离线积压的 hook 事件会
//  一次性回放（实测约 4,100 条 / 11 秒），完成弹窗连闪、提示音连响。
//  这里集中放全部节流参数与不依赖 UI 的判定函数：
//
//    - F8 / F2  回放判定：以握手为界（留容差）；对端支持时间戳却
//               没带戳的事件同为回放
//    - F3       完成卡 TTL / 最小弹出间隔 / 同批合并
//    - F4       完成声音全局冷却（attention 类不参与）
//    - F5       启动期「首次发现」收敛
//    - F6       决策追踪日志的字面量与行格式
//
//  只压提示，不改状态更新，也不参与 completionKey 的去重语义。参数不设
//  用户可见设置项，后续按反馈在下方参数表直接调整。
//
//  本文件只依赖 Foundation，全部是无副作用纯函数：输入是时间与计数，
//  输出是决策，便于单测锁死每一条规则。
//

import Foundation

// ═══════════════════════════════════════════════════════════════
// MARK: - 节流参数表（唯一调整入口）
// ═══════════════════════════════════════════════════════════════
nonisolated enum NotificationPacing {
    /// F8 / F10 握手容差：occurredAt 早于「握手时刻 − 容差」才判回放，
    /// 吸收 hello 与首批实时事件之间的毫秒级竞态
    private static let replayBoundaryTolerance: TimeInterval = 2
    /// F3.1 完成卡 TTL：完成时刻距今超过该值不再入队 / 出队
    private static let completionCardTTL: TimeInterval = 60
    /// F3.2 完成卡最小弹出间隔：距上一张「已弹出」的卡片不足该值则抑制
    private static let completionCardMinInterval: TimeInterval = 60
    /// F3.3 同批合并阈值：同一出队批次达到该张数只出首张，其余并入计数
    private static let completionCardBatchMergeThreshold = 3
    /// F4 完成声音全局冷却窗口
    private static let completionSoundCooldown: TimeInterval = 2
    /// F5 启动期「首次发现」收敛窗口
    private static let firstDiscoveryGrace: TimeInterval = 5

    // ─────────────────────────────────────────────────
    // 节流开关的默认值
    //
    // 节流按真实时钟计量（60s / 2s / 5s）。既有测试套件用合成时钟在
    // 毫秒内连续制造多次完成，那不是节流要治理的洪峰形态；因此测试
    // 进程内默认关闭，节流用例显式传 pacingEnabled: true 打开。
    // 回放判定（F8 / F2）不属于节流，始终生效。
    // ─────────────────────────────────────────────────
    nonisolated static var isPacingEnabledByDefault: Bool {
        Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    // ═════════════════════════════════════════════════════════
    // MARK: - F8 / F2 · 回放判定（以握手为界）
    // ═════════════════════════════════════════════════════════
    /// 判定顺序：
    ///
    /// 1. 尚未握手（无 lastConnectedAt）→ 不判回放。
    /// 2. 无戳事件：对端支持时间戳 ⇒ 回放（旧 bridge 写下的 outbox
    ///    积压）；旧 bridge 保持兼容，视为实时。
    /// 3. 带戳事件（已归一化到 App 时钟）：早于「握手时刻 − 容差」⇒
    ///    回放。bridge 先发 hello 再冲刷 outbox，积压事件必然早于握手。
    nonisolated static func isReplayedBeforeAttach(
        occurredAt: Date?,
        supportsEventTimestamps: Bool,
        connectedAt: Date?
    ) -> Bool {
        guard let connectedAt else { return false }
        guard let occurredAt else { return supportsEventTimestamps }
        return occurredAt < connectedAt.addingTimeInterval(-replayBoundaryTolerance)
    }

    // ═════════════════════════════════════════════════════════
    // MARK: - F3 · 完成卡节流
    // ═════════════════════════════════════════════════════════
    /// 入队准入：TTL 先于最小间隔——过期的完成不占用播报名额。
    ///
    /// - completionOccurredAt: 完成时刻（远程取事件自身时间）；nil 时
    ///   退回入队时刻
    /// - lastPresentedAt: 上一张「已弹出」卡片的出队时刻；nil 表示尚未弹过
    nonisolated static func completionCardAdmission(
        completionOccurredAt: Date?,
        queuedAt: Date,
        lastPresentedAt: Date?,
        now: Date
    ) -> NotifyDecision {
        if isCompletionCardExpired(completionOccurredAt: completionOccurredAt, queuedAt: queuedAt, now: now) {
            return .suppress(.ttlExpired)
        }
        if let lastPresentedAt,
           now.timeIntervalSince(lastPresentedAt) < completionCardMinInterval {
            return .suppress(.minInterval)
        }
        return .notify
    }

    /// 完成卡是否已过 TTL（入队与出队共用）。
    nonisolated static func isCompletionCardExpired(
        completionOccurredAt: Date?,
        queuedAt: Date,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(completionOccurredAt ?? queuedAt) > completionCardTTL
    }

    /// 同一出队批次是否只出首张。
    nonisolated static func mergesCompletionCardBatch(pendingCount: Int) -> Bool {
        pendingCount >= completionCardBatchMergeThreshold
    }

    // ═════════════════════════════════════════════════════════
    // MARK: - F4 · 完成声音冷却
    // ═════════════════════════════════════════════════════════
    /// 只约束完成类边沿。error / resourceLimit / attention 严重度更高，
    /// 由调用方在冷却判定之前返回，天然插队。
    nonisolated static func isCompletionSoundCoolingDown(
        lastPlayedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastPlayedAt else { return false }
        return now.timeIntervalSince(lastPlayedAt) < completionSoundCooldown
    }

    // ═════════════════════════════════════════════════════════
    // MARK: - F5 · 启动期「首次发现」收敛
    // ═════════════════════════════════════════════════════════
    /// 完成边沿的逐会话决策：回放先行，其次才是首次发现收敛。
    ///
    /// 收敛只针对「启动后首次发现、且一出现就是完成态」的本地会话——
    /// 这是列表发现（Codex thread/list、Claude Desktop 逐条 publish），
    /// 不是一次真实完成。会话先以运行态出现、随后完成的照常响，所以
    /// 它不是启动静默窗口。远程会话走 F8 / F2，不在此收敛。
    nonisolated static func completionSoundDecision(
        isReplay: Bool,
        isRemote: Bool,
        isFirstDiscovery: Bool,
        trackerStartedAt: Date,
        now: Date,
        isPacingEnabled: Bool
    ) -> NotifyDecision {
        if isReplay {
            return .suppress(.replay)
        }
        let elapsedSinceStart = now.timeIntervalSince(trackerStartedAt)
        if isPacingEnabled,
           !isRemote,
           isFirstDiscovery,
           elapsedSinceStart >= 0,
           elapsedSinceStart < firstDiscoveryGrace {
            return .suppress(.firstDiscovery)
        }
        return .notify
    }

    // ═════════════════════════════════════════════════════════
    // MARK: - F6 · 决策日志行
    // ═════════════════════════════════════════════════════════
    /// 一条决策一行，字段顺序固定，便于当时间轴读：
    ///
    ///     notify surface=card session=1a2b3c4d kind=completed decision=suppress
    ///           reason=min-interval lag=12s suppressed=3
    ///
    /// - session: 8 位短 id（与 IslandTrace.tag、bridge 调试日志同一口径）
    /// - kind:    completed / ended / compacted（卡）或声音事件名
    /// - reason:  fresh 或 NotifySuppressReason.rawValue
    /// - lag:     now − 事件时刻；无戳为 none
    nonisolated static func decisionLine(
        surface: NotifySurface,
        sessionID: String,
        kind: String,
        decision: NotifyDecision,
        occurredAt: Date?,
        now: Date,
        suppressedCount: Int
    ) -> String {
        let reason: String
        switch decision {
        case .notify:
            reason = "fresh"
        case .suppress(let suppressReason):
            reason = suppressReason.rawValue
        }
        let lag = occurredAt.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "none"
        return [
            "notify",
            "surface=\(surface.rawValue)",
            "session=\(sessionID.prefix(8))",
            "kind=\(kind.replacingOccurrences(of: " ", with: "_"))",
            "decision=\(decision == .notify ? "notify" : "suppress")",
            "reason=\(reason)",
            "lag=\(lag)",
            "suppressed=\(suppressedCount)"
        ].joined(separator: " ")
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - 决策词汇表
// ═══════════════════════════════════════════════════════════════

/// 提示被抑制的原因；rawValue 即决策日志的 reason 字面量。
nonisolated enum NotifySuppressReason: String, Equatable, Sendable {
    /// 回放：事件在本次远程握手之前就已发生（F8），或对端支持
    /// 时间戳却没带戳（F2）
    case replay
    /// 会话级最新事件滞后超过阈值（Task 28）
    case staleEvent = "stale-event"
    /// 完成声音处于全局冷却窗口（F4）
    case cooldown
    /// 距上一张已弹出的完成卡不足最小间隔（F3.2）
    case minInterval = "min-interval"
    /// 同批合并进首张卡片（F3.3）
    case batchMerge = "batch-merge"
    /// 完成时刻距今超过卡片 TTL（F3.1）
    case ttlExpired = "ttl-expired"
    /// 启动期首次发现的本地会话，只登记状态（F5）
    case firstDiscovery = "first-discovery"
}

/// 一次提示决策：放行，或带原因的抑制。
nonisolated enum NotifyDecision: Equatable, Sendable {
    case notify
    case suppress(NotifySuppressReason)
}

/// 决策所属的提示面：完成卡 / 声音。
nonisolated enum NotifySurface: String, Sendable {
    case card
    case sound
}
