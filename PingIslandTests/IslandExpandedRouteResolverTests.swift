import XCTest
@testable import Ping_Island

final class IslandExpandedRouteResolverTests: XCTestCase {
    func testHoverPreviewRetainsConnectedCompletionStates() {
        let completed = [SessionPhase.waitingForInput, .idle, .ended].enumerated().map {
            makeSession(id: "completed-\($0.offset)", phase: $0.element)
        }
        XCTAssertEqual(
            Set(IslandExpandedRouteResolver.activePreviewSessions(from: completed).map(\.sessionId)),
            Set(completed.map(\.sessionId))
        )
        let disconnected = completed.map { session in
            var copy = session
            copy.connectionState = .disconnected
            return copy
        }
        XCTAssertTrue(IslandExpandedRouteResolver.activePreviewSessions(from: disconnected).isEmpty)
        var stale = makeSession(id: "stale", phase: .idle)
        stale.lastActivity = Date().addingTimeInterval(-24 * 60 * 60)
        XCTAssertTrue(IslandExpandedRouteResolver.activePreviewSessions(from: [stale]).isEmpty)
    }

    func testHoverPreviewIncludesActiveSessionWithoutAnyNotification() {
        // 纯活跃会话（正在执行、无 attention、无完成通知）必须进入预览
        // 候选集——通知只是排序信号（shouldSortBeforeInQueue），不是
        // 入选门槛（T12-C 回归锁：悬停预览展示所有活动会话）。
        let running = makeSession(id: "running", phase: .processing)
        let idleRecent = makeSession(id: "idle-recent", phase: .waitingForInput)

        let previewIDs = IslandExpandedRouteResolver.activePreviewSessions(from: [running, idleRecent])
            .map(\.sessionId)

        XCTAssertEqual(Set(previewIDs), Set(["running", "idle-recent"]))
    }

    func testClickResolvesToSessionList() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .sessionList)
    }

    func testClickWithManualAttentionKeepsSessionListAccessible() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .sessionList)
    }

    func testClickWithTerminalOnlyPromptKeepsSessionListAccessibleOnBothSurfaces() {
        var prompt = makeSession(id: "terminal-question", phase: .waitingForInput)
        prompt.suppressInAppPromptControls = true
        for surface in [IslandExpandedSurface.docked, .floating] {
            XCTAssertEqual(
                IslandExpandedRouteResolver.resolve(
                    surface: surface,
                    trigger: .click,
                    contentType: .instances,
                    sessions: [prompt]
                ),
                .sessionList
            )
            XCTAssertEqual(
                IslandExpandedRouteResolver.resolve(
                    surface: surface,
                    trigger: .notification,
                    contentType: .instances,
                    sessions: [prompt]
                ),
                .attentionNotification(prompt)
            )
        }
    }

    func testHoverWithoutManualAttentionResolvesToHoverDashboard() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .hoverDashboard)
    }

    func testHoverWithManualAttentionResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testDockedNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    func testDockedNotificationWithApprovalResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testNotificationAttentionOverridesPreviouslyOpenChat() {
        let staleChat = makeSession(id: "stale-chat", phase: .processing)
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .chat(staleChat),
            sessions: [staleChat, attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testFloatingNotificationWithApprovalResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testFloatingNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 完成通知激活期的并发抢占（Task 21）
    //
    // 完成弹窗弹出后，任一会话出现 needsPromptNotification（真机
    // 日志 2026-11-22 12:46:52 实证：Stop 事件同时 completedReady=
    // true 与 waitingForInput）→ 旧顺序让 attention 静默偷换通知
    // 卡，而 attention 卡无 onTapGesture → 用户点击「无反应」。
    // 修正：completion 已激活时优先保持展示，attention 待消费后接管。
    // ═════════════════════════════════════════════════════════════════

    func testNotificationKeepsActiveCompletionOverConcurrentPromptAttention() {
        var prompt = makeSession(id: "terminal-question", phase: .waitingForInput)
        prompt.suppressInAppPromptControls = true
        let notification = SessionCompletionNotification(session: prompt, kind: .completed)

        for surface in [IslandExpandedSurface.docked, .floating] {
            XCTAssertEqual(
                IslandExpandedRouteResolver.resolve(
                    surface: surface,
                    trigger: .notification,
                    contentType: .instances,
                    sessions: [prompt],
                    activeCompletionNotification: notification
                ),
                .completionNotification(notification)
            )
        }
    }

    func testNotificationKeepsActiveCompletionOverConcurrentQuestionAttention() {
        let question = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        for surface in [IslandExpandedSurface.docked, .floating] {
            XCTAssertEqual(
                IslandExpandedRouteResolver.resolve(
                    surface: surface,
                    trigger: .notification,
                    contentType: .instances,
                    sessions: [completed, question],
                    activeCompletionNotification: notification
                ),
                .completionNotification(notification)
            )
        }
    }

    func testClickTriggerKeepsChatEvenWithConcurrentAttention() {
        // ── tap 后态（trigger=.click + contentType=.chat）稳定锁 ────
        // 并发 attention 存在时仍解析为 .chat——锁住点击跳转的
        // 下游语义，防止未来回退为 notification 触发后被抢占。
        let session = makeSession(id: "completion-tap", phase: .waitingForInput)
        var prompt = makeSession(id: "attention", phase: .waitingForInput)
        prompt.suppressInAppPromptControls = true

        XCTAssertEqual(
            IslandExpandedRouteResolver.resolve(
                surface: .docked,
                trigger: .click,
                contentType: .chat(session),
                sessions: [session, prompt],
                activeCompletionNotification: nil
            ),
            .chat(session)
        )
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            intervention: intervention,
            phase: phase
        )
    }

    private func makeIntervention(
        id: String,
        kind: SessionInterventionKind,
        message: String
    ) -> SessionIntervention {
        SessionIntervention(
            id: id,
            kind: kind,
            title: message,
            message: message,
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
    }
}
