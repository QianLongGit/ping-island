import XCTest
@testable import Ping_Island

/// ══════════════════════════════════════════════════════════════════
/// docked 面提示闸门（Task 28 FIX2，第 35 审 P0-1 / P1-1）
///
/// 远端 outbox 回放过期事件（滞后 > 120 秒）时，docked 面只允许
/// 更新状态，不得触发两条提示类副作用：
///   - pending 边沿自动开槽（handlePendingSessionsChange）
///   - completed-ready 弹跳动画 + 30 秒完成勾选角标
///     （handleCompletedReadyChange / hasCompletedReadyState）
/// 判定逻辑抽成 NotchView 的静态纯函数（freshNewIds / absorbedIds），
/// 本用例直接驱动，不依赖 SwiftUI 运行时。两条不变量：
///   1. 过期边沿不进 freshNewIds（不触发提示）；
///   2. previous 吸收治外——absorbedIds 含过期 id，同一事件后续
///      重放不再进入判定（状态更新与去重语义不被闸门压住）。
/// ══════════════════════════════════════════════════════════════════
final class NotchViewFreshnessGateTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    // ── 构造：等待审批的远程会话（pending 面用） ──────────────────
    /// `lastActivity` 固定为 now，模拟回放接收时间照常刷新活性的
    /// 真实形态（接收时间拦不住过期判定，唯一口径是 occurredAt）。
    private func pendingRemoteSession(
        id: String,
        lastEventOccurredAt: Date?,
        now: Date
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/notch-gate-\(id)",
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

    // ── 构造：已完成就绪的远程会话（completed 面用） ──────────────
    private func completedRemoteSession(
        id: String,
        lastEventOccurredAt: Date?,
        now: Date
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/notch-gate-\(id)",
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

    // ══════════════ P0-1：pending 自动开槽闸门 ══════════════

    /// 过期回放的审批边沿不得触发 docked notch 自动开槽。
    func testStalePendingReplayDoesNotOpenNotch() {
        let stale = pendingRemoteSession(
            id: "stale-pending",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        // 前提归因：该会话确实是 pending 集合成员（与
        // SessionMonitor.pendingInstances 的过滤口径一致）。
        XCTAssertTrue(stale.needsManualAttention)

        let decision = NotchView.evaluatePendingPresentationGate(
            [stale],
            previous: [],
            now: reference
        )
        // 过期 → 不开槽
        XCTAssertTrue(decision.freshNewIds.isEmpty)
        // 吸收治外：过期 id 照常进 absorbed（写回 previous）
        XCTAssertEqual(decision.absorbedIds, [stale.stableId])
    }

    /// 吸收语义：过期边沿被 previous 吸收后，同一事件重放
    ///（App 重启 / 再次回放）不得再次进入判定。
    func testStalePendingReplayIsAbsorbedAndNeverRetriggers() {
        let stale = pendingRemoteSession(
            id: "stale-pending-replay",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        let first = NotchView.evaluatePendingPresentationGate(
            [stale],
            previous: [],
            now: reference
        )
        XCTAssertTrue(first.freshNewIds.isEmpty)

        let replay = NotchView.evaluatePendingPresentationGate(
            [stale],
            previous: first.absorbedIds,
            now: reference
        )
        XCTAssertTrue(replay.freshNewIds.isEmpty)
    }

    /// 实时远程审批：照常开槽（闸门不得误杀新鲜提示）。
    func testFreshPendingSessionStillOpensNotch() {
        let fresh = pendingRemoteSession(
            id: "fresh-pending",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        let decision = NotchView.evaluatePendingPresentationGate(
            [fresh],
            previous: [],
            now: reference
        )
        XCTAssertEqual(decision.freshNewIds, [fresh.stableId])
        XCTAssertEqual(decision.absorbedIds, [fresh.stableId])
    }

    /// 本地事件 / 旧 bridge（occurredAt == nil）：恒新鲜，照常开槽。
    func testLegacyPendingSessionWithoutStampStillOpensNotch() {
        let legacy = pendingRemoteSession(
            id: "legacy-pending",
            lastEventOccurredAt: nil,
            now: reference
        )
        let decision = NotchView.evaluatePendingPresentationGate(
            [legacy],
            previous: [],
            now: reference
        )
        XCTAssertEqual(decision.freshNewIds, [legacy.stableId])
    }

    /// 混合批次：同一波回放里新鲜与过期并存，只放行新鲜会话；
    /// 两者都照常吸收。
    func testMixedPendingBatchOnlyAdmitsFreshSession() {
        let fresh = pendingRemoteSession(
            id: "mixed-fresh",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        let stale = pendingRemoteSession(
            id: "mixed-stale",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        let decision = NotchView.evaluatePendingPresentationGate(
            [fresh, stale],
            previous: [],
            now: reference
        )
        XCTAssertEqual(decision.freshNewIds, [fresh.stableId])
        XCTAssertEqual(
            decision.absorbedIds,
            [fresh.stableId, stale.stableId]
        )
    }

    // ══════ P1-1：completed-ready 弹跳 / 勾选角标闸门 ══════

    /// 过期回放的完成边沿不得写 30 秒勾选角标、不得触发 bounce。
    ///（handler 只对 freshNewIds 写 completionReadyTimestamps 并
    /// 触发 isBouncing，角标数据源 hasCompletedReadyState 完全由
    /// completionReadyTimestamps 驱动——freshNewIds 为空即两者皆灭。）
    func testStaleCompletedReplayDoesNotBounceOrStampBadge() {
        let stale = completedRemoteSession(
            id: "stale-completed",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        // 前提归因：该会话确实是完成就绪态。
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(stale))

        let decision = NotchView.evaluateCompletedReadyPresentationGate(
            [stale],
            previous: [],
            now: reference
        )
        XCTAssertTrue(decision.freshNewIds.isEmpty)
        XCTAssertEqual(decision.absorbedIds, [stale.stableId])
    }

    /// 吸收语义：过期完成照常吸收，重放不再进入判定。
    func testStaleCompletedReplayIsAbsorbedAndNeverRetriggers() {
        let stale = completedRemoteSession(
            id: "stale-completed-replay",
            lastEventOccurredAt: reference.addingTimeInterval(-3 * 3_600),
            now: reference
        )
        let first = NotchView.evaluateCompletedReadyPresentationGate(
            [stale],
            previous: [],
            now: reference
        )
        XCTAssertTrue(first.freshNewIds.isEmpty)

        let replay = NotchView.evaluateCompletedReadyPresentationGate(
            [stale],
            previous: first.absorbedIds,
            now: reference
        )
        XCTAssertTrue(replay.freshNewIds.isEmpty)
    }

    /// 实时远程完成：照常弹跳 + 写角标。
    func testFreshCompletedSessionStillBouncesAndStampsBadge() {
        let fresh = completedRemoteSession(
            id: "fresh-completed",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        let decision = NotchView.evaluateCompletedReadyPresentationGate(
            [fresh],
            previous: [],
            now: reference
        )
        XCTAssertEqual(decision.freshNewIds, [fresh.stableId])
    }

    /// 本地 / 旧 bridge 完成事件（无戳）：恒新鲜，照常提示。
    func testLegacyCompletedSessionWithoutStampStillBounces() {
        let legacy = completedRemoteSession(
            id: "legacy-completed",
            lastEventOccurredAt: nil,
            now: reference
        )
        let decision = NotchView.evaluateCompletedReadyPresentationGate(
            [legacy],
            previous: [],
            now: reference
        )
        XCTAssertEqual(decision.freshNewIds, [legacy.stableId])
    }

    /// 保底：非完成态会话不进 completed 判定集合——闸门不得改变
    /// completed 集合本身的成员语义（processing 会话既不提示也不吸收）。
    func testNonCompletedSessionsStayOutsideCompletedGate() {
        var processing = completedRemoteSession(
            id: "processing-session",
            lastEventOccurredAt: reference.addingTimeInterval(-2),
            now: reference
        )
        processing.phase = .processing
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(processing))

        let decision = NotchView.evaluateCompletedReadyPresentationGate(
            [processing],
            previous: [],
            now: reference
        )
        XCTAssertTrue(decision.freshNewIds.isEmpty)
        XCTAssertTrue(decision.absorbedIds.isEmpty)
    }
}
