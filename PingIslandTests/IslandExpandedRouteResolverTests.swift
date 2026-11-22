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
