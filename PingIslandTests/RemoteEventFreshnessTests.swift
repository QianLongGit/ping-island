import XCTest
@testable import Ping_Island

/// ══════════════════════════════════════════════════════════════════
/// 远程事件回放新鲜度闸门（Task 28）
///
/// 远端 bridge 的持久化 outbox 会在 App 重启/断线重连时一次性回放
/// 离线期间积压的 hook 事件。回放事件只允许更新会话状态（相位、
/// 标题、徽标、列表行），不允许再触发提示类副作用：
///   - 完成通知卡（completed / ended / compacted）
///   - 全部边沿声音（taskCompleted / attentionRequired / …）
/// 判定口径：事件发生时间（occurredAt，由 bridge 在进入转发管线时
/// 打戳）滞后超过阈值 → 过期；occurredAt == nil（旧 bridge / 本地
/// 事件）→ 视为新鲜，按现有行为处理。
/// ══════════════════════════════════════════════════════════════════
final class RemoteEventFreshnessTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    // ── 构造：已完成就绪的远程 Claude 会话 ──────────────────────
    /// `lastActivity` 固定为 now，模拟回放期间接收时间刷新活性的
    /// 真实形态（这正是 60 秒 recency 窗口被击穿的原因）。
    private func completedRemoteSession(
        id: String,
        lastEventOccurredAt: Date?,
        now: Date
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/remote-freshness-\(id)",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            ingress: .remoteBridge,
            pid: nil,
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "\(id)-reply",
                    type: .assistant("remote turn finished"),
                    timestamp: now
                )
            ],
            latestTurnId: "\(id)-turn-1",
            lastActivity: now,
            createdAt: now,
            lastEventOccurredAt: lastEventOccurredAt
        )
    }

    // ── 构造：等待审批的远程会话（attention 边沿用） ─────────────
    private func approvalRemoteSession(
        id: String,
        lastEventOccurredAt: Date?,
        now: Date
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/remote-freshness-\(id)",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            ingress: .remoteBridge,
            pid: nil,
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "\(id)-approval",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: now
            )),
            lastActivity: now,
            createdAt: now,
            lastEventOccurredAt: lastEventOccurredAt
        )
    }

    // ══════════════════ 1. 过期 → 不入队完成卡 ══════════════════

    func testStaleRemoteEventDoesNotQueueCompletionNotification() {
        let stale = completedRemoteSession(
            id: "stale-completion",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        // 回放把接收时间刷成 now；新鲜度闸门必须把过期事件的
        // 完成卡压掉（60 秒窗口本身拦不住 lastActivity = now 的回放）。
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(stale))
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: stale,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true,
            now: reference
        ))
    }

    func testStaleRemoteEventDoesNotQueueEndedNotification() {
        var stale = completedRemoteSession(
            id: "stale-ended",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        stale.phase = .ended
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
            for: stale,
            previousPhase: .waitingForInput,
            isEnabled: true,
            now: reference
        ))
    }

    // ══════════════════ 2. 实时 → 照常入队完成卡 ══════════════════

    func testFreshRemoteEventStillQueuesCompletionNotification() {
        let fresh = completedRemoteSession(
            id: "fresh-completion",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: fresh,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true,
            now: reference
        ))
    }

    // ══════════════════ 3. 过期 → 不产生边沿声音 ══════════════════

    func testStaleRemoteEventProducesNoSoundEdge() {
        var tracker = SessionSoundEdgeTracker()
        let stale = completedRemoteSession(
            id: "stale-sound",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        // 先以 processing 状态建立基线，完成跃变是唯一边沿来源，
        // nil 只能归因于新鲜度闸门（而非 prime 已吸收同一完成键）。
        var baseline = stale
        baseline.phase = .processing
        tracker.prime(with: [baseline])
        XCTAssertNil(tracker.edge(for: [stale], now: reference))

        // 新会话出现边沿（sessionStarted）
        var started = SessionSoundEdgeTracker()
        let staleNewcomer = completedRemoteSession(
            id: "stale-newcomer",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        started.prime(with: [])
        XCTAssertNil(started.edge(for: [staleNewcomer], now: reference))

        // attention 边沿
        var attention = SessionSoundEdgeTracker()
        let staleApproval = approvalRemoteSession(
            id: "stale-attention",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        attention.prime(with: [])
        XCTAssertNil(attention.edge(for: [staleApproval], now: reference))
    }

    func testFreshAndLegacyRemoteEventsStillPlaySoundEdges() {
        // 实时远程事件：滞后 2 秒 → 完成边沿照常（processing 基线 → 完成）
        var tracker = SessionSoundEdgeTracker()
        let fresh = completedRemoteSession(
            id: "fresh-sound",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        var freshBaseline = fresh
        freshBaseline.phase = .processing
        tracker.prime(with: [freshBaseline])
        XCTAssertEqual(tracker.edge(for: [fresh], now: reference)?.event, .taskCompleted)

        // 旧 bridge / 本地事件：occurredAt == nil → 视为新鲜，不得误杀
        var legacy = SessionSoundEdgeTracker()
        let noStamp = completedRemoteSession(id: "legacy-sound", lastEventOccurredAt: nil, now: reference)
        var legacyBaseline = noStamp
        legacyBaseline.phase = .processing
        legacy.prime(with: [legacyBaseline])
        XCTAssertEqual(legacy.edge(for: [noStamp], now: reference)?.event, .taskCompleted)

        // 实时 attention 边沿照常
        var attention = SessionSoundEdgeTracker()
        let freshApproval = approvalRemoteSession(
            id: "fresh-attention",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        attention.prime(with: [])
        XCTAssertEqual(attention.edge(for: [freshApproval], now: reference)?.event, .attentionRequired)
    }

    // ══════════ 4. wire 兼容：旧 bridge 缺 occurredAt → nil ══════════

    func testLegacyPayloadWithoutOccurredAtDecodesAsNil() throws {
        let legacyJSON = """
        {
          "type": "hook_event",
          "payload": {
            "requestID": "11111111-2222-3333-4444-555555555555",
            "sessionID": "legacy-bridge-session",
            "cwd": "/work/project",
            "event": "Stop",
            "status": "waiting_for_input",
            "provider": "claude",
            "expectsResponse": false,
            "clientInfo": {"kind": "claudeCode"}
          }
        }
        """
        let message = try JSONDecoder().decode(RemoteHookEventMessage.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(message.payload.occurredAt)

        let stampedJSON = """
        {
          "type": "hook_event",
          "payload": {
            "requestID": "11111111-2222-3333-4444-555555555555",
            "sessionID": "stamped-session",
            "cwd": "/work/project",
            "event": "Stop",
            "status": "waiting_for_input",
            "provider": "claude",
            "expectsResponse": false,
            "occurredAt": 700000000,
            "clientInfo": {"kind": "claudeCode"}
          }
        }
        """
        let stamped = try JSONDecoder().decode(RemoteHookEventMessage.self, from: Data(stampedJSON.utf8))
        // wire 上 Date 沿用仓库既有风格：Codable 默认编码
        // （secondsSinceReferenceDate 的 Double），与 codexUsage
        // 快照的 capturedAt 同通道同风格。
        XCTAssertEqual(
            stamped.payload.occurredAt,
            Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
    }

    // ════════════ 5. 过期事件仍然更新状态（不丢状态） ════════════

    @MainActor
    func testStaleRemoteEventStillUpdatesSessionState() async throws {
        let id = "stale-state-update-\(UUID().uuidString)"
        let store = SessionStore.shared
        let occurredAt = Date().addingTimeInterval(-3 * 3_600)
        defer { Task { await store.process(.sessionArchived(sessionId: id)) } }

        await store.process(.hookReceived(HookEvent(
            sessionId: id,
            cwd: "/tmp/remote-replay-\(id)",
            event: "Stop",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "replayed remote stop",
            ingress: .remoteBridge,
            occurredAt: occurredAt
        )))

        let updated = await store.session(for: id)
        let session = try XCTUnwrap(updated)
        XCTAssertEqual(session.phase, .waitingForInput)
        // 状态照常：接收时间刷新活性（lastActivity 语义不动）
        XCTAssertGreaterThan(session.lastActivity, occurredAt)
        // 发生时间被记录，供提示类判定做新鲜度闸门
        XCTAssertEqual(session.lastEventOccurredAt, occurredAt)
        // 提示被压：该会话的完成卡不入场队
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true
        ))
    }

    // ══════ 6. attention 链路：tracker 消费不受闸门影响 ══════

    func testAttentionTrackerStillConsumesStaleAttentionEdges() {
        var tracker = SessionManualAttentionTracker()
        let staleApproval = approvalRemoteSession(
            id: "stale-approval-tracker",
            lastEventOccurredAt: Date().addingTimeInterval(-3 * 3_600),
            now: Date()
        )
        // 闸门只压提示（声音/弹卡/自动展开），attention 状态与
        // tracker 的边沿消费必须照常，否则之后空闲会重放旧通知。
        let target = tracker.consumeNewAttentionSession(from: [staleApproval])
        XCTAssertEqual(target?.sessionId, staleApproval.sessionId)

        // 已消费过的边沿不会再次出现（无重放）
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [staleApproval]))
    }

    // ══════════════════════════════════════════════════════
    // FIX-1：跨主机时钟偏移免疫
    //
    // occurredAt 由远端主机时钟产出，而闸门用 App 本机时钟比较。
    // 握手标定偏移（App 时钟 = 远端时钟 + offset），事件入站时把
    // occurredAt 归一化到 App 时钟，闸门保持纯函数的同机比较。
    // ══════════════════════════════════════════════════════

    /// 远端时钟慢 5 分钟：远端"此刻"发生的实时事件，归一化后必须
    /// 仍是新鲜的（否则该主机全部提示被静默掐死）。
    func testClockOffsetNormalizationKeepsLiveRemoteEventsFresh() {
        let appNow = Date()
        let offset: TimeInterval = 5 * 60 // App 时钟 = 远端时钟 + 300s
        // 远端时钟视角的"现在"，即远端实时事件的 occurredAt
        let remoteLiveOccurredAt = appNow.addingTimeInterval(-offset)
        let session = completedRemoteSession(
            id: "offset-live",
            lastEventOccurredAt: RemoteConnectorManager.normalizedOccurredAt(
                remoteLiveOccurredAt, offset: offset
            ),
            now: appNow
        )
        XCTAssertTrue(session.hasFreshNotificationActivity(now: appNow))
    }

    /// 同样带 5 分钟偏移：远端 5 小时前的过期事件，归一化后仍必须
    /// 判为过期（偏移免疫不能放过真正的回放）。
    func testClockOffsetNormalizationStillSuppressesStaleReplays() {
        let appNow = Date()
        let offset: TimeInterval = 5 * 60
        // 远端时钟视角的 5 小时前
        let remoteStaleOccurredAt = appNow.addingTimeInterval(-offset - 5 * 3_600)
        let session = completedRemoteSession(
            id: "offset-stale",
            lastEventOccurredAt: RemoteConnectorManager.normalizedOccurredAt(
                remoteStaleOccurredAt, offset: offset
            ),
            now: appNow
        )
        XCTAssertFalse(session.hasFreshNotificationActivity(now: appNow))
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true,
            now: appNow
        ))
    }

    /// 旧 bridge 无 hello.now → 偏移 0：行为与 T28 现状完全一致。
    func testZeroOffsetKeepsExistingFreshnessBehavior() {
        let appNow = Date()
        let live = completedRemoteSession(
            id: "zero-offset-live",
            lastEventOccurredAt: RemoteConnectorManager.normalizedOccurredAt(
                appNow.addingTimeInterval(-2), offset: 0
            ),
            now: appNow
        )
        XCTAssertTrue(live.hasFreshNotificationActivity(now: appNow))

        let stale = completedRemoteSession(
            id: "zero-offset-stale",
            lastEventOccurredAt: RemoteConnectorManager.normalizedOccurredAt(
                appNow.addingTimeInterval(-3 * 3_600), offset: 0
            ),
            now: appNow
        )
        XCTAssertFalse(stale.hasFreshNotificationActivity(now: appNow))
    }

    // ══════════════════════════════════════════════════════
    // FIX-2：单调取新——过期回放不得覆盖更新的发生时间
    // ══════════════════════════════════════════════════════

    @MainActor
    func testStaleReplayDoesNotOverwriteNewerOccurrenceTime() async throws {
        let id = "monotonic-occurrence-\(UUID().uuidString)"
        let store = SessionStore.shared
        let liveOccurredAt = Date().addingTimeInterval(-2)
        let staleOccurredAt = Date().addingTimeInterval(-3 * 3_600)
        defer { Task { await store.process(.sessionArchived(sessionId: id)) } }

        func send(occurredAt: Date?) async {
            await store.process(.hookReceived(HookEvent(
                sessionId: id,
                cwd: "/tmp/remote-monotonic-\(id)",
                event: "Stop",
                status: "waiting_for_input",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "remote stop",
                ingress: .remoteBridge,
                occurredAt: occurredAt
            )))
        }

        await send(occurredAt: liveOccurredAt)
        // 更早的回放事件随后到达：较新的发生时间必须保留
        await send(occurredAt: staleOccurredAt)

        let updated = await store.session(for: id)
        let session = try XCTUnwrap(updated)
        XCTAssertEqual(session.lastEventOccurredAt, liveOccurredAt)
        XCTAssertTrue(session.hasFreshNotificationActivity())
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true
        ))

        // 本地/未知时间事件（occurredAt == nil）→ 恒新鲜
        await send(occurredAt: nil)
        let afterUnknownOpt = await store.session(for: id)
        let afterUnknown = try XCTUnwrap(afterUnknownOpt)
        XCTAssertNil(afterUnknown.lastEventOccurredAt)
        XCTAssertTrue(afterUnknown.hasFreshNotificationActivity())
    }
}
