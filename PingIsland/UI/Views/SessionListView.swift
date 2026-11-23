//
//  SessionListView.swift
//  PingIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

struct SessionListView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    var enableKeyboardNavigation = true
    var highlightedSessionStableID: String? = nil
    // 紧凑会话列表开关（默认开）：emptyState 按钮区密度跟随
    @ObservedObject private var settings = AppSettings.shared
    // T25：kero 会话清单（补全 hook 侧看不到的本地 / 各主机会话）
    @ObservedObject private var keroInventory = KeroInventoryService.shared
    @State private var expandedSessionStableID: String?
    @State private var selectedSessionStableID: String?
    @State private var keyEventMonitor: Any?
    @State private var isYabaiAvailable = false

    var body: some View {
        Group {
            // T25：hook 侧没会话但 kero 侧有会话时，仍要展示完整列表
            if sessionMonitor.instances.isEmpty && keroRows.isEmpty {
                emptyState
            } else {
                instancesList
            }
        }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
        // ── T25：面板打开时拉一次 kero 清单（TTL 内复用缓存） ─────
        .task {
            keroInventory.refreshIfNeeded()
        }
        // ── 行数上报：驱动面板解析式高度（内容自适应封顶） ────────
        .onAppear {
            viewModel.updateInstanceRowCount(displayedRowCount)
        }
        .onChange(of: displayedRowCount) { _, newCount in
            viewModel.updateInstanceRowCount(newCount)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: SessionListCompactMetrics.sessionTitleFontSize(base: CGFloat(settings.contentFontSize)), weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run Claude Code, Codex CLI, or ChatGPT")
                .font(.system(size: SessionListCompactMetrics.detailFontSize(base: CGFloat(settings.contentFontSize))))
                .foregroundColor(.white.opacity(0.25))

            if FeatureFlags.nativeClaudeRuntime || FeatureFlags.nativeCodexRuntime {
                HStack(spacing: 8) {
                    if FeatureFlags.nativeClaudeRuntime {
                        Button(action: { launchNativeRuntime(.claude) }) {
                            Text("Launch Claude Native")
                                .font(.system(size: SessionListCompactMetrics.detailFontSize(base: CGFloat(settings.contentFontSize)), weight: .semibold))
                                .foregroundColor(.white.opacity(0.86))
                                .padding(.horizontal, 10)
                                .padding(.vertical, settings.compactSessionList ? 5 : 7)
                                .background(nativeRuntimeTint(for: .claude).opacity(0.26))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if FeatureFlags.nativeCodexRuntime {
                        Button(action: { launchNativeRuntime(.codex) }) {
                            Text("Launch Codex Native")
                                .font(.system(size: SessionListCompactMetrics.detailFontSize(base: CGFloat(settings.contentFontSize)), weight: .semibold))
                                .foregroundColor(.white.opacity(0.86))
                                .padding(.horizontal, 10)
                                .padding(.vertical, settings.compactSessionList ? 5 : 7)
                                .background(nativeRuntimeTint(for: .codex).opacity(0.26))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, settings.compactSessionList ? 4 : 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    // MARK: - Instances List

    private var sortedInstances: [SessionState] {
        sessionMonitor.instances
    }

    private var sessionGroups: [PrimarySessionGroup] {
        PrimarySessionGroup.groups(from: sortedInstances)
    }

    private var displayedInstances: [SessionState] {
        sessionGroups.flatMap { [$0.session] + $0.childSessions }
    }

    private var displayedStableIDs: [String] {
        displayedInstances.map(\.stableId)
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - T25：kero 会话补全
    // ═════════════════════════════════════════════════════════════

    /// kero 独占行：kero 侧才知道的会话（与 hook 侧去重后的净增行）
    ///
    /// 去重规则（修复轮 1 定案）：
    ///   ① agentSession.id 命中 hook 会话 → 只补数据，不出行
    ///   ② 其余 → kero 独占行（(dir,pid) 近似匹配已删：hook 侧是
    ///      agent 进程树 PID、kero 侧是 shell PID，真实数据永不相等）
    private var keroRows: [KeroSessionMerger.Row] {
        let hookRefs = displayedInstances.map {
            KeroSessionMerger.HookSessionRef(
                sessionId: $0.sessionId,
                cwd: $0.cwd,
                pid: $0.pid
            )
        }

        return KeroSessionMerger.merge(
            inventory: keroInventory.inventory,
            hookSessions: hookRefs
        ).exclusiveRows
    }

    /// 列表条目：hook 分组与 kero 独占行按 activity 混排
    ///（hook 分组保持既有相对顺序，kero 行不另开分区）
    private var composedEntries: [ComposedListEntry] {
        let groups = sessionGroups
        let rows = keroRows
        let groupById = Dictionary(
            groups.map { ($0.session.stableId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let entries = KeroSessionListComposer.compose(
            hookGroups: groups.map {
                KeroSessionListComposer.HookGroup(
                    id: $0.session.stableId,
                    activity: $0.session.lastActivity
                )
            },
            keroRows: rows
        )

        return entries.compactMap { entry in
            switch entry {
            case .hook(let id):
                guard let group = groupById[id] else { return nil }
                return .hook(group)
            case .kero(let row):
                return .kero(row)
            }
        }
    }

    /// 行数（含 kero 独占行）：驱动面板高度估算
    private var displayedRowCount: Int {
        displayedInstances.count + keroRows.count
    }

    /// 列表条目：既有 hook 分组 或 kero 独占行
    private enum ComposedListEntry: Identifiable {
        case hook(PrimarySessionGroup)
        case kero(KeroSessionMerger.Row)

        var id: String {
            switch self {
            case .hook(let group):
                return "hook:\(group.session.stableId)"
            case .kero(let row):
                return row.id
            }
        }
    }

    private var shouldUseScrollContainer: Bool {
        // 判定口径与面板高度估算一致：hook 行 + kero 独占行的总行数
        displayedRowCount > 3 || expandedSessionStableID != nil
    }

    private var listContent: some View {
        LazyVStack(spacing: 2) {
            ForEach(composedEntries) { entry in
                switch entry {
                case .hook(let group):
                    hookGroupView(group)
                case .kero(let row):
                    keroRowView(row)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    /// 既有 hook 分组：渲染路径与改造前逐字一致，仅抽出为子视图以便与
    /// kero 行混排（不触碰 InstanceRow / SubagentAttachmentRow 任何参数）
    private func hookGroupView(_ group: PrimarySessionGroup) -> some View {
        VStack(spacing: 0) {
            InstanceRow(
                session: group.session,
                isExpanded: expandedSessionStableID == group.session.stableId,
                isSelected: selectedSessionStableID == group.session.stableId,
                isHighlighted: highlightedSessionStableID == group.session.stableId,
                isYabaiAvailable: isYabaiAvailable,
                onSelect: { selectSession(group.session) },
                onActivate: { activateSession(group.session) },
                onToggleExpanded: { toggleExpanded(group.session) },
                onFocus: { activateSession(group.session) },
                onChat: { openChat(group.session) },
                onOpenClient: { openClient(group.session) },
                onArchive: { archiveSession(group.session) },
                onTerminate: { terminateSession(group.session) },
                onApprove: { approveSession(group.session) },
                onApproveForSession: { approveSessionForScope(group.session) },
                onReject: { rejectSession(group.session) }
            )
            .id(group.session.stableId)

            if !group.childSessions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(group.childSessions) { childSession in
                        SubagentAttachmentRow(
                            session: childSession,
                            isSelected: selectedSessionStableID == childSession.stableId,
                            isHighlighted: highlightedSessionStableID == childSession.stableId,
                            onSelect: { selectSession(childSession) },
                            onActivate: { activateSession(childSession) },
                            onChat: { openChat(childSession) }
                        )
                        .id(childSession.stableId)
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 0)
                .padding(.top, 3)
                .padding(.bottom, 5)
            }
        }
    }

    /// kero 独占行：点击后跳转到对应 kero pane
    private func keroRowView(_ row: KeroSessionMerger.Row) -> some View {
        KeroSessionRowView(
            row: row,
            onActivate: { activateKeroRow(row) }
        )
        .id(row.id)
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            Group {
                if shouldUseScrollContainer {
                    ScrollView(.vertical, showsIndicators: false) {
                        listContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    listContent
                }
            }
            .onAppear {
                selectedSessionStableID = nil
                if enableKeyboardNavigation {
                    installKeyEventMonitorIfNeeded()
                }
            }
            .onDisappear {
                removeKeyEventMonitor()
            }
            .onChange(of: displayedStableIDs) { _, stableIDs in
                if let expandedSessionStableID, !stableIDs.contains(expandedSessionStableID) {
                    self.expandedSessionStableID = nil
                }
                syncSelection(with: displayedInstances)
            }
            .onChange(of: selectedSessionStableID) { _, stableID in
                guard let stableID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(stableID, anchor: .center)
                }
            }
            .onChange(of: highlightedSessionStableID) { _, stableID in
                guard let stableID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(stableID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Actions

    private func activateSession(_ session: SessionState) {
        guard !session.clientInfo.suppressesActivationNavigation else { return }
        selectSession(session)
        viewModel.notchClose()
        Task {
            let targetSession = await interactionTargetSession(for: session)
            _ = await SessionLauncher.shared.activate(targetSession)
        }
    }

    /// T25：kero 独占行激活 —— 跳转到对应 kero pane
    ///
    /// 复用既有 TerminalSessionFocuser.focusKeroSession（kero 远程直跳入口）：
    ///   · sessionId = kero 的 agentSession.id（跨 host 唯一精确匹配器）
    ///   · cwd      = 目录兜底（agent 退出后 kero 清空会话时仍能命中 pane）
    /// 远程 pane 的 tty 是远端设备路径，kero 侧仅扫本机 pane，故永不传。
    private func activateKeroRow(_ row: KeroSessionMerger.Row) {
        viewModel.notchClose()

        Task {
            await FocusDiagnosticsStore.shared.record(
                "kero-inventory jump host=\(row.host) sessionId=\(row.agentSessionId ?? "nil") cwd=\(row.dir ?? "nil") paneId=\(row.paneId ?? "nil")"
            )

            let focused = await TerminalSessionFocuser.shared.focusKeroSession(
                sessionId: row.agentSessionId,
                cwd: row.dir
            )

            await FocusDiagnosticsStore.shared.record(
                "kero-inventory jump result=\(focused) paneId=\(row.paneId ?? "nil")"
            )
        }
    }

    private func toggleExpanded(_ session: SessionState) {
        selectSession(session)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            if expandedSessionStableID == session.stableId {
                expandedSessionStableID = nil
            } else {
                expandedSessionStableID = session.stableId
            }
        }
    }

    private func openChat(_ session: SessionState) {
        selectSession(session)
        Task {
            let targetSession = await interactionTargetSession(for: session)
            await MainActor.run {
                viewModel.showChat(for: targetSession)
            }
        }
    }

    private func openClient(_ session: SessionState) {
        selectSession(session)
        Task {
            _ = await SessionLauncher.shared.activateClientApplication(session)
        }
    }

    private func approveSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func approveSessionForScope(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
    }

    private func rejectSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    private func terminateSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.terminateNativeSession(sessionId: session.sessionId)
    }

    private func selectSession(_ session: SessionState) {
        guard selectedSessionStableID != session.stableId else { return }
        selectedSessionStableID = session.stableId
    }

    private func syncSelection(with sessions: [SessionState]) {
        guard !sessions.isEmpty else {
            selectedSessionStableID = nil
            return
        }

        guard let selectedSessionStableID else {
            return
        }

        guard sessions.contains(where: { $0.stableId == selectedSessionStableID }) else {
            self.selectedSessionStableID = nil
            return
        }
    }

    private func installKeyEventMonitorIfNeeded() {
        guard enableKeyboardNavigation else { return }
        guard keyEventMonitor == nil else { return }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard viewModel.status == .opened else { return false }
        guard case .instances = viewModel.contentType else { return false }
        guard NSApp.keyWindow is NotchPanel else { return false }

        let sessions = displayedInstances
        guard !sessions.isEmpty else { return false }

        switch event.keyCode {
        case UInt16(kVK_UpArrow):
            moveSelection(delta: -1, in: sessions)
            return true
        case UInt16(kVK_DownArrow):
            moveSelection(delta: 1, in: sessions)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            activateSelectedSession(in: sessions)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int, in sessions: [SessionState]) {
        guard !sessions.isEmpty else { return }

        let currentIndex: Int
        if let selectedSessionStableID,
           let existingIndex = sessions.firstIndex(where: { $0.stableId == selectedSessionStableID }) {
            currentIndex = existingIndex
        } else {
            currentIndex = delta > 0 ? -1 : sessions.count
        }

        let targetIndex = min(max(currentIndex + delta, 0), sessions.count - 1)
        selectedSessionStableID = sessions[targetIndex].stableId
    }

    private func activateSelectedSession(in sessions: [SessionState]) {
        guard let selectedSessionStableID,
              let targetSession = sessions.first(where: { $0.stableId == selectedSessionStableID }) else {
            return
        }

        viewModel.notchClose()

        Task {
            let interactionTarget = await interactionTargetSession(for: targetSession)
            _ = await SessionLauncher.shared.activate(interactionTarget)
        }
    }

    private func interactionTargetSession(for session: SessionState) async -> SessionState {
        if let parentSessionId = session.codexParentThreadId,
           let parentSession = await SessionStore.shared.session(for: parentSessionId) {
            return parentSession
        }

        if let linkedParentSessionId = session.linkedParentSessionId,
           let linkedParentSession = await SessionStore.shared.session(for: linkedParentSessionId) {
            return linkedParentSession
        }

        return session
    }

    private func launchNativeRuntime(_ provider: SessionProvider) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "选择 \(provider.displayName) Native Runtime 工作目录"
        panel.prompt = "启动"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sessionMonitor.startNativeSession(provider: provider, cwd: url.path)
    }

    private func nativeRuntimeTint(for provider: SessionProvider) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.95, green: 0.67, blue: 0.28)
        case .codex:
            return Color(red: 0.34, green: 0.72, blue: 0.96)
        case .copilot:
            return Color.white.opacity(0.5)
        case .kimi:
            return Color(red: 0.96, green: 0.30, blue: 0.42)
        case .gemini:
            return Color(red: 0.10, green: 0.45, blue: 0.90) // Placeholder blue, adjust if needed
        case .omp:
            return TerminalColors.omp
        }
    }
}

struct PrimarySessionGroup: Identifiable, Equatable {
    let session: SessionState
    let childSessions: [SessionState]

    var id: String { session.stableId }

    static func groups(from sortedSessions: [SessionState]) -> [PrimarySessionGroup] {
        let sessionsById = Dictionary(uniqueKeysWithValues: sortedSessions.map { ($0.sessionId, $0) })
        var childrenByParentId: [String: [SessionState]] = [:]
        var nestedChildIds = Set<String>()

        for session in sortedSessions {
            guard let parentId = attachmentParentId(for: session, sessionsById: sessionsById) else {
                continue
            }

            childrenByParentId[parentId, default: []].append(session)
            nestedChildIds.insert(session.sessionId)
        }

        return sortedSessions
            .filter { !nestedChildIds.contains($0.sessionId) }
            .map { session in
                PrimarySessionGroup(
                    session: session,
                    childSessions: childrenByParentId[session.sessionId] ?? []
                )
            }
    }

    private static func attachmentParentId(
        for session: SessionState,
        sessionsById: [String: SessionState]
    ) -> String? {
        guard var parentId = session.explicitSubagentParentSessionId,
              sessionsById[parentId] != nil else {
            return nil
        }

        var visitedIds: Set<String> = [session.sessionId]
        while let parent = sessionsById[parentId],
              let nextParentId = parent.explicitSubagentParentSessionId,
              sessionsById[nextParentId] != nil,
              !visitedIds.contains(nextParentId) {
            visitedIds.insert(parentId)
            parentId = nextParentId
        }

        return parentId == session.sessionId ? nil : parentId
    }
}

private struct SubagentAttachmentRow: View {
    let session: SessionState
    let isSelected: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onChat: () -> Void

    // ── 字号跟随设置（Task 17）：与主行 metrics 同源派生 ─────────
    @ObservedObject private var settings = AppSettings.shared

    private var contentBase: CGFloat { CGFloat(settings.contentFontSize) }

    @State private var isHovered = false

    private var title: String {
        if session.isCodexSubagent {
            let role = sanitized(session.codexSubagentRole).map(Self.titleCased(_:))
            let title = sanitized(session.sessionName)
                ?? sanitized(session.firstUserMessage)
                ?? sanitized(session.previewText)
                ?? sanitized(session.displayTitle)
                ?? sanitized(session.codexSubagentNickname)

            if let role, let title, role.caseInsensitiveCompare(title) != .orderedSame {
                return "\(role) (\(title))"
            }

            return role
                ?? sanitized(session.codexSubagentNickname)
                ?? sanitized(session.codexSubagentListTitle)
                ?? session.displayTitle
        }

        return sanitized(session.linkedSubagentDisplayTitle)
            ?? sanitized(session.heuristicSubagentDisplayTitle)
            ?? sanitized(session.titleOnlySubagentDisplayTitle)
            ?? session.displayTitle
    }

    private var detail: String? {
        if let latestTool = latestToolCall {
            let preview = latestTool.inputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                return "\(latestTool.name): \(preview)"
            }
            return latestTool.statusDisplay.text
        }

        if let lastToolName = sanitized(session.lastToolName) {
            return lastToolName
        }

        if let lastMessage = sanitized(session.lastMessage) {
            return lastMessage
        }

        switch session.phase {
        case .processing:
            return AppLocalization.string("工作中...")
        case .compacting:
            return AppLocalization.string("正在压缩上下文...")
        case .waitingForApproval:
            return session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待批准")
        case .waitingForInput:
            return AppLocalization.string("等待你的下一条消息")
        case .ended:
            return AppLocalization.string("会话已结束")
        case .idle:
            return nil
        }
    }

    private var latestToolCall: ToolCallItem? {
        for item in session.chatItems.reversed() {
            if case .toolCall(let tool) = item.type {
                return tool
            }
        }
        return nil
    }

    private var ageLabel: String {
        SessionPhaseHelpers.timeBadgeLabel(for: session.attentionRequestedAt ?? session.lastActivity)
    }

    private var needsInAppResponse: Bool {
        session.needsQuestionResponse || session.needsApprovalResponse
    }

    private var rowFill: Color {
        if isSelected {
            return Color.white.opacity(isHovered ? 0.11 : 0.08)
        }
        if isHighlighted {
            return Color.white.opacity(isHovered ? 0.09 : 0.06)
        }
        return isHovered ? Color.white.opacity(0.055) : Color.clear
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: SessionListCompactMetrics.subagentTitleFontSize(base: contentBase), weight: .semibold))
                    .foregroundColor(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("└")
                            .font(.system(size: SessionListCompactMetrics.subagentDetailFontSize(base: contentBase), weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.18))
                        Text(detail)
                            .font(.system(size: SessionListCompactMetrics.subagentDetailFontSize(base: contentBase), weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 5) {
                Text(ageLabel)
                    .font(.system(size: SessionListCompactMetrics.subagentAgeFontSize(base: contentBase), weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.34))

                Text("SUBAGENT")
                    .font(.system(size: SessionListCompactMetrics.subagentBadgeFontSize(base: contentBase), weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.top, 1)
            .fixedSize()
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
            perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
        }
        .onTapGesture {
            onSelect()
            onActivate()
        }
        .onHover {
            isHovered = $0
            if $0 {
                onSelect()
            }
        }
    }

    private func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func perform(_ action: SessionListRowClickAction) {
        switch action {
        case .activate:
            onActivate()
        case .chat:
            onChat()
        case .toggleExpanded:
            break
        }
    }

    nonisolated private static func titleCased(_ text: String) -> String {
        text
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let isExpanded: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let isYabaiAvailable: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onOpenClient: () -> Void
    let onArchive: () -> Void
    let onTerminate: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var energyGovernor = EnergyGovernor.shared
    // 远程 endpoints 变化（增删主机）时刷新会话行主机徽标
    @ObservedObject private var remoteManager = RemoteConnectorManager.shared

    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.needsApprovalResponse
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        if session.needsQuestionResponse {
            return true
        }
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var providerLabel: String {
        session.messageBadgeDisplayName
    }

    private var interactionLabel: String {
        session.interactionDisplayName
    }

    private var providerColor: Color {
        session.clientTintColor
    }

    private var terminalSourceLabel: String? {
        session.terminalSourceBadgeLabel
    }

    private var showsNativeRuntimeBadge: Bool {
        session.ingress == .nativeRuntime
    }

    private var titleFontSize: CGFloat {
        CGFloat(settings.contentFontSize)
    }

    private var isCompactList: Bool {
        settings.compactSessionList
    }

    private var detailFontSize: CGFloat {
        SessionListCompactMetrics.detailFontSize(base: titleFontSize)
    }

    private var detailsEnabled: Bool {
        settings.showAgentDetail
    }

    private var isMinimalCompactPresentation: Bool {
        session.shouldUseMinimalCompactPresentation
    }

    private var isCodexSubagentCompactPresentation: Bool {
        session.shouldUseCodexSubagentCompactPresentation
    }

    private var usesSingleLineCompactLayout: Bool {
        isCollapsedCompactPresentation || isCodexSubagentCompactPresentation
    }

    private var isCollapsedCompactPresentation: Bool {
        isMinimalCompactPresentation && !isExpanded
    }

    private var usesCodexSubagentTitleOnlyPresentation: Bool {
        session.usesTitleOnlySubagentPresentation
    }

    private var needsInAppResponse: Bool {
        session.needsQuestionResponse || isWaitingForApproval
    }

    private var projectTitleFontSize: CGFloat {
        SessionListCompactMetrics.projectTitleFontSize(base: titleFontSize)
    }

    private var sessionTitleFontSize: CGFloat {
        if usesSingleLineCompactLayout {
            return max(11, titleFontSize - 1)
        }
        return SessionListCompactMetrics.sessionTitleFontSize(base: titleFontSize)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingContent

            if isCodexSubagentCompactPresentation {
                subagentCompactBadgeLine
            } else if usesCodexSubagentTitleOnlyPresentation {
                VStack(alignment: .trailing, spacing: 6) {
                    subagentCompactBadgeLine

                    trailingActions
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            } else if isCollapsedCompactPresentation {
                compactMetaLine
            } else {
                VStack(alignment: .trailing, spacing: SessionListCompactMetrics.trailingStackSpacing(compactList: isCompactList)) {
                    HStack(spacing: SessionListCompactMetrics.badgeSpacing(compactList: isCompactList)) {
                        metaBadge(
                            timeLabel,
                            tint: Color.white.opacity(0.1),
                            foreground: .white.opacity(0.64),
                            fontDesign: .monospaced,
                            compact: isCompactList
                        )
                        metaBadge(providerLabel, tint: providerColor.opacity(0.2), compact: isCompactList)
                        if let primarySupplementaryBadge {
                            supplementaryBadgeView(primarySupplementaryBadge, compact: isCompactList)
                        }
                    }

                    trailingActions
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            // ── T27：置灰行右侧展开按钮 ──
            // 行首单击统一为跳转（T26）后，展开入口消失；行尾补
            // 一个恒定入口：点按钮展开/收起，点行内其余区域照旧
            // 跳转。构造照抄 trailingActions 的 IconButton（.plain
            // 样式 + 次要色，随行的置灰修饰），点击区走 actionButtonEdge
            // 表驱动（18/22），低于 single-line 行头像高度（24/30pt），
            // 不触碰行高常量。
            if SessionListRowClickBehavior.showsExpandButton(isMinimalCompactPresentation: isMinimalCompactPresentation) {
                IconButton(
                    icon: isExpanded ? "chevron.down" : "chevron.right",
                    size: SessionListCompactMetrics.actionButtonEdge(compactList: isCompactList)
                ) {
                    perform(SessionListRowClickBehavior.expandButtonTapAction())
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, SessionListCompactMetrics.rowVerticalPadding(compactList: isCompactList, singleLine: usesSingleLineCompactLayout))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
        .saturation(isCollapsedCompactPresentation ? 0 : 1)
        .opacity(isCollapsedCompactPresentation ? 0.72 : 1)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(rowBorderColor, lineWidth: 1)
                )
        )
        .onHover {
            isHovered = $0
            if $0 {
                onSelect()
            }
        }
    }

    private var leadingContent: some View {
        Group {
            if isMinimalCompactPresentation {
                baseLeadingContent
                    .onTapGesture(count: 2) {
                        onSelect()
                        perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
                    }
                    .onTapGesture {
                        onSelect()
                        perform(SessionListRowClickBehavior.primaryTapAction())
                    }
            } else if isCodexSubagentCompactPresentation {
                baseLeadingContent
                    .onTapGesture(count: 2) {
                        onSelect()
                        perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
                    }
                    .onTapGesture {
                        onSelect()
                        perform(SessionListRowClickBehavior.primaryTapAction())
                    }
            } else {
                baseLeadingContent
                    .onTapGesture(count: 2) {
                        onSelect()
                        perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
                    }
                    .onTapGesture {
                        onSelect()
                        perform(SessionListRowClickBehavior.primaryTapAction())
                    }
            }
        }
    }

    private var baseLeadingContent: some View {
        HStack(alignment: .center, spacing: 10) {
            avatarView

            leadingTextContent

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var leadingTextContent: some View {
        VStack(alignment: .leading, spacing: SessionListCompactMetrics.leadingTextSpacing(compactList: isCompactList, singleLine: usesSingleLineCompactLayout)) {
            if shouldReserveIncomingPreviewLineHeight {
                reservedPreviewCenteringSpacer
            }

            titleLine
                .lineLimit(1)
                .truncationMode(.tail)

            if shouldShowExpandedDetails {
                previewLinesView
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }

            if shouldReserveIncomingPreviewLineHeight {
                reservedPreviewCenteringSpacer
            }
        }
    }

    private var reservedPreviewCenteringSpacer: some View {
        Color.clear
            .frame(height: reservedPreviewLineHeight / 2)
            .accessibilityHidden(true)
    }

    private var titleLine: Text {
        if usesCodexSubagentTitleOnlyPresentation || session.shouldHideProjectContextInUI {
            return Text(usesCodexSubagentTitleOnlyPresentation ? session.titleOnlySubagentDisplayTitle : session.displayTitle)
                .font(.system(size: sessionTitleFontSize, weight: .bold))
                .foregroundColor(.white)
        }

        // ── 主分支：项目名 · 会话标题（· 远程主机名） ─────────────
        var title = Text(session.projectName)
            .font(.system(size: projectTitleFontSize, weight: .semibold))
            .foregroundColor(.white.opacity(0.84))
        + Text(" · ")
            .font(.system(size: projectTitleFontSize, weight: .bold))
            .foregroundColor(.white.opacity(0.34))
        + Text(session.displayTitle)
            .font(.system(size: sessionTitleFontSize, weight: .bold))
            .foregroundColor(.white)

        // 多远程主机场景标识会话归属；透明度 0.5，视觉层级低于
        // 项目名（0.84）与会话标题（1.0）
        if let remoteHostTitle {
            title = title
                + Text(" · ")
                    .font(.system(size: projectTitleFontSize, weight: .bold))
                    .foregroundColor(.white.opacity(0.34))
                + Text(remoteHostTitle)
                    .font(.system(size: projectTitleFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
        }

        return title
    }

    /// 远程会话主机徽标：endpoint 命中取展示名，未命中回退 host 部分。
    private var remoteHostTitle: String? {
        guard session.isRemoteSession else { return nil }
        return RemoteConnectorManager.resolvedRemoteHostBadgeTitle(
            remoteHost: session.clientInfo.remoteHost,
            endpoints: remoteManager.endpoints
        )
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: SessionListCompactMetrics.avatarCornerRadius(compactList: isCompactList), style: .continuous)
                .fill(Color.white.opacity(0.04))

            MascotView(
                kind: settings.mascotKind(for: session.mascotClient),
                status: MascotStatus(session: session),
                size: SessionListCompactMetrics.avatarMascotSize(compactList: isCompactList, singleLine: usesSingleLineCompactLayout),
                animationTime: 0
            )
            .padding(SessionListCompactMetrics.avatarInset(compactList: isCompactList))

            avatarStatusBadge
                .offset(x: 2, y: 2)
        }
        .frame(
            width: SessionListCompactMetrics.avatarEdge(compactList: isCompactList, singleLine: usesSingleLineCompactLayout),
            height: SessionListCompactMetrics.avatarEdge(compactList: isCompactList, singleLine: usesSingleLineCompactLayout)
        )
    }

    @ViewBuilder
    private var avatarStatusBadge: some View {
        if session.connectionState == .disconnected {
            Image(systemName: "wifi.slash")
                .font(.system(size: SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: CGFloat(settings.contentFontSize), original: 7), weight: .bold))
                .foregroundColor(Color.white.opacity(0.56))
                .frame(width: 14, height: 14)
                .background(Color.black.opacity(0.92))
                .clipShape(Circle())
                .help(AppLocalization.string("远程连接已断开"))
        } else {
            switch session.phase {
            case .processing, .compacting, .waitingForApproval:
                animatedStatusBadge
            case .waitingForInput:
                Circle()
                    .fill(statusAccentColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.8), lineWidth: 2)
                    )
            case .idle, .ended:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var animatedStatusBadge: some View {
        if energyGovernor.policy.animationLevel == .staticFrames {
            statusBadge(symbol: spinnerSymbols[0])
        } else {
            TimelineView(.periodic(from: .now, by: statusBadgeInterval)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / statusBadgeInterval)
                statusBadge(symbol: spinnerSymbols[phase % spinnerSymbols.count])
            }
        }
    }

    private func statusBadge(symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: SessionListCompactMetrics.avatarBadgeSymbolFontSize(base: CGFloat(settings.contentFontSize), original: 8), weight: .black))
            .foregroundColor(statusAccentColor)
            .frame(width: 14, height: 14)
            .background(Color.black.opacity(0.92))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(statusAccentColor.opacity(0.35), lineWidth: 1)
            )
    }

    private var statusBadgeInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            0.15
        case .reduced:
            0.375
        case .staticFrames:
            0.15
        }
    }

    private var statusAccentColor: Color {
        if session.needsQuestionResponse {
            return TerminalColors.blue
        }
        if isWaitingForApproval {
            return TerminalColors.amber
        }
        switch session.phase {
        case .processing:
            return providerColor
        case .compacting:
            return TerminalColors.magenta
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return Color.white.opacity(0.28)
        case .waitingForApproval:
            return TerminalColors.amber
        }
    }

    private var timeLabel: String {
        SessionPhaseHelpers.timeBadgeLabel(for: session.attentionRequestedAt ?? session.lastActivity)
    }

    private var ideHostBadgeTint: Color {
        if session.ideHostBadgeLabel?.contains("Qoder") == true {
            return Color(red: 0.12, green: 0.88, blue: 0.56).opacity(0.2)
        }
        return Color.white.opacity(0.1)
    }

    private var terminalBadgeTint: Color {
        Color.white.opacity(0.1)
    }

    private enum SupplementaryBadge {
        case text(String, tint: Color, foreground: Color, fontDesign: Font.Design)
        case remote
    }

    private var primarySupplementaryBadge: SupplementaryBadge? {
        if showsNativeRuntimeBadge {
            return .text(
                "NATIVE",
                tint: Color.white.opacity(0.12),
                foreground: .white.opacity(0.92),
                fontDesign: .monospaced
            )
        }
        if let codexSubagentBadgeText = session.codexSubagentBadgeText {
            return .text(
                codexSubagentBadgeText,
                tint: Color.white.opacity(0.12),
                foreground: .white.opacity(0.9),
                fontDesign: .monospaced
            )
        }
        if session.isRemoteSession {
            return .remote
        }
        if let ideHostBadgeLabel = session.ideHostBadgeLabel {
            return .text(
                ideHostBadgeLabel,
                tint: ideHostBadgeTint,
                foreground: .white.opacity(0.9),
                fontDesign: .default
            )
        }
        if let terminalSourceLabel {
            return .text(
                terminalSourceLabel,
                tint: terminalBadgeTint,
                foreground: .white.opacity(0.9),
                fontDesign: .default
            )
        }
        return nil
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.23 : 0.19)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.22 : 0.17)
            }
            return Color.white.opacity(isHovered ? 0.14 : 0.11)
        }
        if isHighlighted {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.2 : 0.16)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.2 : 0.15)
            }
            return Color.white.opacity(isHovered ? 0.11 : 0.08)
        }
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.2 : 0.16)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.18 : 0.13)
            }
            return Color.white.opacity(isHovered ? 0.1 : 0.07)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(isHovered ? 0.16 : 0.11)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(isHovered ? 0.15 : 0.09)
        }
        if session.isExecutionActive {
            return Color.white.opacity(isHovered ? 0.08 : 0.04)
        }
        return isHovered ? Color.white.opacity(0.06) : Color.clear
    }

    private var rowBorderColor: Color {
        if isSelected {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.34)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.32)
            }
            return TerminalColors.green.opacity(isHovered ? 0.34 : 0.28)
        }
        if isHighlighted {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.32)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.3)
            }
            return Color.white.opacity(isHovered ? 0.2 : 0.16)
        }
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.28)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.26)
            }
            return Color.white.opacity(isHovered ? 0.16 : 0.12)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(0.16)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(0.16)
        }
        return Color.white.opacity(isHovered ? 0.08 : 0.04)
    }

    private var shouldShowExpandedDetails: Bool {
        guard !usesCodexSubagentTitleOnlyPresentation else { return false }
        return !isMinimalCompactPresentation || isExpanded
    }

    private var compactMetaLine: some View {
        HStack(spacing: 5) {
            metaBadge(
                timeLabel,
                tint: Color.white.opacity(0.08),
                foreground: .white.opacity(0.6),
                fontDesign: .monospaced,
                compact: true
            )

            metaBadge(
                providerLabel,
                tint: providerColor.opacity(0.18),
                foreground: .white.opacity(0.86),
                compact: true
            )
            if let primarySupplementaryBadge {
                supplementaryBadgeView(primarySupplementaryBadge, compact: true)
            }
        }
    }

    @ViewBuilder
    private var subagentCompactBadgeLine: some View {
        HStack(spacing: 5) {
            if let subagentClientTypeBadgeText = session.subagentClientTypeBadgeText {
                metaBadge(
                    subagentClientTypeBadgeText,
                    tint: providerColor.opacity(0.18),
                    foreground: .white.opacity(0.86),
                    compact: true
                )
            }

            if let codexSubagentBadgeText = session.codexSubagentBadgeText {
                metaBadge(
                    codexSubagentBadgeText,
                    tint: Color.white.opacity(0.12),
                    foreground: .white.opacity(0.9),
                    fontDesign: .monospaced,
                    compact: true
                )
            }
        }
    }

    @ViewBuilder
    private var previewLinesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let prefix = line.prefix {
                        Text(prefix)
                            .font(.system(size: detailFontSize, weight: .semibold))
                            .foregroundColor(line.prefixColor)
                    }

                    Text(line.text)
                        .font(.system(size: detailFontSize, weight: .medium))
                        .foregroundColor(line.textColor)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Active sessions often start with a single transient status line ("working...")
    /// and then immediately grow to user + assistant preview lines once the first
    /// durable message lands. Reserve the second line height up front so the list
    /// and opened-notch measurement stay stable during that first content update.
    private var shouldReserveIncomingPreviewLineHeight: Bool {
        guard detailsEnabled else { return false }
        guard shouldShowExpandedDetails else { return false }
        guard session.isExecutionActive else { return false }
        guard latestUserLine == nil else { return false }
        return previewLines.count == 1
    }

    private var reservedPreviewLineHeight: CGFloat {
        detailFontSize + 3
    }

    private var previewLines: [QueuePreviewLine] {
        var lines: [QueuePreviewLine] = []

        if let userLine = latestUserLine {
            lines.append(
                QueuePreviewLine(
                    id: "user",
                    prefix: AppLocalization.string("你："),
                    prefixColor: .white.opacity(0.52),
                    text: userLine,
                    textColor: .white.opacity(0.62)
                )
            )
        }

        if let assistantLine = latestAssistantLine {
            lines.append(
                QueuePreviewLine(
                    id: "assistant",
                    prefix: previewAssistantPrefix,
                    prefixColor: assistantPrefixColor,
                    text: assistantLine,
                    textColor: assistantTextColor
                )
            )
        }

        if lines.isEmpty, let fallback = compactDetailSummary {
            lines.append(
                QueuePreviewLine(
                    id: "fallback",
                    prefix: AppLocalization.string("状态："),
                    prefixColor: .white.opacity(0.48),
                    text: fallback,
                    textColor: .white.opacity(0.56)
                )
            )
        }

        return Array(lines.prefix(SessionListCompactMetrics.previewLineLimit(detailsEnabled: detailsEnabled, compactList: isCompactList)))
    }

    private var assistantPrefixLabel: String {
        if session.needsQuestionResponse || isWaitingForApproval {
            return interactionLabel
        }
        return session.providerDisplayName
    }

    private var previewAssistantPrefix: String? {
        let badgeLabel = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLabel = assistantPrefixLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixLabel.isEmpty, prefixLabel.caseInsensitiveCompare(badgeLabel) == .orderedSame {
            return nil
        }
        return prefixLabel.isEmpty ? nil : prefixLabel + "："
    }

    private var assistantPrefixColor: Color {
        providerColor.opacity(session.isExecutionActive ? 0.96 : 0.92)
    }

    private var assistantTextColor: Color {
        if session.needsQuestionResponse {
            return .white.opacity(0.88)
        }
        if isWaitingForApproval {
            return .white.opacity(0.74)
        }
        if session.isExecutionActive {
            return .white.opacity(0.66)
        }
        return .white.opacity(0.52)
    }

    private var latestUserLine: String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    private var latestAssistantLine: String? {
        if session.connectionState == .disconnected {
            return AppLocalization.string("远程连接已断开")
        }
        if session.needsQuestionResponse {
            return sanitized(session.intervention?.summaryText) ?? AppLocalization.string("需要你的输入")
        }

        if isWaitingForApproval {
            if isInteractiveTool {
                return AppLocalization.string("等待你补充输入")
            }
            if let toolName = session.pendingToolName {
                return AppLocalization.format(
                    "等待批准 %@",
                    MCPToolFormatter.formatToolName(toolName)
                )
            }
            return AppLocalization.string("等待批准")
        }

        if session.phase == .processing {
            if session.isNativeRuntimeSession {
                return session.codexSubagentSummaryText(
                    for: sanitized(session.lastMessage) ?? AppLocalization.string("Native runtime 正在处理…")
                )
            }
            return session.codexSubagentSummaryText(
                for: sanitized(session.lastMessage) ?? AppLocalization.string("工作中...")
            )
        }

        if session.phase == .compacting {
            return session.codexSubagentSummaryText(for: AppLocalization.string("正在压缩上下文..."))
        }

        if session.phase == .waitingForInput, session.intervention == nil {
            if session.isNativeRuntimeSession {
                return session.codexSubagentSummaryText(
                    for: sanitized(session.lastMessage) ?? AppLocalization.string("Native session 已就绪")
                )
            }
            return session.codexSubagentSummaryText(
                for: sanitized(session.lastMessage) ?? AppLocalization.string("等待你的下一条消息")
            )
        }

        if let lastMessage = sanitized(session.lastMessage) {
            return session.codexSubagentSummaryText(for: lastMessage)
        }

        return compactDetailSummary
    }

    @ViewBuilder
    private var trailingActions: some View {
        let actionButtonEdge = SessionListCompactMetrics.actionButtonEdge(compactList: isCompactList)
        if session.shouldSuppressInAppPromptControls(
            routePromptsToTerminal: settings.effectiveRoutePromptsToTerminal
        ) {
            EmptyView()
        } else if session.needsQuestionResponse {
            HStack(spacing: SessionListCompactMetrics.badgeSpacing(compactList: isCompactList)) {
                IconButton(icon: "bubble.left", size: actionButtonEdge) {
                    onChat()
                }

                if session.clientInfo.prefersAnsweredQuestionFollowupAction {
                    Button {
                        onOpenClient()
                    } label: {
                        Text(verbatim: AppLocalization.format("打开 %@", interactionLabel))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "terminal", size: actionButtonEdge) {
                        onFocus()
                    }
                }
            }
        } else if isWaitingForApproval {
            InlineApprovalButtons(
                sessionAction: session.scopedApprovalAction,
                onChat: onChat,
                onApprove: onApprove,
                onApproveForSession: onApproveForSession,
                onReject: onReject
            )
        } else {
            HStack(spacing: SessionListCompactMetrics.badgeSpacing(compactList: isCompactList)) {
                IconButton(icon: "bubble.left", size: actionButtonEdge) {
                    onChat()
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "eye", size: actionButtonEdge) {
                        onFocus()
                    }
                }

                if session.shouldShowTerminateActionInPrimaryUI {
                    IconButton(icon: "stop.circle", size: actionButtonEdge) {
                        onTerminate()
                    }
                }

                if session.shouldShowArchiveActionInPrimaryUI {
                    IconButton(icon: "archivebox", size: actionButtonEdge) {
                        onArchive()
                    }
                }
            }
        }
    }

    private func metaBadge(
        _ text: String,
        tint: Color,
        foreground: Color = .white.opacity(0.92),
        fontDesign: Font.Design = .default,
        compact: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: compact ? 7 : 8, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 3)
            .background(tint)
            .clipShape(Capsule())
    }

    private func remoteSessionBadge(compact: Bool = false) -> some View {
        Image(systemName: "cloud.fill")
            .font(.system(size: compact ? 8 : 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            .background(Color(red: 0.42, green: 0.70, blue: 0.98).opacity(compact ? 0.22 : 0.26))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .help(AppLocalization.string("远程连接"))
    }

    @ViewBuilder
    private func supplementaryBadgeView(
        _ badge: SupplementaryBadge,
        compact: Bool = false
    ) -> some View {
        switch badge {
        case .text(let text, let tint, let foreground, let fontDesign):
            metaBadge(
                text,
                tint: tint,
                foreground: foreground,
                fontDesign: fontDesign,
                compact: compact
            )
        case .remote:
            remoteSessionBadge(compact: compact)
        }
    }

    private var compactDetailSummary: String? {
        if session.connectionState == .disconnected {
            return AppLocalization.string("远程连接已断开")
        }
        switch session.phase {
        case .processing:
            return session.codexSubagentSummaryText(for: session.isNativeRuntimeSession
                ? AppLocalization.string("Native runtime 正在处理…")
                : AppLocalization.string("工作中..."))
        case .compacting:
            return session.codexSubagentSummaryText(for: AppLocalization.string("正在压缩上下文..."))
        case .waitingForApproval:
            return session.codexSubagentSummaryText(for: session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待批准"))
        case .waitingForInput:
            if session.needsQuestionResponse {
                return session.codexSubagentSummaryText(for: AppLocalization.string("需要你的输入"))
            }
            return session.codexSubagentSummaryText(for: session.isNativeRuntimeSession
                ? AppLocalization.string("Native session 已就绪")
                : AppLocalization.string("等待你的下一条消息"))
        case .ended:
            return session.codexSubagentSummaryText(for: session.isNativeRuntimeSession
                ? AppLocalization.string("Native session 已结束")
                : AppLocalization.string("会话已结束"))
        case .idle:
            return session.codexSubagentSummaryText(
                for: sanitized(session.lastMessage) ?? (session.shouldHideProjectContextInUI ? nil : session.projectName)
            )
        }
    }

    private func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func perform(_ action: SessionListRowClickAction) {
        switch action {
        case .activate:
            onActivate()
        case .chat:
            onChat()
        case .toggleExpanded:
            onToggleExpanded()
        }
    }
}

enum SessionListRowClickAction: Equatable {
    case activate
    case chat
    case toggleExpanded
}

enum SessionListRowClickBehavior {
    // ── T26：单击恒为激活跳转 ──
    // 置灰（不活动）会话行与活动行单击行为一致：任何呈现形
    // 态下行首单击都直接跳转对应终端面板。原「紧凑呈现单击
    // = 展开」分支取消（悬停预览基本不收录置灰行，waitingForInput
    // 且无待答提示的除外；展开入口见 T27）。
    nonisolated static func primaryTapAction() -> SessionListRowClickAction {
        .activate
    }

    nonisolated static func doubleTapAction(
        needsInAppResponse: Bool
    ) -> SessionListRowClickAction {
        needsInAppResponse ? .chat : .activate
    }

    // ── T27：置灰行右侧展开按钮 ──
    // T26 把行首单击统一为跳转后，展开链（.toggleExpanded →
    // onToggleExpanded → expandedSessionStableID）失去唯一生产
    // 者；按钮恢复该入口，点击仍走 perform 统一分发。
    nonisolated static func expandButtonTapAction() -> SessionListRowClickAction {
        .toggleExpanded
    }

    // 仅置灰（不活动）行显示；展开态仍显示（图标换向下用于收
    // 起），调用点不看 isExpanded。活动行在 T26 之前就无展开入
    // 口，不扩范围。
    nonisolated static func showsExpandButton(isMinimalCompactPresentation: Bool) -> Bool {
        isMinimalCompactPresentation
    }
}

// ═════════════════════════════════════════════════════════════════
// MARK: - 会话行紧凑度量（SessionListCompactMetrics）
//
// 紧凑模式（settings.compactSessionList，默认开）的密度参数集中
// 表：行垂直 padding、文本间距、字号、头像、徽章间距、尾随按钮
// 边长与行高估算全部由此纯函数驱动，InstanceRow 只做取值渲染。
// compactList = false 时所有函数返回旧版宽松值（零回归红线）；
// singleLine 指会话自身的 single-line 紧凑呈现（折叠态 / Codex
// subagent），与列表级紧凑开关正交叠加。
// ═════════════════════════════════════════════════════════════════
enum SessionListCompactMetrics {
    // ── 行字号（T20：与 hover 预览面板完全同源，密度不缩字号） ──
    // 主标题 max(14, base+2) / 项目名 max(12, base) / 详情
    // max(10, base-2)：完整面板与 hover dashboard 的行文字同大，
    // compactSessionList 只管行距/行数/头像，不再压字号。
    static func sessionTitleFontSize(base: CGFloat) -> CGFloat {
        max(14, base + 2)
    }

    static func projectTitleFontSize(base: CGFloat) -> CGFloat {
        max(12, base)
    }

    static func detailFontSize(base: CGFloat) -> CGFloat {
        max(10, base - 2)
    }

    // ── 行距 ──────────────────────────────────────────────────────
    // 行垂直 padding 宽松 8/5（regular/single-line），紧凑减半取整
    static func rowVerticalPadding(compactList: Bool, singleLine: Bool) -> CGFloat {
        switch (compactList, singleLine) {
        case (false, false): return 8
        case (false, true): return 5
        case (true, false): return 4
        case (true, true): return 3
        }
    }

    // 标题与预览行间距：single-line 恒 0（原状），regular 5→2
    static func leadingTextSpacing(compactList: Bool, singleLine: Bool) -> CGFloat {
        guard !singleLine else { return 0 }
        return compactList ? 2 : 5
    }

    // ── 预览行数：紧凑下强制单行（每行自身 lineLimit(1) 截断） ──
    static func previewLineLimit(detailsEnabled: Bool, compactList: Bool) -> Int {
        guard detailsEnabled, !compactList else { return 1 }
        return 2
    }

    // ── 头像：mascot 18→14（single-line 16→13），边框 34→26 ────
    static func avatarMascotSize(compactList: Bool, singleLine: Bool) -> CGFloat {
        switch (compactList, singleLine) {
        case (false, false): return 18
        case (false, true): return 16
        case (true, false): return 14
        case (true, true): return 13
        }
    }

    static func avatarEdge(compactList: Bool, singleLine: Bool) -> CGFloat {
        switch (compactList, singleLine) {
        case (false, false): return 34
        case (false, true): return 30
        case (true, false): return 26
        case (true, true): return 24
        }
    }

    static func avatarCornerRadius(compactList: Bool) -> CGFloat {
        compactList ? 8 : 10
    }

    static func avatarInset(compactList: Bool) -> CGFloat {
        compactList ? 5 : 6
    }

    // ── 徽章与尾随操作 ────────────────────────────────────────────
    // 徽章行水平间距 6→4；徽章行与操作按钮的垂直间距 6→3
    static func badgeSpacing(compactList: Bool) -> CGFloat {
        compactList ? 4 : 6
    }

    static func trailingStackSpacing(compactList: Bool) -> CGFloat {
        compactList ? 3 : 6
    }

    // 尾随图标按钮边长 22→18（IconButton size 参数）
    static func actionButtonEdge(compactList: Bool) -> CGFloat {
        compactList ? 18 : 22
    }

    // ── 行高估算（设计契约：紧凑 ≤ 45pt） ────────────────────────
    // 模型 = 行 padding×2 + 标题行 + (间距 + 预览行×limit)；
    // 文本行高按字号 1.25 倍近似，宽松版含预览行距 3。
    static func estimatedRowHeight(base: CGFloat, compactList: Bool) -> CGFloat {
        let title = sessionTitleFontSize(base: base)
        let detail = detailFontSize(base: base)
        let padding = rowVerticalPadding(compactList: compactList, singleLine: false)
        let lineFactor: CGFloat = 1.25
        if compactList {
            return padding * 2
                + title * lineFactor
                + leadingTextSpacing(compactList: true, singleLine: false)
                + detail * lineFactor
        }
        return padding * 2
            + title * lineFactor
            + leadingTextSpacing(compactList: false, singleLine: false)
            + 2 * detail * lineFactor
            + 3
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: 子代理子行与头像角标（Task 17 · 字号跟随设置）
    //
    // SubagentAttachmentRow 原全写死（标题 12 / 详情 11 / 年龄 10 /
    // 徽章 7），头像角标符号同样写死（wifi 7 / spinner 8）。统一改
    // 为 contentFontSize（base）派生，base=13 时与旧值零漂移；
    // 子行本身即紧凑呈现，不叠加列表级 compactList 开关。
    // ══════════════════════════════════════════════════════════════

    // ── 子行字号：偏移派生（base 13 → 12/11/10），下限防塌缩 ──
    static func subagentTitleFontSize(base: CGFloat) -> CGFloat {
        max(10, base - 1)
    }

    static func subagentDetailFontSize(base: CGFloat) -> CGFloat {
        max(9, base - 2)
    }

    static func subagentAgeFontSize(base: CGFloat) -> CGFloat {
        max(8, base - 3)
    }

    // SUBAGENT 胶囊小徽章：按 base 比例缩放并夹在 [5, 9]
    static func subagentBadgeFontSize(base: CGFloat) -> CGFloat {
        min(9, max(5, base * 7 / 13))
    }

    // ── 头像角标符号（14×14 定边圆内）：original = 旧写死值 ──────
    // 随 base 比例缩放并夹在 [original-1, original+2]，防溢出圆框
    static func avatarBadgeSymbolFontSize(base: CGFloat, original: CGFloat) -> CGFloat {
        min(original + 2, max(original - 1, original * base / 13))
    }

    // ── 子行高估算：与渲染字号同源联动 ──────────────────────────
    // 模型 = vertical padding 6×2 + 标题×1.25 + 间距 2 + 详情×1.25
    static func estimatedSubagentRowHeight(base: CGFloat) -> CGFloat {
        let title = subagentTitleFontSize(base: base)
        let detail = subagentDetailFontSize(base: base)
        return 6 * 2 + title * 1.25 + 2 + detail * 1.25
    }
}

private struct QueuePreviewLine: Identifiable {
    let id: String
    let prefix: String?
    let prefixColor: Color
    let text: String
    let textColor: Color
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let sessionAction: SessionScopedApprovalAction?
    let onChat: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var showSessionButton = false

    var body: some View {
        HStack(spacing: 5) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            ConfirmationActionButton(
                title: AppLocalization.string("Deny"),
                role: .deny,
                compact: true,
                action: onReject
            )
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            if let sessionAction {
                ConfirmationActionButton(
                    title: AppLocalization.string(sessionAction.compactButtonTitleKey),
                    role: .scopedApproval,
                    compact: true,
                    action: onApproveForSession
                )
                .opacity(showSessionButton ? 1 : 0)
                .scaleEffect(showSessionButton ? 1 : 0.8)
            }

            ConfirmationActionButton(
                title: AppLocalization.string("Allow"),
                role: .approve,
                compact: true,
                action: onApprove
            )
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showSessionButton = sessionAction != nil
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    // 紧凑会话列表下由调用方传 18（SessionListCompactMetrics 表驱动）
    var size: CGFloat = 22
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
