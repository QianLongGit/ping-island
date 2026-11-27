import XCTest
@testable import Ping_Island

/// ══════════════════════════════════════════════════════════════════
/// 完成提示洪峰治理（Task 31）
///
/// 场景：远程主机重连后一次性回放数千条离线积压的 hook 事件，完成
/// 弹窗连闪、提示音连响。这里按规则逐条固化：
///
///   F8  以握手为界判定回放：只更新状态，不弹卡、不响、无重连 churn
///   F2  对端支持时间戳却没带戳 ⇒ 同为回放；旧 bridge 保持兼容
///   F3  完成卡 TTL / 最小弹出间隔 / 同批合并
///   F4  完成声音冷却（attention 可插队）
///   F5  启动期「首次发现」收敛
///   F6  决策日志
/// ══════════════════════════════════════════════════════════════════
@MainActor
final class CompletionNotificationFloodTests: XCTestCase {

    /// 纯逻辑用例的固定时钟（早于任何 tracker 的创建时刻）
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    // ── 构造：远程 hook 事件 ──────────────────────────────────
    /// `isReplay` 由 RemoteConnectorManager 在入站时推断，这里直接给定。
    private func remoteEvent(
        _ event: String,
        status: String,
        sessionID: String,
        occurredAt: Date?,
        isReplay: Bool = false
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionID,
            cwd: "/tmp/remote-flood-\(sessionID)",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .remoteBridge,
            occurredAt: occurredAt,
            isReplay: isReplay
        )
    }

    // ── 构造：完成就绪的会话 ──────────────────────────────────
    private func completedSession(
        id: String,
        ingress: SessionIngress = .remoteBridge,
        isReplay: Bool = false,
        lastEventOccurredAt: Date? = nil,
        turnID: String? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/flood-\(id)",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            ingress: ingress,
            phase: .waitingForInput,
            latestTurnId: turnID ?? "\(id)-turn-1",
            lastActivity: reference,
            createdAt: reference,
            lastEventOccurredAt: lastEventOccurredAt,
            lastEventIsReplay: isReplay
        )
    }

    private func processingSession(id: String, ingress: SessionIngress = .hookBridge, isReplay: Bool = false) -> SessionState {
        var session = completedSession(id: id, ingress: ingress, isReplay: isReplay)
        session.phase = .processing
        return session
    }

    private func approvalSession(id: String, isReplay: Bool = false) -> SessionState {
        var session = completedSession(
            id: id, isReplay: isReplay, lastEventOccurredAt: isReplay ? reference : nil
        )
        session.phase = .waitingForApproval(PermissionContext(
            toolUseId: "\(id)-approval",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: reference
        ))
        return session
    }

    // ── 构造：完成卡 ──────────────────────────────────────────
    private func card(_ id: String, completedAt: Date) -> SessionCompletionNotification {
        SessionCompletionNotification(
            session: completedSession(id: id, lastEventOccurredAt: completedAt),
            kind: .completed,
            queuedAt: completedAt
        )
    }

    private func archive(_ id: String, in store: SessionStore) {
        Task { await store.process(.sessionArchived(sessionId: id)) }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F8 回放：只更新状态，不产生提示
    // ══════════════════════════════════════════════════════════

    /// 批次尾部的「新鲜尾巴」：事件只滞后 10 秒，Task 28 的 120 秒
    /// 闸门拦不住，但它是握手之前的积压——状态照常，提示全压。
    func testF8ReplayedCompletionUpdatesStateButProducesNoCardOrSound() async throws {
        let id = "flood-replay-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { archive(id, in: store) }

        await store.process(.hookReceived(remoteEvent(
            "Stop", status: "waiting_for_input", sessionID: id,
            occurredAt: Date().addingTimeInterval(-10), isReplay: true
        )))
        let snapshot = await store.session(for: id)
        let session = try XCTUnwrap(snapshot)

        XCTAssertEqual(session.phase, .waitingForInput)
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
        XCTAssertTrue(session.lastEventIsReplay)
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true
        ))

        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        XCTAssertNil(tracker.edge(for: [session]))
    }

    /// 握手之后发生的实时完成：一切照旧。
    func testF8LiveCompletionAfterHandshakeStillNotifies() async throws {
        let id = "flood-live-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { archive(id, in: store) }

        await store.process(.hookReceived(remoteEvent(
            "Stop", status: "waiting_for_input", sessionID: id,
            occurredAt: Date().addingTimeInterval(-1), isReplay: false
        )))
        let snapshot = await store.session(for: id)
        let session = try XCTUnwrap(snapshot)

        XCTAssertFalse(session.lastEventIsReplay)
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .processing,
            previousCompletionKey: nil,
            isEnabled: true
        ))

        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        XCTAssertEqual(tracker.edge(for: [session])?.event, .taskCompleted)
    }

    /// 标记跟随最近一条事件：积压放完之后到来的实时事件解除回放态。
    func testF8ReplayFlagFollowsTheLatestEvent() async throws {
        let id = "flood-then-live-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { archive(id, in: store) }

        await store.process(.hookReceived(remoteEvent(
            "Stop", status: "waiting_for_input", sessionID: id,
            occurredAt: Date().addingTimeInterval(-600), isReplay: true
        )))
        let replayedSnapshot = await store.session(for: id)
        XCTAssertTrue(try XCTUnwrap(replayedSnapshot).lastEventIsReplay)

        await store.process(.hookReceived(remoteEvent(
            "PostToolUse", status: "processing", sessionID: id,
            occurredAt: Date(), isReplay: false
        )))
        let liveSnapshot = await store.session(for: id)
        let session = try XCTUnwrap(liveSnapshot)
        XCTAssertFalse(session.lastEventIsReplay)
        XCTAssertEqual(session.phase, .processing)
    }

    /// 重连 churn：积压事件把会话重新置为 connected / processing，
    /// 不得被读成 sessionStarted / processingStarted / taskCompleted。
    func testF8ReconnectChurnRaisesNoEdge() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        XCTAssertNil(tracker.edge(for: [processingSession(id: "churn", isReplay: true)]))
        XCTAssertNil(tracker.edge(for: [completedSession(id: "churn", isReplay: true)]))
        XCTAssertNil(tracker.edge(for: [completedSession(id: "churn-new", isReplay: true)]))
    }

    /// 审批 / 追问不得被无声吞掉：握手前 60 秒到达、仍未答复的审批
    /// 虽是回放，只要没过 120 秒过期线，attention 边沿照常。
    func testF8PendingApprovalIsNeverSilentlyDropped() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        var fresh = approvalSession(id: "approval-fresh", isReplay: true)
        fresh.lastEventOccurredAt = reference.addingTimeInterval(-60)
        XCTAssertEqual(tracker.edge(for: [fresh], now: reference)?.event, .attentionRequired)

        // 真正过期的仍按 0.33.9 的规则不提示
        var staleTracker = SessionSoundEdgeTracker(pacingEnabled: true)
        staleTracker.prime(with: [])
        var stale = approvalSession(id: "approval-stale", isReplay: true)
        stale.lastEventOccurredAt = reference.addingTimeInterval(-3 * 3_600)
        XCTAssertNil(staleTracker.edge(for: [stale], now: reference))
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F8 / F2 回放判定（纯函数）
    // ══════════════════════════════════════════════════════════

    func testReplayBoundaryIsTheHandshakeWithTolerance() {
        func isReplay(_ occurredAt: Date?) -> Bool {
            NotificationPacing.isReplayedBeforeAttach(
                occurredAt: occurredAt,
                supportsEventTimestamps: true,
                connectedAt: reference
            )
        }

        // 握手前的积压 → 回放
        XCTAssertTrue(isReplay(reference.addingTimeInterval(-3)))
        XCTAssertTrue(isReplay(reference.addingTimeInterval(-3 * 3_600)))
        // 容差内（毫秒级竞态）按实时处理
        XCTAssertFalse(isReplay(reference.addingTimeInterval(-2)))
        XCTAssertFalse(isReplay(reference.addingTimeInterval(-1)))
        XCTAssertFalse(isReplay(reference))
        XCTAssertFalse(isReplay(reference.addingTimeInterval(5)))

        // F2：对端支持时间戳却没带戳 → 回放；旧 bridge → 实时
        XCTAssertTrue(isReplay(nil))
        XCTAssertFalse(NotificationPacing.isReplayedBeforeAttach(
            occurredAt: nil, supportsEventTimestamps: false, connectedAt: reference
        ))
        // 尚未握手 → 不判回放
        XCTAssertFalse(NotificationPacing.isReplayedBeforeAttach(
            occurredAt: reference.addingTimeInterval(-600), supportsEventTimestamps: true, connectedAt: nil
        ))
    }

    /// 入站全链路：wire 载荷 + 端点（时钟偏移 / 能力位 / 握手时刻）→
    /// 归一化后的 occurredAt 与回放标记。
    func testInboundReplayContextClassifiesWirePayload() throws {
        func payload(occurredAtJSON: String?) throws -> RemoteHookEventPayload {
            let stamp = occurredAtJSON.map { "\"occurredAt\": \($0)," } ?? ""
            let json = """
            {
              "type": "hook_event",
              "payload": {
                "requestID": "11111111-2222-3333-4444-555555555555",
                "sessionID": "replay-context",
                "cwd": "/work/project",
                "event": "Stop",
                "status": "waiting_for_input",
                "provider": "claude",
                "expectsResponse": false,
                \(stamp)
                "clientInfo": {"kind": "claudeCode"}
              }
            }
            """
            return try JSONDecoder().decode(RemoteHookEventMessage.self, from: Data(json.utf8)).payload
        }

        let hello = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let offset: TimeInterval = 300
        let endpoint = RemoteEndpoint(
            displayName: "Remote",
            sshTarget: "dev@example.invalid",
            lastConnectedAt: hello,
            remoteClockOffset: offset,
            supportsEventTimestamps: true
        )

        // 远端时钟视角 5 分钟前发生：归一化后仍是握手前的积压
        let backlog = RemoteConnectorManager.replayContext(
            payload: try payload(occurredAtJSON: "799999400"),
            endpoint: endpoint
        )
        XCTAssertEqual(try XCTUnwrap(backlog.occurredAt).timeIntervalSince(hello), -300, accuracy: 0.001)
        XCTAssertTrue(backlog.isReplay)

        // 远端时钟视角的「此刻」：归一化后不早于握手 → 实时
        let live = RemoteConnectorManager.replayContext(
            payload: try payload(occurredAtJSON: "799999701"),
            endpoint: endpoint
        )
        XCTAssertEqual(try XCTUnwrap(live.occurredAt).timeIntervalSince(hello), 1, accuracy: 0.001)
        XCTAssertFalse(live.isReplay)

        // F2：新 bridge（hello.now 存在）冲刷旧 bridge 的无戳积压
        XCTAssertTrue(RemoteConnectorManager.supportsEventTimestamps(helloNow: hello))
        let unstamped = RemoteConnectorManager.replayContext(
            payload: try payload(occurredAtJSON: nil),
            endpoint: endpoint
        )
        XCTAssertNil(unstamped.occurredAt)
        XCTAssertTrue(unstamped.isReplay)

        // 旧 bridge（hello.now 缺席）：无戳照旧视为实时
        XCTAssertFalse(RemoteConnectorManager.supportsEventTimestamps(helloNow: nil))
        let legacy = RemoteConnectorManager.replayContext(
            payload: try payload(occurredAtJSON: nil),
            endpoint: RemoteEndpoint(displayName: "Legacy", sshTarget: "legacy@example.invalid")
        )
        XCTAssertFalse(legacy.isReplay)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F3 完成卡节流
    // ══════════════════════════════════════════════════════════

    func testF3CardOlderThanTTLIsNotEnqueued() {
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true)
        registry.enqueue(card("ttl", completedAt: reference.addingTimeInterval(-90)), now: reference)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    /// 排队期间过期同样出列：被审批 / 隐藏窗口挡住的旧完成，解挡后
    /// 不得再逐张倾泻。
    func testF3CardThatExpiresWhileQueuedIsDroppedOnDequeue() {
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true)
        registry.enqueue(card("blocked", completedAt: reference), now: reference)
        XCTAssertEqual(registry.pendingNotifications.count, 1)

        XCTAssertNil(registry.dequeueNext(now: reference.addingTimeInterval(61)))
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    func testF3SecondCardWithinMinIntervalIsSuppressedAndCounted() throws {
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true)
        let first = card("first", completedAt: reference)
        registry.enqueue(first, now: reference)
        XCTAssertEqual(registry.dequeueNext(now: reference)?.identity, first.identity)

        registry.enqueue(
            card("second", completedAt: reference.addingTimeInterval(10)),
            now: reference.addingTimeInterval(10)
        )
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
        XCTAssertEqual(registry.suppressedSessionCount, 1)

        // 间隔过后：下一张卡片带上累计数，计数随即清零
        let later = reference.addingTimeInterval(60)
        registry.enqueue(card("third", completedAt: later), now: later)
        let next = try XCTUnwrap(registry.dequeueNext(now: later))
        XCTAssertEqual(next.session.sessionId, "third")
        XCTAssertEqual(next.suppressedSessionCount, 1)
        XCTAssertEqual(registry.suppressedSessionCount, 0)
    }

    func testF3BatchOfThreeCardsPresentsOneAnnouncingTheRest() throws {
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true)
        for id in ["merge-a", "merge-b", "merge-c"] {
            registry.enqueue(card(id, completedAt: reference), now: reference)
        }
        XCTAssertEqual(registry.pendingNotifications.count, 3)

        let presented = try XCTUnwrap(registry.dequeueNext(now: reference))
        XCTAssertEqual(presented.session.sessionId, "merge-a")
        XCTAssertEqual(presented.suppressedSessionCount, 2)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
        XCTAssertNil(registry.dequeueNext(now: reference))

        // 被合并的完成键已消费：后续快照不会把它们重新入队
        registry.enqueue(card("merge-b", completedAt: reference), now: reference)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    /// 未达阈值的批次保持既有行为：两张依次弹出。
    func testF3TwoPendingCardsStillPresentSeparately() throws {
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true)
        let first = card("pair-a", completedAt: reference)
        let second = card("pair-b", completedAt: reference)
        registry.enqueue(first, now: reference)
        registry.enqueue(second, now: reference)

        XCTAssertEqual(registry.dequeueNext(now: reference)?.identity, first.identity)
        XCTAssertEqual(registry.dequeueNext(now: reference)?.identity, second.identity)
        XCTAssertNil(registry.dequeueNext(now: reference))
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F4 声音冷却
    // ══════════════════════════════════════════════════════════

    func testF4TwoCompletionEdgesWithinCooldownRingOnce() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        XCTAssertEqual(
            tracker.edge(for: [completedSession(id: "ring-a")], now: reference)?.event,
            .taskCompleted
        )
        // 冷却窗口内：只登记状态，不响
        XCTAssertNil(tracker.edge(
            for: [completedSession(id: "ring-b")],
            now: reference.addingTimeInterval(1)
        ))
        // 窗口结束：恢复
        XCTAssertEqual(
            tracker.edge(for: [completedSession(id: "ring-c")], now: reference.addingTimeInterval(2))?.event,
            .taskCompleted
        )
    }

    /// 冷却只作用于完成类；attention 需要用户处理，永远可插队。
    func testF4AttentionEdgeBypassesCompletionCooldown() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true)
        tracker.prime(with: [])
        XCTAssertEqual(
            tracker.edge(for: [completedSession(id: "cool-a")], now: reference)?.event,
            .taskCompleted
        )
        XCTAssertNil(tracker.edge(
            for: [completedSession(id: "cool-b")],
            now: reference.addingTimeInterval(0.5)
        ))
        XCTAssertEqual(
            tracker.edge(
                for: [approvalSession(id: "cool-attention")],
                now: reference.addingTimeInterval(0.6)
            )?.event,
            .attentionRequired
        )
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F5 启动期「首次发现」收敛
    // ══════════════════════════════════════════════════════════

    func testF5FirstDiscoveredLocalSessionWithinStartupGraceDoesNotRing() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true, startedAt: reference)
        tracker.prime(with: [])
        let discovered = completedSession(id: "discovered", ingress: .hookBridge)

        XCTAssertNil(tracker.edge(for: [discovered], now: reference.addingTimeInterval(1)))
        // 状态已登记：之后不会补响
        XCTAssertNil(tracker.edge(for: [discovered], now: reference.addingTimeInterval(60)))
    }

    /// 不是启动静默窗口：会话先以运行态被发现、随后真的完成 → 照常响。
    func testF5RealCompletionAfterStartupStillRings() {
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true, startedAt: reference)
        tracker.prime(with: [])
        XCTAssertNotEqual(
            tracker.edge(
                for: [processingSession(id: "live")],
                now: reference.addingTimeInterval(1)
            )?.event,
            .taskCompleted
        )
        XCTAssertEqual(
            tracker.edge(
                for: [completedSession(id: "live", ingress: .hookBridge)],
                now: reference.addingTimeInterval(2)
            )?.event,
            .taskCompleted
        )
    }

    func testF5GraceOnlyCoversFirstDiscoveryOfLocalSessions() {
        // 远程会话不受 F5 约束（走 F8 / F2 判定）
        var remote = SessionSoundEdgeTracker(pacingEnabled: true, startedAt: reference)
        remote.prime(with: [])
        XCTAssertEqual(
            remote.edge(
                for: [completedSession(id: "remote-discovered")],
                now: reference.addingTimeInterval(1)
            )?.event,
            .taskCompleted
        )

        // 窗口之外的首次发现保持既有行为
        var later = SessionSoundEdgeTracker(pacingEnabled: true, startedAt: reference)
        later.prime(with: [])
        XCTAssertEqual(
            later.edge(
                for: [completedSession(id: "discovered-later", ingress: .hookBridge)],
                now: reference.addingTimeInterval(5)
            )?.event,
            .taskCompleted
        )
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - F6 决策日志
    // ══════════════════════════════════════════════════════════

    func testF6CardDecisionsAreTraced() {
        var lines: [String] = []
        let registry = SessionCompletionNotificationRegistry(pacingEnabled: true, trace: { lines.append($0) })

        registry.enqueue(card("ttl", completedAt: reference.addingTimeInterval(-90)), now: reference)
        registry.enqueue(card("fresh", completedAt: reference), now: reference)
        _ = registry.dequeueNext(now: reference)
        registry.enqueue(
            card("next", completedAt: reference.addingTimeInterval(5)),
            now: reference.addingTimeInterval(5)
        )

        XCTAssertTrue(lines.contains {
            $0.contains("surface=card session=fresh kind=completed decision=notify reason=fresh")
        })
        XCTAssertTrue(lines.contains {
            $0.contains("session=ttl kind=completed decision=suppress reason=ttl-expired lag=90s")
        })
        XCTAssertTrue(lines.contains {
            $0.contains("session=next kind=completed decision=suppress reason=min-interval")
        })
    }

    func testF6SoundDecisionsAreTraced() {
        var lines: [String] = []
        var tracker = SessionSoundEdgeTracker(pacingEnabled: true, trace: { lines.append($0) })
        tracker.prime(with: [])

        XCTAssertEqual(tracker.edge(for: [completedSession(id: "trace-a")], now: reference)?.event, .taskCompleted)
        XCTAssertNil(tracker.edge(
            for: [completedSession(id: "trace-b")],
            now: reference.addingTimeInterval(1)
        ))
        XCTAssertNil(tracker.edge(
            for: [completedSession(id: "trace-r", isReplay: true)],
            now: reference.addingTimeInterval(3)
        ))

        XCTAssertTrue(lines.contains {
            $0.contains("surface=sound session=trace-a kind=taskCompleted decision=notify")
        })
        XCTAssertTrue(lines.contains {
            $0.contains("surface=sound session=trace-b kind=completed decision=suppress reason=cooldown")
        })
        XCTAssertTrue(lines.contains {
            $0.contains("surface=sound session=trace-r kind=completed decision=suppress reason=replay")
        })
    }

    /// 策略层每次评估都给出抑制原因（落盘去重由 NotifyTrace 负责）。
    func testF6PolicyReportsSuppressionReason() {
        var reasons: [NotifySuppressReason] = []
        func report(_ reason: NotifySuppressReason) {
            reasons.append(reason)
        }

        let stale = completedSession(
            id: "policy-stale", lastEventOccurredAt: reference.addingTimeInterval(-600)
        )
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: stale, previousPhase: .processing, isEnabled: true,
            now: reference, onFreshnessSuppress: report
        ))

        let replay = completedSession(id: "policy-replay", isReplay: true)
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: replay, previousPhase: .processing, isEnabled: true,
            now: reference, onFreshnessSuppress: report
        ))

        let live = completedSession(
            id: "policy-live", lastEventOccurredAt: reference.addingTimeInterval(-2)
        )
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: live, previousPhase: .processing, isEnabled: true,
            now: reference, onFreshnessSuppress: report
        ))

        XCTAssertEqual(reasons, [.staleEvent, .replay])
    }

    func testF6DecisionLineIsFlatAndStable() {
        let line = NotificationPacing.decisionLine(
            surface: .card,
            sessionID: "0123456789abcdef",
            kind: "ended",
            decision: .suppress(.minInterval),
            occurredAt: reference.addingTimeInterval(-12.4),
            now: reference,
            suppressedCount: 3
        )
        XCTAssertEqual(
            line,
            "notify surface=card session=01234567 kind=ended decision=suppress reason=min-interval lag=12s suppressed=3"
        )
    }
}
