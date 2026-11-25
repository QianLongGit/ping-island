//
//  NotchViewModel.swift
//  PingIsland
//
//  State management for the dynamic island
//

import AppKit
import os
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // ── T21 插桩：完成弹窗点击链取证通道（os_log）───────────────
    private static let tapTrace = Logger(
        subsystem: "com.wudanwu.pingisland",
        category: "CompletionTap"
    )

    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published private(set) var presentationMode: IslandPresentationMode = .docked
    @Published private(set) var detachedDisplayMode: DetachedIslandDisplayMode = .compact
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published private(set) var openedMeasuredHeight: CGFloat?
    // ── 实例面板内容需求输入（驱动解析式高度公式） ──────────────
    // instanceRowCount：列表行数（主行+子代理行），由 SessionListView
    //   上报；isNotificationPresentationActive：完成通知卡是否正
    //   在面板内呈示，呈示时以通知卡最低高度兜底内容需求；
    //   hoverPreviewSessionCount：hover 预览 dashboard 的会话卡数
    //   （= 活动会话全量，T29 起不再按 3 封顶），由
    //   hoverPreviewSessionsProvider 派生更新（唯一更新点
    //   updateHoverPreviewSessionCount），驱动预览估算高。
    @Published private(set) var instanceRowCount: Int = 0
    @Published private(set) var hoverPreviewSessionCount: Int = 0
    @Published private(set) var isNotificationPresentationActive: Bool = false
    @Published private(set) var isFullscreenEdgeRevealActive = false
    @Published private(set) var isFullscreenPhysicalNotchCompactActive = false
    @Published private(set) var isFullscreenBrowserHiddenActive = false
    @Published private(set) var isIdleAutoHiddenActive = false
    @Published private(set) var isQuietBackgroundPresentationActive = false
    @Published private(set) var isSettingsPopoverPresented = false
    @Published private(set) var isInlineTextInputActive = false

    // MARK: - Geometry

    @Published private(set) var geometry: NotchGeometry
    let spacing: CGFloat = 12
    @Published private(set) var hasPhysicalNotch: Bool

    private static let defaultClosedHeight = ScreenNotchMetrics.fallbackClosedHeight
    private static let detachmentLongPressNarrowedWidthScale: CGFloat = 0.82
    private static let detachmentLongPressMaximumShrink: CGFloat = 56
    @Published private(set) var closedWidth: CGFloat

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    var closedHeight: CGFloat {
        usesPhysicalNotchClosedPresentation
            ? deviceNotchRect.height
            : detectedClosedHeight
    }
    var usesPhysicalNotchClosedPresentation: Bool {
        hasPhysicalNotch && isFullscreenPhysicalNotchCompactActive
    }
    var closedSize: CGSize {
        if usesPhysicalNotchClosedPresentation {
            return deviceNotchRect.size
        }
        return CGSize(width: closedWidth, height: closedHeight)
    }
    var closedScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - closedSize.width / 2,
            y: screenRect.maxY - closedSize.height,
            width: closedSize.width,
            height: closedSize.height
        )
    }

    private var detectedClosedHeight: CGFloat {
        guard hasPhysicalNotch else { return Self.defaultClosedHeight }
        let systemHeight = ceil(deviceNotchRect.height)
        return systemHeight > 0 ? systemHeight : Self.defaultClosedHeight
    }

    private func resolvedClosedWidth(preferredModuleWidthOverride: CGFloat? = nil) -> CGFloat {
        preferredModuleWidthOverride ?? preferredModuleWidth
    }

    private var preferredModuleWidth: CGFloat {
        CGFloat(AppSettingsStore.normalizedNotchModuleWidth(notchModuleWidthProvider()))
    }

    static func shouldAutoCollapseHoverPreview(
        isHovering: Bool,
        status: NotchStatus,
        openReason: NotchOpenReason,
        isSettingsPopoverPresented: Bool,
        isInlineTextInputActive: Bool,
        autoCollapseOnLeave: Bool
    ) -> Bool {
        !isHovering
            && status == .opened
            && openReason == .hover
            && !isSettingsPopoverPresented
            && !isInlineTextInputActive
            && autoCollapseOnLeave
    }

    private func narrowedClosedWidth(for baseWidth: CGFloat) -> CGFloat {
        return max(
            CGFloat(AppSettingsStore.minimumNotchModuleWidth),
            baseWidth * Self.detachmentLongPressNarrowedWidthScale,
            baseWidth - Self.detachmentLongPressMaximumShrink
        )
    }

    private func dockedClosedWidthTarget(preferredModuleWidthOverride: CGFloat? = nil) -> CGFloat {
        let baseWidth = resolvedClosedWidth(preferredModuleWidthOverride: preferredModuleWidthOverride)
        guard presentationMode == .docked, detachmentTracking != nil else {
            return baseWidth
        }
        return narrowedClosedWidth(for: baseWidth)
    }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        panelSize(for: .docked)
    }

    var detachedSize: CGSize {
        switch detachedDisplayMode {
        case .compact:
            return compactDetachedSize
        case .hoverExpanded:
            return expandedDetachedSize
        }
    }

    func panelSize(for style: IslandOpenedPresentationStyle) -> CGSize {
        let maxAllowedHeight = maximumOpenedHeight

        switch contentType {
        case .chat:
            switch style {
            case .docked:
                return CGSize(
                    width: min(screenRect.width - 64, 600),
                    height: maxAllowedHeight
                )
            case .detached:
                return CGSize(
                    width: min(screenRect.width - 96, 500),
                    height: min(maxAllowedHeight, screenRect.height - 180)
                )
            }
        case .instances:
            switch style {
            case .docked:
                // ── 面板高度（T20：点击展开恒等于用户上限） ─────────
                // 用户点击打开的完整面板直接展开到 maxAllowedHeight，
                // 不再按行数自适应收缩——少会话时面板同样全高，
                // 列表内容在面板内部滚动；通知自动弹出（openReason
                // == .notification）保持内容自适应，避免突然全高。
                // 解析式按行数×行高估算（LazyVStack 实测会被视口
                // 钳制成"自我实现的矮面板"，不可依赖）。
                let listHeight = Self.estimatedInstancesPanelHeight(
                    instanceRowCount: instanceRowCount,
                    isNotificationPresentationActive: isNotificationPresentationActive,
                    compactList: AppSettings.compactSessionList,
                    contentFontSize: CGFloat(AppSettings.contentFontSize),
                    closedHeight: closedHeight,
                    maxAllowedHeight: maxAllowedHeight
                )
                // ── 预览面板（dashboard）：实测优先，卡数估算兜底 ────
                // dashboard 为普通 VStack（非惰性）preference 实测可
                // 信；实测未回报的首帧按卡数估算（空态卡 160）。
                let panelHeight: CGFloat
                if openReason == .hover {
                    let previewEstimate = Self.estimatedHoverPreviewPanelHeight(
                        sessionCount: hoverPreviewSessionCount,
                        closedHeight: closedHeight,
                        maxAllowedHeight: maxAllowedHeight
                    )
                    panelHeight = min(
                        maxAllowedHeight,
                        max(closedHeight + 24, openedMeasuredHeight ?? previewEstimate)
                    )
                } else if openReason == .notification {
                    panelHeight = listHeight
                } else {
                    // T20：click / boot / unknown 一律恒定上限高度
                    panelHeight = maxAllowedHeight
                }
                // ── 宽度（T20：完整面板与 hover 预览同宽） ───────────
                // 完整面板（点击展开）宽度不得窄于 hover 预览面板，
                // 三态统一 min(屏宽 - 64, 600)，原 0.44×屏宽 cap 520
                // 的窄档已移除。
                return CGSize(
                    width: min(screenRect.width - 64, 600),
                    height: panelHeight
                )
            case .detached:
                return CGSize(
                    width: min(screenRect.width - 112, 400),
                    // ── T13：detached 接入同一解析式（去固定 170 与
                    // 300 封顶）：实测通知高（面板全高量纲）与解析式
                    // 取 max 融合，再走 cap 收口。
                    height: min(
                        maxAllowedHeight,
                        max(
                            closedHeight + 24,
                            max(
                                Self.estimatedInstancesPanelHeight(
                                    instanceRowCount: instanceRowCount,
                                    isNotificationPresentationActive: isNotificationPresentationActive,
                                    compactList: AppSettings.compactSessionList,
                                    contentFontSize: CGFloat(AppSettings.contentFontSize),
                                    closedHeight: closedHeight,
                                    maxAllowedHeight: maxAllowedHeight
                                ),
                                openedMeasuredHeight ?? 0
                            )
                        )
                    )
                )
            }
        }
    }

    private var compactDetachedSize: CGSize {
        if AppSettings.notchDisplayMode == .detailed {
            return closedSize
        }

        let orbEdge = max(closedSize.height, 40)
        return CGSize(width: orbEdge, height: orbEdge)
    }

    private var expandedDetachedSize: CGSize {
        let maxAllowedHeight = maximumOpenedHeight
        let fallbackHeight: CGFloat = 220

        return CGSize(
            width: min(screenRect.width - 112, 400),
            height: min(maxAllowedHeight, max(closedHeight + 24, fallbackHeight))
        )
    }

    // ── 面板高度上限（Task 15 起 detached 气泡共用） ──────────────
    // 同时叠加两类约束：用户设置（maxPanelHeight，clamp 480-700）
    // 与物理屏幕余量（screenRect.height - 120）。
    var maximumOpenedHeight: CGFloat {
        let maxPanelHeight = CGFloat(AppSettings.maxPanelHeight)
        let screenLimit = screenRect.height - 120

        if openReason == .hover {
            return min(screenLimit, maxPanelHeight)
        }

        switch contentType {
        case .chat:
            return min(screenLimit, maxPanelHeight)
        case .instances:
            return min(screenLimit, maxPanelHeight)
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    var closedNotchResizeAnimation: Animation {
        if isDetachmentNarrowingClosedNotch {
            return .linear(duration: detachmentLongPressNarrowAnimationDuration)
        }
        return .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    }

    var isDetachmentNarrowingClosedNotch: Bool {
        presentationMode == .docked && detachmentTracking != nil && status != .opened
    }

    var isDetachmentGestureActive: Bool {
        presentationMode == .docked && detachmentTracking != nil
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events: EventMonitors?
    private let fullscreenActivityProvider: @MainActor (CGRect) -> Bool
    private let fullscreenBrowserHiddenProvider: @MainActor (CGRect) -> Bool
    private let hideInFullscreenProvider: @MainActor () -> Bool
    private let autoHideWhenIdleProvider: @MainActor () -> Bool
    private let notchModuleWidthProvider: @MainActor () -> Double
    // ── hover 预览内容源（T13 智能层） ────────────────────────────
    // 由组装层注入（IslandPresentationCoordinator）：返回当前可进入
    // 预览的活动会话集合；为空时 hover 驻留直接展开完整面板，跳过
    // 「无活动会话」空态卡中转。测试注入可控数组。
    private let hoverPreviewSessionsProvider: @MainActor () -> [SessionState]
    private var hoverTimer: DispatchWorkItem?
    // Keep hover previews feeling responsive without making incidental cursor
    // passes over the notch expand it too aggressively.
    private let defaultHoverActivationDelay: TimeInterval = 0.24
    private let fullscreenHoverActivationDelay: TimeInterval = 0.18
    private let fullscreenRevealZoneHeight: CGFloat = 8
    private let fullscreenRevealZoneHorizontalInset: CGFloat = 36
    private let fullscreenStateSettleDelay: TimeInterval
    private var fullscreenPhysicalNotchCollapseWorkItem: DispatchWorkItem?
    private let detachmentLongPressDuration = IslandDetachmentGestureGate.defaultLongPressDuration
    private let detachmentLongPressNarrowAnimationDuration =
        IslandDetachmentGestureGate.defaultLongPressDuration * 20
    private let detachmentLongPressResetDuration: TimeInterval = 0.18
    private let detachmentTapMovementTolerance: CGFloat = 8
    private var detachmentLongPressWorkItem: DispatchWorkItem?

    var onDetachmentRequested: ((IslandDetachmentRequest) -> Void)?
    var onDetachmentUpdated: ((CGPoint) -> Void)?
    var onDetachmentFinished: ((CGPoint?) -> Void)?

    private struct DockedDetachmentTracking {
        let id: UUID
        let source: IslandDetachmentSource
        let startLocation: CGPoint
        var isLongPressSatisfied: Bool
        var hasExceededTapMovementTolerance: Bool
        var hasTriggeredDetachment: Bool
    }

    private var detachmentTracking: DockedDetachmentTracking?

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool,
        enableEventMonitoring: Bool = true,
        observeSystemEnvironment: Bool = true,
        fullscreenActivityProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenAppActive,
        hideInFullscreenProvider: @escaping @MainActor () -> Bool = { AppSettings.hideInFullscreen },
        fullscreenBrowserHiddenProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenBrowserActive,
        autoHideWhenIdleProvider: @escaping @MainActor () -> Bool = { AppSettings.autoHideWhenIdle },
        notchModuleWidthProvider: @escaping @MainActor () -> Double = { AppSettingsStore.defaultNotchModuleWidth },
        // ── T13 智能层：hover 预览内容源（可预览会话集合） ──────────
        // 空集合时 dwell 直接展开完整面板（跳过空态预览卡中转）。
        hoverPreviewSessionsProvider: @escaping @MainActor () -> [SessionState] = { [] },
        fullscreenStateSettleDelay: TimeInterval = 0.18
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedWidth = CGFloat(AppSettingsStore.normalizedNotchModuleWidth(notchModuleWidthProvider()))
        self.events = enableEventMonitoring ? EventMonitors.shared : nil
        self.fullscreenActivityProvider = fullscreenActivityProvider
        self.fullscreenBrowserHiddenProvider = fullscreenBrowserHiddenProvider
        self.hideInFullscreenProvider = hideInFullscreenProvider
        self.autoHideWhenIdleProvider = autoHideWhenIdleProvider
        self.notchModuleWidthProvider = notchModuleWidthProvider
        self.hoverPreviewSessionsProvider = hoverPreviewSessionsProvider
        self.fullscreenStateSettleDelay = fullscreenStateSettleDelay
        if enableEventMonitoring {
            setupEventHandlers()
        }
        if observeSystemEnvironment {
            observeEnvironment()
        }
        refreshFullscreenPresentationState()
    }

    #if compiler(>=6.3)
    // Keep teardown outside MainActor isolation; Xcode 26 can otherwise abort
    // while destroying this view model in unit-test scope teardown.
    nonisolated deinit {}
    #endif

    func updateScreenGeometry(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool
    ) {
        let updatedGeometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        let geometryChanged = updatedGeometry != geometry || hasPhysicalNotch != self.hasPhysicalNotch
        guard geometryChanged else { return }

        geometry = updatedGeometry
        self.hasPhysicalNotch = hasPhysicalNotch
        openedMeasuredHeight = nil
        syncClosedWidth(animated: false)
        refreshFullscreenPresentationState()
    }

    private func observeEnvironment() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$hideInFullscreen
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideWhenIdle
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$maxPanelHeight
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$notchModuleWidth
            .sink { [weak self] width in
                self?.syncClosedWidth(
                    animated: true,
                    animation: .easeOut(duration: 0.12),
                    preferredModuleWidth: width
                )
            }
            .store(in: &cancellables)
    }

    private func refreshFullscreenPresentationState() {
        let isFullscreenActive = fullscreenActivityProvider(screenRect)
        let shouldHideForFullscreenBrowser = fullscreenBrowserHiddenProvider(screenRect)
        let shouldUseEdgeReveal = shouldUseFullscreenEdgeReveal(isFullscreenActive: isFullscreenActive)
        let shouldUsePhysicalNotchCompact = shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive)

        if shouldHideForFullscreenBrowser != isFullscreenBrowserHiddenActive {
            isFullscreenBrowserHiddenActive = shouldHideForFullscreenBrowser
        }

        applyPhysicalNotchFullscreenState(shouldUsePhysicalNotchCompact)

        guard shouldUseEdgeReveal != isFullscreenEdgeRevealActive else { return }
        isFullscreenEdgeRevealActive = shouldUseEdgeReveal

        if shouldUseEdgeReveal {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }

        if shouldHideForFullscreenBrowser {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }
    }

    func refreshFullscreenPresentationStateForTesting() {
        refreshFullscreenPresentationState()
    }

    private func applyPhysicalNotchFullscreenState(_ shouldUsePhysicalNotchCompact: Bool) {
        if shouldUsePhysicalNotchCompact {
            fullscreenPhysicalNotchCollapseWorkItem?.cancel()
            fullscreenPhysicalNotchCollapseWorkItem = nil
            if !isFullscreenPhysicalNotchCompactActive {
                isFullscreenPhysicalNotchCompactActive = true
            }
            return
        }

        guard isFullscreenPhysicalNotchCompactActive else { return }

        fullscreenPhysicalNotchCollapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenPhysicalNotchCollapseWorkItem = nil
            let isFullscreenActive = self.fullscreenActivityProvider(self.screenRect)
            if self.shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive) {
                self.isFullscreenPhysicalNotchCompactActive = true
            } else {
                self.isFullscreenPhysicalNotchCompactActive = false
            }
        }
        fullscreenPhysicalNotchCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenStateSettleDelay, execute: workItem)
    }

    private func shouldUseFullscreenEdgeReveal(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider() && !hasPhysicalNotch && isFullscreenActive
    }

    private func shouldUsePhysicalNotchCompact(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider()
            && hasPhysicalNotch
            && isFullscreenActive
            && !isFullscreenBrowserHiddenActive
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        guard let events else { return }

        // ── 鼠标位置流：搭 routing 轻量流（interactionOnly 档亦活跃）
        //    安静能耗档下 mouseLocation 会被 EnergyGovernor 关闸，
        //    导致 hover 检测"休眠"（移入无反应）；routing 流在所有
        //    可交互档位恒活跃，作为 hover 的低功耗心跳来源。──────
        events.mouseRoutingLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDown(event)
            }
            .store(in: &cancellables)

        events.mouseDragged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDragged(event)
            }
            .store(in: &cancellables)

        events.mouseUp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseUp(event)
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode.
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're currently presenting while the island stays open.
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        guard presentationMode == .docked else { return }

        let inNotch = isPointInHoverTrigger(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        if Self.shouldAutoCollapseHoverPreview(
            isHovering: newHovering,
            status: status,
            openReason: openReason,
            isSettingsPopoverPresented: isSettingsPopoverPresented,
            isInlineTextInputActive: isInlineTextInputActive,
            autoCollapseOnLeave: AppSettings.autoCollapseOnLeave
        ) {
            notchClose()
        }

        // Start hover timer to auto-expand after a short dwell
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.performDeferredHoverOpenIfNeeded()
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverActivationDelay, execute: workItem)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard presentationMode == .docked else { return }

        if isSettingsPopoverPresented {
            return
        }

        if MouseEventReplay.isReplayed(event) {
            return
        }

        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if detachmentTriggerScreenRect.contains(location) {
                beginDockedDetachmentTracking(source: .opened, startLocation: location)
            } else if geometry.isPointOutsidePanel(location, size: openedSize) {
                // The panel window already handles click-through replay for intercepted clicks.
                notchClose()
            }
            // ── T14：面板内部点击＝纯面板动作（会话行跳转等），VM 零状态改变 ──
        case .closed, .popping:
            if detachmentTriggerScreenRect.contains(location) {
                beginDockedDetachmentTracking(source: .closed, startLocation: location)
            } else if isPointInHoverTrigger(location) {
                notchOpen(reason: .click)
            }
        }
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }
        guard var tracking = detachmentTracking else { return }

        let location = NSEvent.mouseLocation

        if !tracking.isLongPressSatisfied {
            let horizontalDistance = abs(location.x - tracking.startLocation.x)
            let verticalDistance = abs(location.y - tracking.startLocation.y)
            if max(horizontalDistance, verticalDistance) > detachmentTapMovementTolerance {
                tracking.hasExceededTapMovementTolerance = true
            }
            detachmentTracking = tracking
            return
        }

        guard IslandDetachmentGestureGate.qualifies(
            start: tracking.startLocation,
            current: location,
            hasSatisfiedLongPress: tracking.isLongPressSatisfied
        ) else {
            detachmentTracking = tracking
            return
        }

        if tracking.hasTriggeredDetachment {
            onDetachmentUpdated?(location)
        } else {
            tracking.hasTriggeredDetachment = true
            onDetachmentRequested?(
                IslandDetachmentRequest(
                    source: tracking.source,
                    dragStartScreenLocation: tracking.startLocation,
                    currentScreenLocation: location
                )
            )
        }

        detachmentTracking = tracking
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }
        guard let tracking = detachmentTracking else { return }

        let location = NSEvent.mouseLocation
        if tracking.hasTriggeredDetachment {
            onDetachmentFinished?(location)
        } else if tracking.source == .closed,
                  !tracking.isLongPressSatisfied,
                  !tracking.hasExceededTapMovementTolerance,
                  detachmentTriggerScreenRect.contains(location) {
            notchOpen(reason: .click)
        } else if tracking.source == .opened,
                  !tracking.isLongPressSatisfied,
                  !tracking.hasExceededTapMovementTolerance,
                  detachmentTriggerScreenRect.contains(location),
                  !isInChatMode {
            // ── 岛区域单击 toggle（T14）：预览态 → 完整面板；完整态 → 收起 ──
            handleIslandAreaTap()
        }

        cancelDockedDetachmentTracking()
    }

    private func beginDockedDetachmentTracking(
        source: IslandDetachmentSource,
        startLocation: CGPoint
    ) {
        hoverTimer?.cancel()
        hoverTimer = nil
        cancelDockedDetachmentTracking()

        let trackingID = UUID()
        detachmentTracking = DockedDetachmentTracking(
            id: trackingID,
            source: source,
            startLocation: startLocation,
            isLongPressSatisfied: false,
            hasExceededTapMovementTolerance: false,
            hasTriggeredDetachment: false
        )
        syncClosedWidth(
            animated: true,
            animation: .linear(duration: detachmentLongPressNarrowAnimationDuration)
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var tracking = self.detachmentTracking, tracking.id == trackingID else { return }
            tracking.isLongPressSatisfied = true
            self.detachmentTracking = tracking
            self.detachmentLongPressWorkItem = nil
            if tracking.source == .opened {
                self.notchClose()
            }
        }
        detachmentLongPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + detachmentLongPressDuration, execute: workItem)
    }

    private func cancelDockedDetachmentTracking() {
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(
            animated: true,
            animation: .easeOut(duration: detachmentLongPressResetDuration)
        )
    }

    private var hoverActivationDelay: TimeInterval {
        isFullscreenEdgeRevealActive ? fullscreenHoverActivationDelay : defaultHoverActivationDelay
    }

    var shouldHideWindowPresentation: Bool {
        if presentationMode == .detached {
            return true
        }
        if isFullscreenBrowserHiddenActive {
            return true
        }
        if isFullscreenEdgeRevealActive && status != .opened {
            return true
        }
        if isIdleAutoHiddenActive && status != .opened {
            return true
        }
        return false
    }

    var shouldHideClosedPresentation: Bool {
        shouldHideWindowPresentation
    }

    var shouldSuppressAutomaticPresentation: Bool {
        presentationMode == .detached
            || isFullscreenBrowserHiddenActive
            || (isFullscreenEdgeRevealActive && status != .opened)
    }

    var closedPresentationOffsetY: CGFloat {
        shouldHideWindowPresentation ? -(closedHeight + 12) : 0
    }

    func isPointInHoverTrigger(_ point: CGPoint) -> Bool {
        if shouldHideClosedPresentation {
            return fullscreenRevealTriggerRect.contains(point)
        }
        return isPointInClosedNotch(point)
    }

    private func isPointInClosedNotch(_ point: CGPoint) -> Bool {
        closedScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    func updateIdleAutoHiddenState(hasVisibleSessionActivity: Bool) {
        let shouldHide = autoHideWhenIdleProvider() && !hasVisibleSessionActivity
        if shouldHide != isIdleAutoHiddenActive {
            isIdleAutoHiddenActive = shouldHide
        }
    }

    func updateQuietBackgroundPresentationState(isActive: Bool) {
        guard isQuietBackgroundPresentationActive != isActive else { return }
        isQuietBackgroundPresentationActive = isActive
    }

    private var fullscreenRevealTriggerRect: CGRect {
        let width = closedSize.width + (fullscreenRevealZoneHorizontalInset * 2)
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - fullscreenRevealZoneHeight,
            width: width,
            height: fullscreenRevealZoneHeight
        )
    }

    var detachmentTriggerScreenRect: CGRect {
        closedScreenRect
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        hoverTimer?.cancel()
        hoverTimer = nil

        if reason == .notification && shouldSuppressAutomaticPresentation {
            return
        }

        openReason = reason
        status = .opened
        if case .instances = contentType {
            openedMeasuredHeight = nil
        }

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Hover opens a lightweight preview instead of restoring the full chat view.
        if reason == .hover {
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func performDeferredHoverOpenIfNeeded() {
        guard isHovering else { return }
        guard status == .closed || status == .popping else { return }
        // ── 智能打开层（T13）────────────────────────────────────
        // 预览有内容（activePreviewSessions 非空）→ hover 轻量预览；
        // 无内容 → 跳过「无活动会话」空态中转，直接完整面板。
        // 打开瞬间同步卡数，让首帧高度估算即用准实时值（随后由
        // preference 实测接管，见 panelSize hover 分流）。
        let previewSessions = hoverPreviewSessionsProvider()
        updateHoverPreviewSessionCount(previewSessions.count)
        notchOpen(reason: previewSessions.isEmpty ? .click : .hover)
    }

    /// 岛区域（notch pill，打开后仍占据 closedScreenRect 的顶部条）单击 toggle（T14）：
    /// 预览态 → 单下直达完整面板；完整/通知态 → 收起。
    /// 仅由岛 pill 的 tap 判定（handleMouseUp 的 detach 跟踪短按分支）调用；
    /// 面板内部点击不走此路径——那是纯面板动作（会话行跳转等），
    /// 由 SwiftUI 视图自持手势承接，VM 不得借 mouseDown 抢跑改状态。
    func handleIslandAreaTap() {
        if openReason == .hover {
            notchOpen(reason: .click)
        } else {
            notchClose()
        }
    }

    func notchClose() {
        status = .closed
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
        isInlineTextInputActive = false
    }

    func beginDetachedPresentation(contentType: NotchContentType, playSound: Bool = true) {
        hoverTimer?.cancel()
        hoverTimer = nil
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(animated: false)
        isHovering = false
        detachedDisplayMode = .compact
        openedMeasuredHeight = nil

        switch contentType {
        case .chat(let session):
            currentChatSession = session
        case .instances:
            currentChatSession = nil
        }

        self.contentType = .instances
        openReason = .click
        status = .opened
        presentationMode = .detached
        if playSound {
            AppSettings.playDetachedCapsuleSound()
        }
    }

    func setDetachedDisplayMode(_ mode: DetachedIslandDisplayMode) {
        guard presentationMode == .detached else { return }
        guard detachedDisplayMode != mode else { return }
        detachedDisplayMode = mode
        if mode == .compact {
            openedMeasuredHeight = nil
        }
    }

    func redockAfterDetached() {
        cancelDockedDetachmentTracking()
        detachedDisplayMode = .compact
        notchClose()
        presentationMode = .docked
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func setSettingsPopoverPresented(_ isPresented: Bool) {
        isSettingsPopoverPresented = isPresented
    }

    func setInlineTextInputActive(_ isActive: Bool) {
        guard isInlineTextInputActive != isActive else { return }
        isInlineTextInputActive = isActive
    }

    func showChat(for session: SessionState) {
        // ── T21 插桩：VM 层会话面板呈现入口（含点击/自动两路）──
        // 只打 case 标签摘要（复用 NotchContentType.id 语义）：严禁
        // String(describing:) —— 它会全量反射 SessionState 携带的
        // 对话内容（chatItems/previewText/conversationInfo），以
        // public 隐私持久写入系统日志属于隐私泄漏。
        let contentTypeSummary: String
        if case .chat(let current) = contentType {
            contentTypeSummary = "chat-\(current.sessionId.prefix(8))"
        } else {
            contentTypeSummary = "instances"
        }
        Self.tapTrace.notice(
            "vm.showChat session=\(session.sessionId.prefix(8), privacy: .public) contentType=\(contentTypeSummary, privacy: .public)"
        )
        currentChatSession = session
        openedMeasuredHeight = nil

        // Avoid unnecessary updates only when the snapshot is already current.
        if case .chat(let current) = contentType, current == session {
            return
        }
        contentType = .chat(session)
    }

    func presentChat(for session: SessionState, reason: NotchOpenReason = .click) {
        notchOpen(reason: reason)
        showChat(for: session)
    }

    func toggleChat(for session: SessionState, reason: NotchOpenReason = .click) {
        if status == .opened,
           case .chat(let currentSession) = contentType,
           currentSession.sessionId == session.sessionId {
            notchClose()
            return
        }

        presentChat(for: session, reason: reason)
    }

    /// Surface a session from an automatic notification without collapsing first.
    /// This keeps attention-driven panel refreshes stable when the notch is already open.
    func presentNotificationChat(for session: SessionState) {
        // ── T21 插桩：自动通知链路的会话呈现（区别于点击链）──
        Self.tapTrace.notice(
            "vm.presentNotificationChat session=\(session.sessionId.prefix(8), privacy: .public)"
        )
        notchOpen(reason: .notification)
        showChat(for: session)
    }

    /// Surface manual-attention content through the route resolver instead of forcing chat.
    /// Approval cards should take priority over the underlying session detail view.
    func presentNotificationAttention() {
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
        notchOpen(reason: .notification)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
    }

    func presentSessionList(reason: NotchOpenReason = .click) {
        exitChat()
        notchOpen(reason: reason)
    }

    func toggleSessionList(reason: NotchOpenReason = .click) {
        if status == .opened,
           reason == .click,
           openReason == .click,
           case .instances = contentType {
            notchClose()
            return
        }

        presentSessionList(reason: reason)
    }

    func updateOpenedMeasuredHeight(_ height: CGFloat?) {
        let sanitized = height.map { max(closedHeight, ceil($0)) }

        guard sanitized != openedMeasuredHeight else { return }
        openedMeasuredHeight = sanitized
    }

    // ── 高度公式输入上报 ────────────────────────────────────────
    // SessionListView / NotchView 在内容变化时调用；写入触发
    // objectWillChange → panelSize 重算 → 面板高度随行数自适应。

    func updateInstanceRowCount(_ count: Int) {
        let sanitized = max(0, count)

        guard sanitized != instanceRowCount else { return }
        instanceRowCount = sanitized
    }

    func updateHoverPreviewSessionCount(_ count: Int) {
        let sanitized = max(0, count)

        guard sanitized != hoverPreviewSessionCount else { return }
        hoverPreviewSessionCount = sanitized
    }

    func updateNotificationPresentationActive(_ isActive: Bool) {
        guard isActive != isNotificationPresentationActive else { return }
        isNotificationPresentationActive = isActive
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 实例面板高度解析式（内容自适应 · 上限封顶）
    //
    // height = min(maxAllowedHeight,
    //              max(closedHeight + 24,              ← 最小可用高
    //                  closedHeight + 12 + contentHeight)) ← 需求高
    // contentHeight = max(列表解析高, 通知卡最低高)
    // 列表解析高 = 行数 × metrics 行高 + (行数-1) × 行距 2
    //            + 列表竖直 padding 4 × 2
    // closedHeight+12 与 NotchView 实测换算（openedMeasuredHeight
    // = closedHeight + contentHeight + 12）同源，纯函数可测。
    // ═══════════════════════════════════════════════════════════════
    static func estimatedInstancesPanelHeight(
        instanceRowCount: Int,
        isNotificationPresentationActive: Bool,
        compactList: Bool,
        contentFontSize: CGFloat,
        closedHeight: CGFloat,
        maxAllowedHeight: CGFloat
    ) -> CGFloat {
        let rowCount = max(0, instanceRowCount)
        let rowHeight = SessionListCompactMetrics.estimatedRowHeight(
            base: contentFontSize,
            compactList: compactList
        )
        let listSpacing: CGFloat = 2
        let listVerticalPadding: CGFloat = 8
        let listHeight = CGFloat(rowCount) * rowHeight
            + CGFloat(max(0, rowCount - 1)) * listSpacing
            + listVerticalPadding
        let notificationFloor = isNotificationPresentationActive
            ? SessionCompletionNotificationView.minimumContentHeight
            : 0
        let contentHeight = max(listHeight, notificationFloor)
        let chromeOverhead = closedHeight + 12

        return min(
            maxAllowedHeight,
            max(closedHeight + 24, chromeOverhead + contentHeight)
        )
    }

    // ═══════════════════════════════════════════════════════════════
    // hover 预览面板高度解析式（T13）：
    //   高度 = min(上限, max(closedHeight + 24, closedHeight + 12 + 预览内容高))
    // 预览内容高（regular 密度）= topPadding 12 + 卡数 × 62 +
    //   (卡数 - 1) × containerSpacing 18 + bottomPadding 18；
    // 62 ≈ SessionHoverCompactRow 实际渲染高（itemV 12×2 + 标题
    // 13×1.3 + 行内间距 6 + 详情 10.5×1.3），highlighted 卡更高——
    // 首帧估算后由 preference 实测接管修正；0 卡时空态卡按 160 估。
    // 与 estimatedInstancesPanelHeight 同源换算（chrome+12），纯函数。
    // ═══════════════════════════════════════════════════════════════
    static func estimatedHoverPreviewPanelHeight(
        sessionCount: Int,
        closedHeight: CGFloat,
        maxAllowedHeight: CGFloat
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowHeight: CGFloat = 62
        let cardSpacing: CGFloat = 18
        let topPadding: CGFloat = 12
        let bottomPadding: CGFloat = 18
        let emptyCardHeight: CGFloat = 160

        let contentHeight: CGFloat
        if count == 0 {
            contentHeight = emptyCardHeight
        } else {
            contentHeight = topPadding
                + CGFloat(count) * rowHeight
                + CGFloat(count - 1) * cardSpacing
                + bottomPadding
        }
        let chromeOverhead = closedHeight + 12

        return min(
            maxAllowedHeight,
            max(closedHeight + 24, chromeOverhead + contentHeight)
        )
    }

    func setManualAttentionActive(_ isActive: Bool) {
        syncClosedWidth(animated: false)
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        guard !shouldSuppressAutomaticPresentation else { return }
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }

    private func syncClosedWidth(
        animated: Bool,
        animation: Animation? = nil,
        preferredModuleWidth: Double? = nil
    ) {
        let targetWidth = dockedClosedWidthTarget(
            preferredModuleWidthOverride: preferredModuleWidth.map {
                CGFloat(AppSettingsStore.normalizedNotchModuleWidth($0))
            }
        )
        guard closedWidth != targetWidth else { return }

        if animated, let animation {
            withAnimation(animation) {
                closedWidth = targetWidth
            }
        } else {
            closedWidth = targetWidth
        }
    }

#if DEBUG
    func beginDockedDetachmentTrackingForTesting(
        source: IslandDetachmentSource = .closed,
        startLocation: CGPoint = .zero
    ) {
        beginDockedDetachmentTracking(source: source, startLocation: startLocation)
    }

    func cancelDockedDetachmentTrackingForTesting() {
        cancelDockedDetachmentTracking()
    }

    func syncClosedWidthForTesting(preferredModuleWidth: Double) {
        syncClosedWidth(animated: false, preferredModuleWidth: preferredModuleWidth)
    }
#endif
}
