import Foundation

enum IslandExpandedSurface: Equatable {
    case docked
    case floating
}

enum IslandExpandedTrigger: Equatable {
    case click
    case hover
    case notification
    case pinnedList
}

enum IslandExpandedRoute: Equatable {
    case sessionList
    case hoverDashboard
    case attentionNotification(SessionState)
    case completionNotification(SessionCompletionNotification)
    case chat(SessionState)
}

enum IslandExpandedRouteResolver {
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType,
        sessions: [SessionState],
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> IslandExpandedRoute {
        switch trigger {
        case .notification:
            // ── 完成通知激活期的并发抢占修正（Task 21）────────────────
            // 完成弹窗已展示给用户时，任一会话转为 needsPromptNotification
            // 不得静默偷换通知卡——被换上的 attention 卡没有点击手势，
            // 用户点击将无任何反应。completion 优先保持展示；其消费后
            // （点击/超时/hover 离开）attention 分支照常接管。
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
        case .click, .hover, .pinnedList:
            break
        }

        if case .chat(let session) = contentType {
            return .chat(session)
        }

        switch (surface, trigger) {
        case (.docked, .notification):
            // ── 与先行 trigger 分支保持同一优先级语义（Task 21）──────
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .sessionList
        case (.docked, .hover), (.floating, .hover):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .hoverDashboard
        case (.floating, .notification):
            // ── 与 docked 分支保持同一优先级语义（Task 21）──────────
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .hoverDashboard
        case (_, .click):
            // Explicit list access stays available while a prompt is pending.
            // The list retains its approval/question controls and attention order.
            return .sessionList
        case (_, .pinnedList):
            return .sessionList
        }
    }

    nonisolated static func orderedSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    nonisolated static func activePreviewSessions(from sessions: [SessionState]) -> [SessionState] {
        orderedSessions(from: sessions).filter {
            $0.connectionState == .connected && (
                $0.phase.isActive || $0.needsPromptNotification
                    || $0.phase == .waitingForInput || $0.isRecentlyCompleted
            )
        }
    }

    nonisolated static func highestPriorityAttentionSession(from sessions: [SessionState]) -> SessionState? {
        orderedSessions(from: sessions)
            .filter(\.needsPromptNotification)
            .sorted(by: attentionSort)
            .first
    }

    nonisolated private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
