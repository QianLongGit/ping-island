import Foundation

/// Turns successive snapshots of the visible session list into semantic sound
/// events.
///
/// A sound must be caused by a session's own state changing. The list handed to the
/// Island is filtered, deduplicated, and sorted first, so a session can enter or
/// leave it for reasons that have nothing to do with that session — see
/// `SameWorkspaceSessionSupersession`. Differencing whole membership sets reads that
/// churn as "a session started processing" and chimes on every flip; the same shape
/// previously fired a spurious cue when a permission round-trip briefly left the set.
///
/// So the tracker records the last known state per `stableId` and keeps that record
/// while the session is missing from the list. Absence is not a state change, which
/// makes list churn inaudible by construction.
///
/// At most one event is emitted per snapshot, highest severity first, and it carries
/// only the sessions that actually crossed the edge so the focus-based mute in the
/// callers is evaluated against the terminals that caused the sound.
struct SessionSoundEdgeTracker {
    struct Edge: Equatable {
        let event: AppSoundFeedbackEvent
        let sessions: [SessionState]
    }

    /// The sound-relevant state of a single session at one point in time.
    private struct Snapshot {
        var isProcessing: Bool
        var needsAttention: Bool
        var completionKey: SessionCompletionKey?
        var isResourceLimited: Bool
        var errorToolIDs: Set<String>

        init(_ session: SessionState) {
            isProcessing = session.contributesToProcessingSoundEdge
            needsAttention = SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
            completionKey = SessionCompletionKey.make(for: session)
            isResourceLimited = session.phase == .compacting
            errorToolIDs = session.completedErrorToolIDs
        }
    }

    private struct Record {
        var snapshot: Snapshot
        var lastSeenSequence: UInt64
    }

    /// Cap on retained records so a long-running app cannot accumulate one entry per
    /// session seen since launch. Only records for sessions that are currently absent
    /// from the list are evicted, oldest first.
    private let retainedSessionLimit: Int
    private var records: [String: Record] = [:]
    private var playedCompletionKeys = Set<SessionCompletionKey>()
    private var rapidSubmitTracker = RapidSubmitSoundTracker()
    private var sequence: UInt64 = 0
    private var hasPrimed = false

    // ─────────────────────────────────────────────────
    // 提示洪峰治理状态（Task 31）
    // ─────────────────────────────────────────────────
    /// 冷却时钟与启动期「首次发现」窗口的起点（默认即创建时刻）
    private let startedAt: Date
    /// 最近一次实际发声的完成边沿时刻（F4）
    private var lastCompletionSoundAt: Date?
    /// 自上次完成发声以来被冷却抑制的完成数（仅用于决策日志）
    private var cooldownSuppressedCount = 0
    /// 决策日志出口（Task 31 · F6），可注入以便单测
    private let trace: (String) -> Void
    /// 节流开关（冷却 / 首次发现）；回放闸门不受它影响
    private let isPacingEnabled: Bool

    init(
        retainedSessionLimit: Int = 512,
        pacingEnabled: Bool = NotificationPacing.isPacingEnabledByDefault,
        startedAt: Date = Date(),
        trace: @escaping (String) -> Void = { NotifyTrace.emit($0) }
    ) {
        self.retainedSessionLimit = max(1, retainedSessionLimit)
        self.isPacingEnabled = pacingEnabled
        self.startedAt = startedAt
        self.trace = trace
    }

    var isPrimed: Bool { hasPrimed }

    /// Adopt the current state without emitting anything, so sessions that already
    /// exist when a surface appears do not chime retroactively.
    mutating func prime(with sessions: [SessionState]) {
        hasPrimed = true
        _ = rapidSubmitTracker.observe(sessions)
        absorb(sessions)
    }

    /// Record `sessions` and return the single sound edge they crossed, if any.
    ///
    /// ══════════════════════════════════════════════════════════════════
    /// 提示闸门（只压提示，不改状态记录）：
    ///
    /// - 过期（Task 28）：`lastEventOccurredAt` 滞后超过阈值的远程会话
    ///   （离线 outbox 回放）不进入任何边沿桶。
    /// - 回放（Task 31 · F8）：`lastEventIsReplay` 的会话不产生完成 /
    ///   churn 类边沿——断连重连后整批积压把会话重新置为 connected，
    ///   不再被读成 processingStarted / sessionStarted / taskCompleted。
    ///   例外是 attention：尚未答复的审批 / 追问在重连后仍需提醒，只受
    ///   上面的 120 秒过期闸门约束，绝不被无声吞掉。
    /// - 冷却（Task 31 · F4）：完成边沿全局 2 秒冷却，attention /
    ///   干预类严重度更高、天然插队。
    /// - 首次发现（Task 31 · F5）：启动后 5 秒内首次发现、且一出现就是
    ///   完成态的本地会话不响（列表发现，不是真实完成）。
    ///
    /// `absorb` 无条件执行：被压掉的 completionKey 照常登记，后续同一
    /// 完成键的重放不会重复响。
    /// ══════════════════════════════════════════════════════════════════
    mutating func edge(for sessions: [SessionState], now: Date = Date()) -> Edge? {
        guard hasPrimed else {
            prime(with: sessions)
            return nil
        }

        var errorSessions: [SessionState] = []
        var resourceLimitSessions: [SessionState] = []
        var attentionSessions: [SessionState] = []
        var completedSessions: [SessionState] = []
        var processingSessions: [SessionState] = []
        let connectedSessions = sessions.filter { $0.connectionState == .connected }
        let notificationFresh = connectedSessions.filter { $0.hasFreshNotificationActivity(now: now) }
        // ── 逐会话静默原因：回放（F8 / F2）或启动期首次发现（F5）。
        //    被静默的会话不进任何边沿桶（「只登记状态」），避免完成边沿
        //    被压掉后又以 sessionStarted 的形式响出来。attention 例外。──
        var silenceReasons: [String: NotifySuppressReason] = [:]
        for session in notificationFresh {
            if case .suppress(let reason) = NotificationPacing.completionSoundDecision(
                isReplay: session.lastEventIsReplay,
                isRemote: session.ingress == .remoteBridge,
                isFirstDiscovery: records[session.stableId] == nil,
                trackerStartedAt: startedAt,
                now: now,
                isPacingEnabled: isPacingEnabled
            ) {
                silenceReasons[session.stableId] = reason
            }
        }
        let liveSessions = notificationFresh.filter { silenceReasons[$0.stableId] == nil }
        let newSessions = liveSessions.filter { records[$0.stableId] == nil }
        let rapidSubmitSessions = rapidSubmitTracker.observe(liveSessions)

        for session in notificationFresh {
            let previous = records[session.stableId]?.snapshot
            let current = Snapshot(session)
            let silenceReason = silenceReasons[session.stableId]

            if silenceReason == nil,
               !current.errorToolIDs.subtracting(previous?.errorToolIDs ?? []).isEmpty {
                errorSessions.append(session)
            }
            if silenceReason == nil, current.isResourceLimited, previous?.isResourceLimited != true {
                resourceLimitSessions.append(session)
            }
            if current.needsAttention, previous?.needsAttention != true {
                attentionSessions.append(session)
            }
            if let completionKey = current.completionKey,
               !playedCompletionKeys.contains(completionKey) {
                if let silenceReason {
                    trace(line(session, .suppress(silenceReason), now: now))
                } else {
                    completedSessions.append(session)
                }
            }
            if silenceReason == nil, current.isProcessing, previous?.isProcessing != true {
                processingSessions.append(session)
            }
        }

        absorb(sessions)

        // ── F4 完成声音冷却：窗口内不响，状态已由 absorb 记录 ──
        if isPacingEnabled, !completedSessions.isEmpty {
            if NotificationPacing.isCompletionSoundCoolingDown(
                lastPlayedAt: lastCompletionSoundAt,
                now: now
            ) {
                cooldownSuppressedCount += completedSessions.count
                for session in completedSessions {
                    trace(line(session, .suppress(.cooldown), now: now))
                }
                // 完成边沿优先级高于 sessionStarted 等低阶边沿：被冷却
                // 压掉后不再顺延给它们，否则冷却窗口里仍有声音。
                return nil
            } else {
                lastCompletionSoundAt = now
            }
        }

        let edge: Edge?
        if !errorSessions.isEmpty {
            edge = Edge(event: .taskError, sessions: errorSessions)
        } else if !resourceLimitSessions.isEmpty {
            edge = Edge(event: .resourceLimit, sessions: resourceLimitSessions)
        } else if !attentionSessions.isEmpty {
            edge = Edge(event: .attentionRequired, sessions: attentionSessions)
        } else if !completedSessions.isEmpty {
            edge = Edge(event: .taskCompleted, sessions: completedSessions)
        } else if !newSessions.isEmpty {
            edge = Edge(event: .sessionStarted, sessions: newSessions)
        } else if !processingSessions.isEmpty {
            edge = Edge(event: .processingStarted, sessions: processingSessions)
        } else if !rapidSubmitSessions.isEmpty {
            edge = Edge(event: .rapidSubmit, sessions: rapidSubmitSessions)
        } else {
            edge = nil
        }
        if let edge {
            trace(NotificationPacing.decisionLine(
                surface: .sound,
                sessionID: edge.sessions.first?.sessionId ?? "",
                kind: String(describing: edge.event),
                decision: .notify,
                occurredAt: nil,
                now: now,
                suppressedCount: edge.event == .taskCompleted ? cooldownSuppressedCount : 0
            ))
            if edge.event == .taskCompleted {
                cooldownSuppressedCount = 0
            }
        }
        return edge
    }

    // ─────────────────────────────────────────────────
    // 决策日志行（Task 31 · F6）：kind 取完成卡语义的 completed
    // ─────────────────────────────────────────────────
    private func line(
        _ session: SessionState,
        _ decision: NotifyDecision,
        now: Date
    ) -> String {
        NotificationPacing.decisionLine(
            surface: .sound,
            sessionID: session.sessionId,
            kind: "completed",
            decision: decision,
            occurredAt: session.lastEventOccurredAt,
            now: now,
            suppressedCount: cooldownSuppressedCount
        )
    }

    private mutating func absorb(_ sessions: [SessionState]) {
        sequence &+= 1

        for session in sessions {
            var snapshot = Snapshot(session)
            if let existing = records[session.stableId]?.snapshot {
                // Failed tool IDs only ever accumulate on a session; keep the ones
                // already announced so a rebuilt session cannot replay them.
                snapshot.errorToolIDs.formUnion(existing.errorToolIDs)
            }
            if let completionKey = snapshot.completionKey {
                playedCompletionKeys.insert(completionKey)
            }
            records[session.stableId] = Record(snapshot: snapshot, lastSeenSequence: sequence)
        }

        pruneRetainedRecords(visible: sessions)
    }

    private mutating func pruneRetainedRecords(visible: [SessionState]) {
        guard records.count > retainedSessionLimit else { return }

        let visibleIDs = Set(visible.map(\.stableId))
        let evictionOrder = records
            .filter { !visibleIDs.contains($0.key) }
            .sorted { $0.value.lastSeenSequence < $1.value.lastSeenSequence }

        var overflow = records.count - retainedSessionLimit
        for entry in evictionOrder {
            guard overflow > 0 else { break }
            records.removeValue(forKey: entry.key)
            overflow -= 1
        }
    }
}
