import os
import SwiftUI

private struct SessionCompletionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

nonisolated struct SessionCompletionNotification: Equatable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case completed
        case ended
        case compacted

        var statusLabelKey: String {
            switch self {
            case .completed:
                return "完成"
            case .ended:
                return "结束"
            case .compacted:
                return "已压缩"
            }
        }

        var fallbackAssistantMessageKey: String {
            switch self {
            case .completed:
                return "会话已完成，点击查看完整结果。"
            case .ended:
                return "会话已结束"
            case .compacted:
                return "上下文已压缩"
            }
        }

        var usesAssistantPreview: Bool {
            switch self {
            case .completed, .ended:
                return true
            case .compacted:
                return false
            }
        }
    }

    let id: UUID
    let session: SessionState
    let kind: Kind
    let queuedAt: Date
    /// 随本卡播报的其它会话完成数（Task 31 · F3）：被最小间隔抑制或
    /// 同批合并的完成不单独出卡，计数并入下一张真正弹出的卡片。
    let suppressedSessionCount: Int
    let identity: Identity

    enum Identity: Hashable {
        case completed(SessionCompletionKey)
        case compacted(sessionId: String, incarnationID: UUID, sequence: UInt64)
        case lifecycle(kind: Kind, sessionId: String, sequence: UInt64, turnId: String?)
    }

    init(
        id: UUID = UUID(),
        session: SessionState,
        kind: Kind,
        queuedAt: Date = Date(),
        suppressedSessionCount: Int = 0
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.queuedAt = queuedAt
        self.suppressedSessionCount = suppressedSessionCount
        if kind == .completed, let key = SessionCompletionKey.make(for: session) {
            self.identity = .completed(key)
        } else if kind == .compacted {
            self.identity = .compacted(
                sessionId: session.sessionId,
                incarnationID: session.lifecycleIncarnationID,
                sequence: session.compactionSequence
            )
        } else {
            self.identity = .lifecycle(
                kind: kind,
                sessionId: session.sessionId,
                sequence: session.completionSequence,
                turnId: session.latestTurnId
            )
        }
    }

    /// 返回携带累计播报数的同身份副本（id / identity 不变）
    nonisolated func announcingSuppressedSessions(_ count: Int) -> SessionCompletionNotification {
        SessionCompletionNotification(
            id: id,
            session: session,
            kind: kind,
            queuedAt: queuedAt,
            suppressedSessionCount: count
        )
    }
}

enum SessionCompletionPreviewBuilder {
    static func latestUserText(for session: SessionState) -> String? {
        let isRemoteCodex = session.provider == .codex && session.ingress == .remoteBridge
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                // An empty prompt still advances this boundary without adding
                // a chat item. Do not pair an older question with the new reply.
                if isRemoteCodex {
                    guard let submittedAt = session.conversationInfo.lastUserMessageDate,
                          item.timestamp >= submittedAt else { return nil }
                }
                return sanitized(text)
            }
        }
        return isRemoteCodex ? nil : sanitized(session.firstUserMessage)
    }

    static func latestAssistantText(for session: SessionState) -> String? {
        // A remote turn can complete without a prompt or reply body. Keep the
        // notification, but do not present an earlier turn's text as its result.
        if session.provider == .codex,
           session.ingress == .remoteBridge,
           session.lastMessageRole != "assistant" {
            return nil
        }

        var activityFallback: String?
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                if let text = sanitized(text) { return text }
            case .thinking(let text):
                activityFallback = activityFallback ?? sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                activityFallback = activityFallback ?? (preview.map { "\(label) \($0)" } ?? label)
            case .interrupted:
                activityFallback = activityFallback ?? "已中断"
            case .user:
                return activityFallback
            }
        }

        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage) ?? activityFallback
    }

    static func latestAssistantText(
        for session: SessionState,
        notificationKind: SessionCompletionNotification.Kind
    ) -> String? {
        guard notificationKind.usesAssistantPreview else { return nil }
        return latestAssistantText(for: session)
    }

    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

nonisolated enum SessionCompletionStateEvaluator {
    /// A Stop or completed idle turn is authoritative even if its final text is
    /// written to the transcript later, or never sent by a remote hook.
    static func isCompletedReadySession(_ session: SessionState) -> Bool {
        guard session.connectionState == .connected else { return false }
        guard case nil = session.intervention else { return false }
        guard !session.needsPromptNotification else { return false }
        if session.provider == .codex {
            // Remote discovery reports idle metadata before any Stop is observed.
            if session.ingress == .remoteBridge, !session.hasRemoteCodexTurnCompletion {
                return false
            }
            return session.phase == .idle && !session.isCodexTurnInterrupted
        }
        return session.phase == .waitingForInput || isCompletedOpenCodeIdleSession(session)
    }

    private static func isCompletedOpenCodeIdleSession(_ session: SessionState) -> Bool {
        session.phase == .idle && session.clientInfo.brand == .opencode
    }

    static func allowsEndedNotificationAfterWaitingForInput(_ session: SessionState) -> Bool {
        guard session.phase == .ended else { return false }
        guard case nil = session.intervention else { return false }
        // Qoder CLI and Kimi both use "Stop" for turn-end (goes to .waitingForInput)
        // and "SessionEnd" for actual session closure.
        return session.clientInfo.isQoderCLIClient
            || session.clientInfo.isKimiClient
    }

    /// Transcript evidence remains useful for previews, but is not a completion gate.
    static func hasCompletedAssistantReply(for session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return session.lastMessageRole == "assistant"
    }
}

@MainActor
final class SessionCompletionNotificationRegistry {
    static let shared = SessionCompletionNotificationRegistry()

    private var consumedIdentities = Set<SessionCompletionNotification.Identity>()
    private var pending: [SessionCompletionNotification] = []

    // ─────────────────────────────────────────────────
    // 节流状态（Task 31 · F3）
    //
    // 入队 / 出队准入只看卡片自己的完成时刻与「上一张已弹出卡片」
    // 的出队时刻；控制器照旧 enqueue → dequeueNext，无需知情。
    // ─────────────────────────────────────────────────
    /// 上一张实际弹出（出队）的完成卡时刻
    private var lastPresentedAt: Date?
    /// 被最小间隔 / 同批合并抑制、等待随下一张卡片播报的会话数
    private(set) var suppressedSessionCount = 0
    private let trace: (String) -> Void
    /// 节流开关：关闭即沿用 Task 31 之前的入队 / 出队语义。回放与
    /// 过期闸门在策略层，不受它影响。
    private let isPacingEnabled: Bool

    init(
        pacingEnabled: Bool = NotificationPacing.isPacingEnabledByDefault,
        trace: @escaping (String) -> Void = { NotifyTrace.emit($0) }
    ) {
        self.isPacingEnabled = pacingEnabled
        self.trace = trace
    }

    var pendingNotifications: [SessionCompletionNotification] { pending }

    func isConsumed(session: SessionState) -> Bool {
        guard let key = SessionCompletionKey.make(for: session) else { return false }
        return consumedIdentities.contains(.completed(key))
    }

    func markConsumed(session: SessionState) {
        guard let key = SessionCompletionKey.make(for: session) else { return }
        consumedIdentities.insert(.completed(key))
    }

    func isConsumed(_ notification: SessionCompletionNotification) -> Bool {
        consumedIdentities.contains(notification.identity)
    }

    func markConsumed(_ notification: SessionCompletionNotification) {
        consumedIdentities.insert(notification.identity)
    }

    /// 入队准入（F3.1 TTL + F3.2 最小间隔）。被最小间隔抑制的完成
    /// 不出卡，但计入 suppressedSessionCount，随下一张卡片播报。
    func enqueue(_ notification: SessionCompletionNotification, now: Date = Date()) {
        guard !isConsumed(notification),
              !pending.contains(where: { $0.identity == notification.identity }) else { return }

        let decision: NotifyDecision = isPacingEnabled
            ? NotificationPacing.completionCardAdmission(
                completionOccurredAt: notification.session.lastEventOccurredAt,
                queuedAt: notification.queuedAt,
                lastPresentedAt: lastPresentedAt,
                now: now
            )
            : .notify
        trace(decisionLine(notification, decision, now: now))
        guard decision == .notify else {
            if decision == .suppress(.minInterval) {
                suppressedSessionCount += 1
            }
            return
        }
        pending.append(notification)
    }

    /// 出队（F3.1 排队期间过期的卡片出列 + F3.3 同批合并）。
    func dequeueNext(now: Date = Date()) -> SessionCompletionNotification? {
        pending.removeAll(where: isConsumed)
        guard isPacingEnabled else {
            // 节流关闭：逐张出队，不过期、不合并
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            markConsumed(next)
            return next
        }

        // 排队期间过期：被审批 / 隐藏窗口挡住后积压的旧完成，
        // 解挡时不得再逐张倾泻。
        var retained: [SessionCompletionNotification] = []
        for notification in pending {
            if NotificationPacing.isCompletionCardExpired(
                completionOccurredAt: notification.session.lastEventOccurredAt,
                queuedAt: notification.queuedAt,
                now: now
            ) {
                trace(decisionLine(notification, .suppress(.ttlExpired), now: now))
            } else {
                retained.append(notification)
            }
        }
        pending = retained
        guard var head = pending.first else { return nil }

        let batch = pending
        pending.removeAll()
        if NotificationPacing.mergesCompletionCardBatch(pendingCount: batch.count) {
            // 同一批 ≥ 阈值：只出首张，其余合并进它的计数
            suppressedSessionCount += batch.count - 1
            for merged in batch.dropFirst() {
                markConsumed(merged)
                trace(decisionLine(merged, .suppress(.batchMerge), now: now))
            }
        } else {
            pending.append(contentsOf: batch.dropFirst())
        }
        head = head.announcingSuppressedSessions(suppressedSessionCount)
        suppressedSessionCount = 0
        markConsumed(head)
        lastPresentedAt = now
        trace(decisionLine(head, .notify, now: now))
        return head
    }

    func removePending(matching predicate: (SessionCompletionNotification.Kind) -> Bool) {
        let removed = pending.filter { predicate($0.kind) }
        pending.removeAll { predicate($0.kind) }
        for notification in removed {
            markConsumed(notification)
        }
    }

    // ─────────────────────────────────────────────────
    // 决策日志行（Task 31 · F6）
    // ─────────────────────────────────────────────────
    private func decisionLine(
        _ notification: SessionCompletionNotification,
        _ decision: NotifyDecision,
        now: Date
    ) -> String {
        NotificationPacing.decisionLine(
            surface: .card,
            sessionID: notification.session.sessionId,
            kind: notification.kind.rawValue,
            decision: decision,
            occurredAt: notification.session.lastEventOccurredAt,
            now: now,
            suppressedCount: suppressedSessionCount
        )
    }
}

enum SessionCompletionNotificationPolicy {
    private static let notificationRecencyWindow: TimeInterval = 60

    static func trackingStates(
        for sessions: [SessionState]
    ) -> [String: (phase: SessionPhase, completionKey: SessionCompletionKey?)] {
        Dictionary(uniqueKeysWithValues: sessions.map {
            (trackingID(for: $0), trackingState(for: $0))
        })
    }

    static func trackingState(
        for session: SessionState
    ) -> (phase: SessionPhase, completionKey: SessionCompletionKey?) {
        var snapshot = session
        if snapshot.provider == .codex, snapshot.ingress == .remoteBridge {
            // Losing transport must not erase the observed turn identity.
            // Notification eligibility still checks the actual connection state.
            snapshot.connectionState = .connected
        }
        return (phase: session.phase, completionKey: SessionCompletionKey.make(for: snapshot))
    }

    static func trackingID(for session: SessionState) -> String {
        // Remote discovery omits the PID that hooks may report or change.
        if session.provider == .codex, session.ingress == .remoteBridge {
            return session.sessionId
        }
        return session.stableId
    }

    static func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        previousCompletionKey: SessionCompletionKey? = nil,
        isEnabled: Bool,
        now: Date = Date(),
        onFreshnessSuppress: ((NotifySuppressReason) -> Void)? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }

        if session.provider == .codex {
            guard session.phase == .idle, let previousPhase else { return false }
            if session.ingress == .remoteBridge, previousPhase == .idle {
                // Discovery and Stop can both be idle; only a new Stop key queues a popup.
                guard SessionCompletionKey.make(for: session) != previousCompletionKey else {
                    return false
                }
            } else if !isCodexCompletionSourcePhase(previousPhase) {
                return false
            }
            return wasTrackedOrRecentlyCreated(
                session, kind: .completed, previousPhase: previousPhase, now: now, onSuppress: onFreshnessSuppress
            )
        }

        // A question can be resolved without changing waitingForInput; the
        // completion identity, not the phase alone, deduplicates that transition.
        return wasTrackedOrRecentlyCreated(
            session, kind: .completed, previousPhase: previousPhase, now: now, onSuppress: onFreshnessSuppress
        )
    }

    static func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date(),
        onFreshnessSuppress: ((NotifySuppressReason) -> Void)? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard wasTrackedOrRecentlyCreated(
            session, kind: .ended, previousPhase: previousPhase, now: now, onSuppress: onFreshnessSuppress
        ) else {
            return false
        }
        if previousPhase == .waitingForInput {
            return SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(session)
        }
        return true
    }

    static func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date(),
        onFreshnessSuppress: ((NotifySuppressReason) -> Void)? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        guard previousPhase == .compacting else { return false }
        guard session.phase != .compacting else { return false }
        return wasTrackedOrRecentlyCreated(
            session, kind: .compacted, previousPhase: previousPhase, now: now, onSuppress: onFreshnessSuppress
        )
    }

    static func hasRecentNotificationActivity(
        _ session: SessionState,
        kind: SessionCompletionNotification.Kind = .completed,
        now: Date = Date(),
        onSuppress: ((NotifySuppressReason) -> Void)? = nil
    ) -> Bool {
        // ═══════════════════════════════════════════════════
        // 提示类副作用的闸门，两层叠加、只压提示不改状态：
        //   1. 回放（Task 31 · F8）：事件在本次握手之前就已发生——
        //      哪怕滞后不足 120 秒（批次尾部的「新鲜尾巴」）也不入队
        //   2. 过期（Task 28）：会话级最新事件滞后超过阈值
        // 两者都缺席（本地事件 / 实时远程事件）→ 落到下面的 recency 窗口
        // ═══════════════════════════════════════════════════
        if session.lastEventIsReplay {
            reportSuppression(.replay, session: session, kind: kind, now: now, onSuppress: onSuppress)
            return false
        }
        guard session.hasFreshNotificationActivity(now: now) else {
            reportSuppression(.staleEvent, session: session, kind: kind, now: now, onSuppress: onSuppress)
            return false
        }
        return now.timeIntervalSince(session.lastActivity) <= notificationRecencyWindow
    }

    /// 决策日志（Task 31 · F6）。控制器每个快照都会重新评估同一会话，
    /// 同一次完成的同一原因只落一行，避免一次洪峰写成上万行。
    private static func reportSuppression(
        _ reason: NotifySuppressReason,
        session: SessionState,
        kind: SessionCompletionNotification.Kind,
        now: Date,
        onSuppress: ((NotifySuppressReason) -> Void)?
    ) {
        onSuppress?(reason)
        NotifyTrace.emitOnce(
            key: [
                session.stableId, kind.rawValue, reason.rawValue,
                String(session.completionSequence), session.latestTurnId ?? "-",
                String(session.compactionSequence)
            ].joined(separator: "|"),
            NotificationPacing.decisionLine(
                surface: .card,
                sessionID: session.sessionId,
                kind: kind.rawValue,
                decision: .suppress(reason),
                occurredAt: session.lastEventOccurredAt,
                now: now,
                suppressedCount: 0
            )
        )
    }

    private static func isCodexCompletionSourcePhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .processing, .waitingForInput, .waitingForApproval:
            return true
        case .idle, .ended, .compacting:
            return false
        }
    }

    private static func wasTrackedOrRecentlyCreated(
        _ session: SessionState,
        kind: SessionCompletionNotification.Kind,
        previousPhase: SessionPhase?,
        now: Date,
        onSuppress: ((NotifySuppressReason) -> Void)?
    ) -> Bool {
        guard hasRecentNotificationActivity(
            session, kind: kind, now: now, onSuppress: onSuppress
        ) else {
            return false
        }

        if previousPhase != nil {
            return true
        }

        return now.timeIntervalSince(session.createdAt) <= notificationRecencyWindow
    }
}

struct SessionCompletionNotificationView: View {
    static let minimumContentHeight: CGFloat = 172
    static let maximumAssistantContentHeight: CGFloat = 300
    static let bubbleAssistantLineLimit = 9

    // ── T21 插桩：完成弹窗点击链取证通道 ─────────────────────────
    // 独立 category 便于真机 `log show` 过滤；隐私全 public（仅含
    // 会话短标识与布尔状态，无对话内容）。
    private static let tapTrace = Logger(
        subsystem: "com.wudanwu.pingisland",
        category: "CompletionTap"
    )

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 布局度量（紧凑会话列表联动）
    //
    // 紧凑档开启时字号/内距取自 SessionListCompactMetrics 密度表
    // （与主列表同源，视觉一致）；关闭时严格保持旧值（13 / 12+ /
    // 16 / 14），行为零漂移。纯函数便于单测锁死表驱动一致性。
    // ═══════════════════════════════════════════════════════════════
    static func metricsBodyFontSize(base: CGFloat, compactList: Bool) -> CGFloat {
        compactList
            ? SessionListCompactMetrics.detailFontSize(base: base)
            : max(12, base)
    }

    static func metricsLabelFontSize(base: CGFloat, compactList: Bool) -> CGFloat {
        compactList
            ? SessionListCompactMetrics.sessionTitleFontSize(base: base)
            : max(13, base)
    }

    static func metricsSectionVerticalPadding(compactList: Bool) -> CGFloat {
        compactList ? 9 : 14
    }

    static func metricsSectionHorizontalPadding(compactList: Bool) -> CGFloat {
        compactList ? 12 : 16
    }

    let notification: SessionCompletionNotification
    let presentationStyle: SessionCompletionNotificationPresentationStyle
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void
    let onOpenSession: (() -> Void)?

    @ObservedObject private var settings = AppSettings.shared
    @State private var measuredAssistantContentHeight: CGFloat = 0

    init(
        notification: SessionCompletionNotification,
        presentationStyle: SessionCompletionNotificationPresentationStyle = .panel,
        onHoverChanged: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onOpenSession: (() -> Void)? = nil
    ) {
        self.notification = notification
        self.presentationStyle = presentationStyle
        self.onHoverChanged = onHoverChanged
        self.onDismiss = onDismiss
        self.onOpenSession = onOpenSession
    }

    private var session: SessionState { notification.session }

    private var assistantLabel: String {
        session.providerDisplayName
    }

    private var providerTint: Color {
        session.clientTintColor
    }

    private var assistantPrefixColor: Color {
        providerTint.opacity(session.phase.isActive ? 0.96 : 0.9)
    }

    private var assistantTextColor: Color {
        .white.opacity(0.82)
    }

    private var bodyFontSize: CGFloat {
        Self.metricsBodyFontSize(
            base: CGFloat(settings.contentFontSize),
            compactList: settings.compactSessionList
        )
    }

    private var userText: String? {
        let text = SessionCompletionPreviewBuilder.latestUserText(for: session)
        if session.provider == .codex, session.ingress == .remoteBridge {
            return text
        }
        return text ?? session.titleOnlySubagentDisplayTitle
    }

    private var assistantText: String? {
        SessionCompletionPreviewBuilder.latestAssistantText(
            for: session,
            notificationKind: notification.kind
        )
    }

    private var assistantContentHeight: CGFloat? {
        guard measuredAssistantContentHeight > 0 else { return nil }
        return min(measuredAssistantContentHeight, Self.maximumAssistantContentHeight)
    }

    private var assistantLabelText: String {
        assistantLabel + "："
    }

    @ViewBuilder
    private var assistantContent: some View {
        if let assistantText {
            MarkdownText(
                assistantText,
                color: assistantTextColor,
                fontSize: bodyFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(assistantLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        } else {
            Text(appLocalized: notification.kind.fallbackAssistantMessageKey)
                .font(.system(size: bodyFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(assistantLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        }
    }

    private var assistantLineLimit: Int? {
        switch presentationStyle {
        case .panel:
            return nil
        case .bubble:
            return Self.bubbleAssistantLineLimit
        }
    }

    @ViewBuilder
    private var assistantMessageView: some View {
        switch presentationStyle {
        case .panel:
            ScrollView(.vertical, showsIndicators: true) {
                assistantContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SessionCompletionContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: assistantContentHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .bubble:
            assistantContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var assistantSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(assistantLabelText)
                .font(.system(size: Self.metricsLabelFontSize(base: CGFloat(settings.contentFontSize), compactList: settings.compactSessionList), weight: .semibold))
                .foregroundColor(assistantPrefixColor)

            assistantMessageView
        }
        .padding(.horizontal, Self.metricsSectionHorizontalPadding(compactList: settings.compactSessionList))
        .padding(.vertical, Self.metricsSectionVerticalPadding(compactList: settings.compactSessionList))
    }

    private var containerCornerRadius: CGFloat { 16 }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 会话标识行（T16 · projectName · displayTitle · 主机徽章）
    //
    // 弹窗须自证归属：复用会话列表行的两段名层级与主机徽章语义
    // （本地/远程一目了然）；子代理/网关会话退化为单段标题。
    // ═══════════════════════════════════════════════════════════════
    private var identityBadgeText: String {
        SessionCompletionNotificationIdentity.hostBadgeText(
            for: session,
            endpoints: RemoteConnectorManager.shared.endpoints
        )
    }

    private var identityTitleLine: Text {
        let titleFontSize = Self.metricsLabelFontSize(base: CGFloat(settings.contentFontSize), compactList: settings.compactSessionList)
        let separator = Text(" · ")
            .font(.system(size: titleFontSize, weight: .bold))
            .foregroundColor(.white.opacity(0.34))

        var line: Text
        if SessionCompletionNotificationIdentity.usesSingleTitlePresentation(for: session) {
            // 单段名退化：子代理取专属单段标题，网关取会话标题
            let title = session.usesTitleOnlySubagentPresentation
                ? session.titleOnlySubagentDisplayTitle
                : session.displayTitle
            line = Text(title)
                .font(.system(size: titleFontSize, weight: .bold))
                .foregroundColor(.white)
        } else {
            line = Text(session.projectName)
                .font(.system(size: titleFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))
            + separator
            + Text(session.displayTitle)
                .font(.system(size: titleFontSize, weight: .bold))
                .foregroundColor(.white)
        }

        // 主机徽章收尾：低亮度 0.5，与会话行 T9 徽章同语义
        return line
            + separator
            + Text(identityBadgeText)
                .font(.system(size: titleFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
    }

    private var identityHeaderView: some View {
        identityTitleLine
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Self.metricsSectionHorizontalPadding(compactList: settings.compactSessionList))
            .padding(.top, Self.metricsSectionVerticalPadding(compactList: settings.compactSessionList))
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var contentCard: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            identityHeaderView

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let userText {
                    Text(appLocalized: "你：")
                        .font(.system(size: Self.metricsLabelFontSize(base: CGFloat(settings.contentFontSize), compactList: settings.compactSessionList), weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))

                    Text(userText)
                        .font(.system(size: bodyFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                Text(AppLocalization.string(notification.kind.statusLabelKey))
                    .font(.system(size: Self.metricsLabelFontSize(base: CGFloat(settings.contentFontSize), compactList: settings.compactSessionList), weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize()
            }
            .padding(.horizontal, Self.metricsSectionHorizontalPadding(compactList: settings.compactSessionList))
            .padding(.vertical, Self.metricsSectionVerticalPadding(compactList: settings.compactSessionList))

            // ── Task 31 · F3：被抑制 / 合并的其它会话完成，随本卡播报 ──
            if notification.suppressedSessionCount > 0 {
                Text(AppLocalization.format("另有 %ld 个会话完成", notification.suppressedSessionCount))
                    .font(.system(size: bodyFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.metricsSectionHorizontalPadding(compactList: settings.compactSessionList))
                    .padding(.bottom, Self.metricsSectionVerticalPadding(compactList: settings.compactSessionList))
            }

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            assistantSection
        }

        switch presentationStyle {
        case .panel:
            content
                .background(
                    RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
        case .bubble:
            content
        }
    }

    private var outerHorizontalPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 14
        case .bubble:
            return 0
        }
    }

    private var outerTopPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 8
        case .bubble:
            return 0
        }
    }

    private var outerBottomPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 12
        case .bubble:
            return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contentCard
        }
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.top, outerTopPadding)
        .padding(.bottom, outerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(
            presentationStyle == .bubble
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .onPreferenceChange(SessionCompletionContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            measuredAssistantContentHeight = height
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onDisappear {
            onHoverChanged(false)
        }
        .onTapGesture {
            // ── T21 插桩（CompletionTap 通道）：手势层命中点 ──────────
            // 若真机点击后此行缺失 → 手势未到达视图（命中测试问题）；
            // 有此行而后续 content.forward 缺失 → 闭包链断裂。
            Self.tapTrace.notice(
                "view.tap session=\(notification.session.sessionId.prefix(8), privacy: .public) hasOpenCallback=\(onOpenSession != nil, privacy: .public)"
            )
            // 单击即「进去看」：有跳转回调则打开会话面板，否则保持旧 dismiss
            if let onOpenSession {
                onOpenSession()
            } else {
                onDismiss()
            }
        }
    }
}

enum SessionCompletionNotificationPresentationStyle: Equatable {
    case panel
    case bubble
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 标识行纯函数（T16）
//
// 会话归属文案判定与视图解耦：主机徽章本地/远程/endpoint 展示名
// 三态、单段名退化判定，均为无副作用纯函数（可单测锁死）。
// ═════════════════════════════════════════════════════════════════
enum SessionCompletionNotificationIdentity {
    /// 主机徽章：本地恒「本地」；远程优先 endpoint 展示名/host 回退
    /// （复用 T12-A HoverSessionHostBadge 判定），无 host 提示兜底「远程」。
    static func hostBadgeText(
        for session: SessionState,
        endpoints: [RemoteEndpoint]
    ) -> String {
        guard session.isRemoteSession else { return "本地" }
        return HoverSessionHostBadge.badgeTitle(for: session, endpoints: endpoints) ?? "远程"
    }

    /// 单段名退化：子代理/网关会话沿用列表行同款单段标题展示。
    static func usesSingleTitlePresentation(for session: SessionState) -> Bool {
        session.usesTitleOnlySubagentPresentation || session.shouldHideProjectContextInUI
    }
}
