import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Ping_Island

@MainActor
final class DetachedIslandWindowControllerTests: XCTestCase {
    private var originalSmartSuppression = true
    private var completionRegistries: [SessionCompletionNotificationRegistry] = []

    override func setUp() async throws {
        try await super.setUp()
        originalSmartSuppression = AppSettings.smartSuppression
        AppSettings.smartSuppression = false
    }

    override func tearDown() async throws {
        completionRegistries.removeAll()
        AppSettings.smartSuppression = originalSmartSuppression
        try await super.tearDown()
    }

    func testDetachedHostingViewStaysTransparent() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let contentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(contentView.isOpaque)
        XCTAssertTrue(contentView.wantsLayer)

        let layer = try XCTUnwrap(contentView.layer)
        XCTAssertFalse(layer.isOpaque)
        XCTAssertEqual(layer.backgroundColor, NSColor.clear.cgColor)
    }

    func testDetachedHostingViewAcceptsFirstMouse() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let contentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(contentView.acceptsFirstMouse(for: nil))
    }

    func testDetachedWindowDisablesSystemShadow() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
    }

    func testDetachedWindowUsesCustomDragInsteadOfBackgroundDragging() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    func testDetachedWindowSupportsFullscreenFloatingPresentation() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
    }

    func testQuietBackgroundDimsDetachedPetUntilBubbleInteraction() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [
            makeSession(id: "active", phase: .processing)
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {},
            energyModePublisher: Empty<EnergyMode, Never>(completeImmediately: false).eraseToAnyPublisher()
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1260, y: 180), activatesApplication: false)
        controller.applyEnergyModeForTesting(.quietBackground)

        XCTAssertEqual(try XCTUnwrap(controller.windowAlphaForTesting), 0.38, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)

        controller.presentHoverBubbleForTesting()
        controller.applyEnergyModeForTesting(.quietBackground)

        XCTAssertEqual(try XCTUnwrap(controller.windowAlphaForTesting), 1, accuracy: 0.01)

        controller.hideBubbleForTesting()
        waitForBubbleHidden(controller)
        controller.applyEnergyModeForTesting(.quietBackground)

        XCTAssertEqual(try XCTUnwrap(controller.windowAlphaForTesting), 0.38, accuracy: 0.01)

        controller.applyEnergyModeForTesting(.active)
        XCTAssertEqual(try XCTUnwrap(controller.windowAlphaForTesting), 1, accuracy: 0.01)
    }

    func testPetInteractionFrameConvertsTopAnchoredLayoutIntoWindowCoordinates() {
        let layout = DetachedIslandWindowLayout(
            containerSize: CGSize(width: 92, height: 164),
            petFrame: CGRect(x: 0, y: 36, width: 92, height: 92),
            bubbleFrame: CGRect(x: 104, y: 12, width: 280, height: 140),
            bubblePlacement: .topRight,
            petAnchorInWindow: CGPoint(x: 46, y: 82),
            bubbleContentMode: .hoverPreview
        )

        let frame = DetachedIslandWindowController.petInteractionFrame(for: layout)

        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(frame.origin.y, 36, accuracy: 0.5)
        XCTAssertEqual(frame.width, 92, accuracy: 0.5)
        XCTAssertEqual(frame.height, 92, accuracy: 0.5)
    }

    func testFloatingDragTranslationUsesScreenCoordinates() {
        let translation = DetachedIslandWindowController.floatingDragTranslation(
            from: CGPoint(x: 400, y: 600),
            to: CGPoint(x: 438, y: 572)
        )

        XCTAssertEqual(translation.width, 38, accuracy: 0.5)
        XCTAssertEqual(translation.height, -28, accuracy: 0.5)
    }

    func testQuartzScreenCoordinatesConvertToPositiveUpwardFloatingDragTranslation() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let start = MouseEventReplay.appKitScreenLocation(
            fromQuartzScreenLocation: CGPoint(x: 400, y: 600),
            screenBounds: screenBounds
        )
        let current = MouseEventReplay.appKitScreenLocation(
            fromQuartzScreenLocation: CGPoint(x: 438, y: 572),
            screenBounds: screenBounds
        )

        let translation = DetachedIslandWindowController.floatingDragTranslation(
            from: start,
            to: current
        )

        XCTAssertEqual(translation.width, 38, accuracy: 0.5)
        XCTAssertEqual(translation.height, 28, accuracy: 0.5)
    }

    func testFloatingDragUpdatesWindowOrigin() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let window = try XCTUnwrap(controller.window)
        window.setFrame(
            NSRect(x: 180, y: 420, width: 100, height: 100),
            display: false
        )

        controller.beginFloatingDrag()
        let dragStartOrigin = window.frame.origin
        controller.updateFloatingDrag(translation: CGSize(width: 24, height: 16))
        controller.endFloatingDrag()

        XCTAssertEqual(window.frame.origin.x, dragStartOrigin.x + 24, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, dragStartOrigin.y + 16, accuracy: 0.5)
    }

    func testFloatingDragKeepsMouseEventsEnabled() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        let window = try XCTUnwrap(controller.window)
        window.ignoresMouseEvents = false

        controller.beginFloatingDrag()

        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testFloatingDragUpdatesPetDraggingState() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        XCTAssertFalse(controller.isPetDraggingForTesting)

        controller.beginFloatingDrag()
        XCTAssertTrue(controller.isPetDraggingForTesting)

        controller.endFloatingDrag()
        XCTAssertFalse(controller.isPetDraggingForTesting)
    }

    func testBeginFloatingDragPreservesPetAnchorWhenHoverBubbleIsVisible() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [
            makeSession(id: "active", phase: .processing)
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1260, y: 180))
        controller.presentHoverBubbleForTesting()

        let beforeAnchor = try XCTUnwrap(controller.currentPetAnchor)
        controller.beginFloatingDrag()
        let afterAnchor = try XCTUnwrap(controller.currentPetAnchor)

        XCTAssertEqual(beforeAnchor.x, afterAnchor.x, accuracy: 0.5)
        XCTAssertEqual(beforeAnchor.y, afterAnchor.y, accuracy: 0.5)
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
        XCTAssertFalse(controller.isBubbleVisibleForTesting)
    }

    func testPetSecondaryClickPresentsSettingsWindow() throws {
        let settingsController = SettingsWindowController.shared
        settingsController.dismiss()

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer {
            controller.dismiss()
            settingsController.dismiss()
        }

        controller.handlePetSecondaryClick()

        let window = try XCTUnwrap(settingsController.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isMiniaturized)
    }

    func testPresentConsumesFloatingPetSettingsHintPending() {
        let previousValue = AppSettings.floatingPetSettingsHintPending
        AppSettings.floatingPetSettingsHintPending = true
        defer { AppSettings.floatingPetSettingsHintPending = previousValue }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = []

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1100, y: 180))

        XCTAssertFalse(AppSettings.floatingPetSettingsHintPending)
    }

    func testDefaultPetAnchorUsesBottomTrailingVisibleFrameInsets() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1
        defer { AppSettings.floatingPetScale = originalScale }
        let visibleFrame = CGRect(x: 100, y: 60, width: 960, height: 640)

        let anchor = DetachedIslandWindowController.defaultPetAnchor(in: visibleFrame)

        XCTAssertEqual(anchor.x, 982, accuracy: 0.5)
        XCTAssertEqual(anchor.y, 154, accuracy: 0.5)
    }

    func testDefaultPetAnchorCanAlignToActiveWindowBottomTrailingCorner() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1
        defer { AppSettings.floatingPetScale = originalScale }
        let visibleFrame = CGRect(x: 80, y: 40, width: 1200, height: 800)
        let activeWindowFrame = CGRect(x: 320, y: 180, width: 640, height: 420)

        let anchor = DetachedIslandWindowController.defaultPetAnchor(
            in: visibleFrame,
            alignedTo: activeWindowFrame
        )

        XCTAssertEqual(anchor.x, 882, accuracy: 0.5)
        XCTAssertEqual(anchor.y, 274, accuracy: 0.5)
    }

    func testFloatingPetAnchorRoundTripsThroughVisibleFrameRatios() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1
        defer { AppSettings.floatingPetScale = originalScale }
        let visibleFrame = CGRect(x: 40, y: 24, width: 1280, height: 720)
        let petAnchor = CGPoint(x: 1110, y: 144)

        let storedAnchor = DetachedIslandWindowController.floatingPetAnchor(
            from: petAnchor,
            in: visibleFrame
        )
        let restoredAnchor = DetachedIslandWindowController.petAnchor(
            from: storedAnchor,
            in: visibleFrame
        )

        XCTAssertEqual(restoredAnchor.x, petAnchor.x, accuracy: 0.5)
        XCTAssertEqual(restoredAnchor.y, petAnchor.y, accuracy: 0.5)
    }

    func testStoredFloatingPetAnchorClampsBackIntoVisibleFrame() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1
        defer { AppSettings.floatingPetScale = originalScale }
        let visibleFrame = CGRect(x: 0, y: 0, width: 400, height: 240)
        let storedAnchor = FloatingPetAnchor(xRatio: 1.4, yRatio: -0.3)

        let restoredAnchor = DetachedIslandWindowController.petAnchor(
            from: storedAnchor,
            in: visibleFrame
        )

        XCTAssertEqual(restoredAnchor.x, 354, accuracy: 0.5)
        XCTAssertEqual(restoredAnchor.y, 46, accuracy: 0.5)
    }

    func testFloatingPetUsesStandardSizeOnBaselineResolution() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1
        defer { AppSettings.floatingPetScale = originalScale }
        let viewModel = makeViewModel(screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900))

        let layout = DetachedIslandContentModel.layout(
            for: [],
            viewModel: viewModel,
            bubbleState: .hidden,
            bubblePlacement: .topLeft
        )

        XCTAssertEqual(layout.containerSize.width, 92, accuracy: 0.5)
        XCTAssertEqual(layout.containerSize.height, 92, accuracy: 0.5)
        XCTAssertEqual(layout.petFrame.width, 92, accuracy: 0.5)
        XCTAssertEqual(layout.petFrame.height, 92, accuracy: 0.5)
    }

    func testFloatingPetUsesCustomScaleAcrossDisplays() {
        let originalScale = AppSettings.floatingPetScale
        AppSettings.floatingPetScale = 1.4
        defer { AppSettings.floatingPetScale = originalScale }
        let highResolutionFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let viewModel = makeViewModel(screenRect: highResolutionFrame)
        let petMetrics = DetachedIslandPanelMetrics.petMetrics()

        let layout = DetachedIslandContentModel.layout(
            for: [],
            viewModel: viewModel,
            bubbleState: .hidden,
            bubblePlacement: .topLeft
        )

        XCTAssertEqual(petMetrics.scale, 1.4, accuracy: 0.001)
        XCTAssertEqual(layout.containerSize.width, 92 * petMetrics.scale, accuracy: 0.5)
        XCTAssertEqual(layout.containerSize.height, 92 * petMetrics.scale, accuracy: 0.5)
        XCTAssertEqual(layout.petAnchorInWindow.x, layout.containerSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(layout.petAnchorInWindow.y, layout.containerSize.height / 2, accuracy: 0.5)
    }

    func testFloatingPetScaleSupportsStandardSize() {
        let petMetrics = DetachedIslandPanelMetrics.petMetrics(scale: 1)

        XCTAssertEqual(petMetrics.scale, 1, accuracy: 0.001)
        XCTAssertEqual(petMetrics.petHitFrame, 92, accuracy: 0.5)
    }

    func testFloatingPetScaleSupportsIntermediateSize() {
        let petMetrics = DetachedIslandPanelMetrics.petMetrics(scale: 1.16)

        XCTAssertEqual(petMetrics.scale, 1.16, accuracy: 0.001)
        XCTAssertEqual(petMetrics.petHitFrame, 106.72, accuracy: 0.5)
    }

    func testFloatingPetScaleSupportsMaximumSize() {
        let petMetrics = DetachedIslandPanelMetrics.petMetrics(scale: 10)

        XCTAssertEqual(petMetrics.scale, 10, accuracy: 0.001)
        XCTAssertEqual(petMetrics.mascotDisplaySize, 460, accuracy: 0.5)
        XCTAssertEqual(petMetrics.petHitFrame, 920, accuracy: 0.5)
        XCTAssertEqual(petMetrics.floatingUsageBoltFontSize, 80, accuracy: 0.5)
        XCTAssertEqual(petMetrics.activeCountFontSize(for: 1), 92, accuracy: 0.5)
    }

    func testFloatingPetOverlaySpacingDoesNotGrowWithScale() {
        let standardMetrics = DetachedIslandPanelMetrics.petMetrics(scale: 1)
        let enlargedMetrics = DetachedIslandPanelMetrics.petMetrics(scale: 6)

        XCTAssertEqual(standardMetrics.badgeOffset, CGSize(width: 4, height: 2))
        XCTAssertEqual(enlargedMetrics.badgeOffset, standardMetrics.badgeOffset)
        XCTAssertEqual(
            enlargedMetrics.floatingUsageBoltGap,
            standardMetrics.floatingUsageBoltGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            enlargedMetrics.activeCountFontSize(for: 1),
            standardMetrics.activeCountFontSize(for: 1) * 6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            enlargedMetrics.floatingUsageBoltFontSize,
            standardMetrics.floatingUsageBoltFontSize * 6,
            accuracy: 0.001
        )
    }

    func testFloatingPetMetricsClampToSupportedScaleRange() {
        XCTAssertEqual(DetachedIslandPetMetrics(scale: 0.5).scale, 1, accuracy: 0.001)
        XCTAssertEqual(DetachedIslandPetMetrics(scale: 2).scale, 2, accuracy: 0.001)
        XCTAssertEqual(DetachedIslandPetMetrics(scale: 12).scale, 10, accuracy: 0.001)
    }

    func testVisibleSessionCountIncludesIdleSessions() {
        // T18：徽章=可见会话数——空闲/已结束会话与执行中一律计入
        let sessions = [
            makeSession(id: "processing", phase: .processing),
            makeSession(id: "waiting", phase: .waitingForInput),
            makeSession(id: "ended", phase: .ended)
        ]

        XCTAssertEqual(DetachedIslandContentModel.visibleSessionCount(from: sessions), 3)
    }

    func testVisibleSessionCountIsZeroWhenNoSessions() {
        // T18：0 会话得 0——上层以 count>0 隐藏徽章，语义保持
        XCTAssertEqual(DetachedIslandContentModel.visibleSessionCount(from: []), 0)
    }

    func testVisibleSessionCountSupportsDoubleDigits() {
        // T18：两位数值链不回归（≥10 走徽章收字距分支）
        let sessions = (0..<12).map { index in
            makeSession(id: "session-\(index)", phase: index == 0 ? .processing : .waitingForInput)
        }

        XCTAssertEqual(DetachedIslandContentModel.visibleSessionCount(from: sessions), 12)
    }

    func testBubblePlacementPriorityPrefersTopLeftWhenItFits() {
        XCTAssertEqual(
            DetachedIslandContentModel.preferredBubblePlacement(
                for: CGPoint(x: 980, y: 320),
                bubbleSize: CGSize(width: 280, height: 180),
                availableFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            .topLeft
        )
    }

    func testBubblePlacementFallsBackToTopRightWhenLeftSpaceIsTight() {
        XCTAssertEqual(
            DetachedIslandContentModel.preferredBubblePlacement(
                for: CGPoint(x: 180, y: 320),
                bubbleSize: CGSize(width: 280, height: 180),
                availableFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            .topRight
        )
    }

    func testBubblePlacementFallsBackToBottomLeftWhenTopRowDoesNotFit() {
        XCTAssertEqual(
            DetachedIslandContentModel.preferredBubblePlacement(
                for: CGPoint(x: 980, y: 760),
                bubbleSize: CGSize(width: 280, height: 180),
                availableFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            .bottomLeft
        )
    }

    func testBubblePlacementFallsBackToBottomRightWhenOnlyTrailingBottomFits() {
        XCTAssertEqual(
            DetachedIslandContentModel.preferredBubblePlacement(
                for: CGPoint(x: 180, y: 760),
                bubbleSize: CGSize(width: 280, height: 180),
                availableFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            .bottomRight
        )
    }

    func testBubbleShapeKeepsAllCornersRoundedForEveryPlacement() {
        let rect = CGRect(x: 0, y: 0, width: 280, height: 180)
        let cornerSamples = [
            CGPoint(x: rect.minX + 1, y: rect.minY + 1),
            CGPoint(x: rect.maxX - 1, y: rect.minY + 1),
            CGPoint(x: rect.maxX - 1, y: rect.maxY - 1),
            CGPoint(x: rect.minX + 1, y: rect.maxY - 1)
        ]

        for placement in DetachedIslandBubblePlacement.allCases {
            let path = DetachedIslandBubbleShape(placement: placement).path(in: rect)

            for sample in cornerSamples {
                XCTAssertFalse(
                    path.contains(sample),
                    "Expected \(placement) bubble to keep corner sample \(sample) transparent"
                )
            }
        }
    }

    func testBubbleContentWidthReservesRenderInsetAndPadding() {
        let frameWidth: CGFloat = 280
        let expectedWidth = frameWidth
            - (DetachedIslandPanelMetrics.bubbleRenderInset * 2)
            - (DetachedIslandPanelMetrics.bubbleHorizontalPadding * 2)

        XCTAssertEqual(
            DetachedIslandContentModel.contentWidth(for: frameWidth),
            expectedWidth,
            accuracy: 0.5
        )
    }

    func testBubbleLayoutLeavesWindowGutterAroundRenderedBubble() throws {
        let viewModel = makeViewModel()
        let session = makeSession(id: "active", phase: .processing)

        for placement in DetachedIslandBubblePlacement.allCases {
            let layout = DetachedIslandContentModel.layout(
                for: [session],
                viewModel: viewModel,
                bubbleState: .hoverPreview,
                bubblePlacement: placement
            )
            let bubbleFrame = try XCTUnwrap(layout.bubbleFrame)
            let gutter = DetachedIslandPanelMetrics.bubbleWindowGutter

            XCTAssertGreaterThanOrEqual(bubbleFrame.minX, gutter, "minX for \(placement)")
            XCTAssertGreaterThanOrEqual(bubbleFrame.minY, gutter, "minY for \(placement)")
            XCTAssertLessThanOrEqual(
                bubbleFrame.maxX,
                layout.containerSize.width - gutter,
                "maxX for \(placement)"
            )
            XCTAssertLessThanOrEqual(
                bubbleFrame.maxY,
                layout.containerSize.height - gutter,
                "maxY for \(placement)"
            )
        }
    }

    func testHoverPreviewUsesSharedAttentionRouteWhenNeeded() {
        let attention = makeSession(
            id: "attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        let active = makeSession(id: "active", phase: .processing)
        let interactionModel = DetachedIslandInteractionModel()
        let viewModel = makeViewModel()

        interactionModel.presentHoverPreview(canPresentBubble: true)

        XCTAssertEqual(interactionModel.bubbleContentMode, .hoverPreview)
        XCTAssertEqual(
            DetachedIslandContentModel.route(
                for: [active, attention],
                viewModel: viewModel,
                mode: .hoverPreview
            ),
            .attentionNotification(attention)
        )
    }

    func testPinnedBubbleUsesSharedSessionListRoute() {
        let active = makeSession(id: "active", phase: .processing)
        let interactionModel = DetachedIslandInteractionModel()
        let viewModel = makeViewModel()

        interactionModel.togglePinned(canPresentBubble: true)

        XCTAssertEqual(interactionModel.bubbleContentMode, .pinnedList)
        XCTAssertEqual(
            DetachedIslandContentModel.route(
                for: [active],
                viewModel: viewModel,
                mode: .pinnedList
            ),
            .sessionList
        )
    }

    func testSessionListBubbleHeightConstantAcrossSessionCount() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        AppSettings.maxPanelHeight = 600
        defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
        let viewModel = makeViewModel()
        let single = [makeSession(id: "active-1", phase: .processing)]
        let many = [
            makeSession(id: "active-1", phase: .processing),
            makeSession(id: "active-2", phase: .processing),
            makeSession(id: "attention", phase: .waitingForInput, intervention: makeIntervention(id: "q-1", kind: .question, message: "Need your answer")),
            makeSession(id: "idle-1", phase: .idle),
            makeSession(id: "ended-1", phase: .ended)
        ]

        // T20：完整面板高度恒等于用户上限，不随会话数伸缩
        let singleHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: single,
            viewModel: viewModel
        ).height
        let manyHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: many,
            viewModel: viewModel
        ).height

        XCTAssertEqual(singleHeight, 600, accuracy: 0.5)
        XCTAssertEqual(manyHeight, 600, accuracy: 0.5)
        XCTAssertEqual(singleHeight, manyHeight, accuracy: 0.01)
    }

    func testSessionListBubbleHeightIgnoresRowDensityMix() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        AppSettings.maxPanelHeight = 600
        defer { AppSettings.maxPanelHeight = originalMaxPanelHeight }
        let viewModel = makeViewModel()
        let activeOnly = [
            makeSession(id: "active-1", phase: .processing),
            makeSession(id: "active-2", phase: .processing),
            makeSession(id: "active-3", phase: .processing)
        ]
        let mixed = [
            makeSession(id: "active-1", phase: .processing),
            makeSession(id: "idle-1", phase: .idle),
            makeSession(id: "ended-1", phase: .ended)
        ]

        // T20：行密度组合（活跃/空闲/结束）不再影响面板总高
        let activeOnlyHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: activeOnly,
            viewModel: viewModel
        ).height
        let mixedHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: mixed,
            viewModel: viewModel
        ).height

        XCTAssertEqual(activeOnlyHeight, 600, accuracy: 0.5)
        XCTAssertEqual(mixedHeight, 600, accuracy: 0.5)
        XCTAssertEqual(mixedHeight, activeOnlyHeight, accuracy: 0.01)
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: 完整面板恒定高度（Task 15 动态高度 → Task 20 翻转）
    //
    // 消费链锚点：宠物点击 → pinnedList → route .sessionList →
    // DetachedIslandContentModel.layout → bubbleContentSize(.sessionList) →
    // bubbleFrame → 气泡 .frame(height:)。
    // T20 定案：点击展开的完整面板高度恒等于 maximumOpenedHeight
    // （= min(屏高-120, maxPanelHeight)），内容多少只影响列表内部
    // 滚动——不再按行数解析式自适应。测试锁住「恒定值 → bubbleFrame」
    // 整条链（T13 教训：公式修了视图不接等于没修）。
    // ═══════════════════════════════════════════════════════════════════

    /// 完整面板高度必须恒等于用户上限（maxPanelHeight 生效于所有行数档）：
    /// 0 行 / 3 行 / 15 行全部钉在 maxPanelHeight（如 600），
    /// 而不是被 screenRect.height - 160（如 740）或内容估算放行。
    func testSessionListBubbleHeightPinnedToMaximumOpenedHeight() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        AppSettings.maxPanelHeight = 600
        AppSettings.compactSessionList = true
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
        }
        let viewModel = makeViewModel()

        // 0 行（原最小可用高 96）也必须直接展开到上限；
        // 0..<rowCount 写法保证 0 行时得到空会话数组（1...0 会 trap）
        let heights = [0, 3, 15].map { rowCount -> CGFloat in
            let sessions = (0..<rowCount).map {
                makeSession(id: "active-\($0 + 1)", phase: .processing)
            }
            return DetachedIslandContentModel.bubbleContentSize(
                for: .sessionList,
                sessions: sessions,
                viewModel: viewModel
            ).height
        }

        XCTAssertEqual(heights[0], 600, accuracy: 0.5)
        XCTAssertEqual(heights[1], 600, accuracy: 0.5)
        XCTAssertEqual(heights[2], 600, accuracy: 0.5)
    }

    /// 内容需求低于上限时，面板高度也恒为上限（不再按解析式收缩）。
    func testSessionListBubbleHeightIgnoresContentBelowCap() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        AppSettings.maxPanelHeight = 600
        AppSettings.compactSessionList = true
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
        }
        let viewModel = makeViewModel()
        let sessions = (1...3).map { makeSession(id: "active-\($0)", phase: .processing) }

        let height = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel
        ).height

        XCTAssertEqual(height, 600, accuracy: 0.5)
    }

    /// 面板高度不再随 compactSessionList 切换（密度只管行内排版）。
    func testSessionListBubbleHeightIgnoresCompactDensity() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        let originalContentFontSize = AppSettings.contentFontSize
        AppSettings.maxPanelHeight = 600
        AppSettings.contentFontSize = 13
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
            AppSettings.contentFontSize = originalContentFontSize
        }
        let viewModel = makeViewModel()
        let sessions = (1...3).map { makeSession(id: "active-\($0)", phase: .processing) }

        AppSettings.compactSessionList = true
        let compactHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel
        ).height
        AppSettings.compactSessionList = false
        let relaxedHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel
        ).height

        XCTAssertEqual(compactHeight, 600, accuracy: 0.5)
        XCTAssertEqual(relaxedHeight, 600, accuracy: 0.5)
        XCTAssertEqual(compactHeight, relaxedHeight, accuracy: 0.01)
    }

    /// usage footer 不再叠加面板总高（恒定高度内消化）。
    func testSessionListBubbleHeightIgnoresUsageFooter() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        AppSettings.maxPanelHeight = 600
        AppSettings.compactSessionList = true
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
        }
        let viewModel = makeViewModel()
        let sessions = (1...3).map { makeSession(id: "active-\($0)", phase: .processing) }

        let withoutFooter = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel
        ).height
        let withFooter = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel,
            additionalFooterHeight: DetachedIslandPanelMetrics.usageFooterReservedHeight
        ).height

        XCTAssertEqual(withoutFooter, 600, accuracy: 0.5)
        XCTAssertEqual(withFooter, 600, accuracy: 0.5)
    }

    /// 视图消费链：layout 产出的 bubbleFrame 必须原样承载
    /// bubbleContentSize(.sessionList) 的高度（含 maxPanelHeight 上限）。
    /// 这是「公式 → 窗口布局」的接线断言，防止公式修了视图不用。
    func testSessionListLayoutBubbleFrameMatchesContentSize() throws {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        AppSettings.maxPanelHeight = 600
        AppSettings.compactSessionList = true
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
        }
        let viewModel = makeViewModel()
        let sessions = (1...15).map { makeSession(id: "active-\($0)", phase: .processing) }

        let contentSize = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: sessions,
            viewModel: viewModel
        )
        let layout = DetachedIslandContentModel.layout(
            for: sessions,
            viewModel: viewModel,
            bubbleState: .pinned,
            bubblePlacement: .topLeft
        )
        let bubbleFrame = try XCTUnwrap(layout.bubbleFrame)

        XCTAssertEqual(bubbleFrame.height, contentSize.height, accuracy: 0.5)
        XCTAssertEqual(bubbleFrame.height, 600, accuracy: 0.5)
    }

    /// 子代理子行不再影响面板总高（Task 17 计入 → Task 20 恒定翻转）：
    /// 1 主行 + 2 挂靠子行与 1 主行同高，均为 maximumOpenedHeight。
    func testSessionListBubbleHeightIgnoresSubagentAttachmentRows() {
        let originalMaxPanelHeight = AppSettings.maxPanelHeight
        let originalCompactList = AppSettings.compactSessionList
        let originalContentFontSize = AppSettings.contentFontSize
        AppSettings.maxPanelHeight = 600
        AppSettings.compactSessionList = true
        AppSettings.contentFontSize = 13
        defer {
            AppSettings.maxPanelHeight = originalMaxPanelHeight
            AppSettings.compactSessionList = originalCompactList
            AppSettings.contentFontSize = originalContentFontSize
        }
        let viewModel = makeViewModel()

        let parent = makeSession(id: "parent", phase: .processing)
        func makeChild(_ id: String) -> SessionState {
            var child = makeSession(id: id, phase: .idle)
            child.codexParentThreadId = "parent"
            return child
        }
        let parentOnly = [parent]
        let withChildren = [parent, makeChild("child-1"), makeChild("child-2")]

        let parentOnlyHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: parentOnly,
            viewModel: viewModel
        ).height
        let withChildrenHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList,
            sessions: withChildren,
            viewModel: viewModel
        ).height

        XCTAssertEqual(parentOnlyHeight, 600, accuracy: 0.5)
        XCTAssertEqual(withChildrenHeight, 600, accuracy: 0.5)
    }

    func testAttentionBubbleUsesMeasuredHeightBeforeFallback() {
        let viewModel = makeViewModel()
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: [
                        "command": AnyCodable("cat very-long-file.txt")
                    ],
                    receivedAt: Date()
                )
            )
        )

        let measuredHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .attentionNotification(attention),
            sessions: [attention],
            viewModel: viewModel,
            measuredAttentionBubbleHeight: 420
        ).height
        let cappedHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .attentionNotification(attention),
            sessions: [attention],
            viewModel: viewModel,
            measuredAttentionBubbleHeight: 1_200
        ).height

        XCTAssertEqual(measuredHeight, 420, accuracy: 0.5)
        XCTAssertEqual(cappedHeight, 740, accuracy: 0.5)
    }

    func testCompletionBubbleUsesMeasuredHeightBeforeFallback() {
        let viewModel = makeViewModel()
        let notification = SessionCompletionNotification(
            session: makeCompletedSession(id: "done"),
            kind: .completed
        )

        let fallbackHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .completionNotification(notification),
            sessions: [notification.session],
            viewModel: viewModel
        ).height
        let measuredHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .completionNotification(notification),
            sessions: [notification.session],
            viewModel: viewModel,
            measuredCompletionBubbleHeight: 190
        ).height
        let minimumHeight = DetachedIslandContentModel.bubbleContentSize(
            for: .completionNotification(notification),
            sessions: [notification.session],
            viewModel: viewModel,
            measuredCompletionBubbleHeight: 100
        ).height

        XCTAssertEqual(
            fallbackHeight,
            DetachedIslandPanelMetrics.completionBubbleFallbackHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(measuredHeight, 190, accuracy: 0.5)
        XCTAssertEqual(
            minimumHeight,
            DetachedIslandPanelMetrics.completionBubbleMinimumHeight,
            accuracy: 0.5
        )
        XCTAssertLessThan(fallbackHeight, 260)
    }

    func testNewAttentionAutoOpensHoverBubble() {
        let attention = makeSession(
            id: "attention",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )
        var tracker = SessionManualAttentionTracker()
        let interactionModel = DetachedIslandInteractionModel()

        let target = tracker.consumeNewAttentionSession(from: [attention])
        interactionModel.presentHoverPreview(canPresentBubble: target != nil)

        XCTAssertEqual(target, attention)
        XCTAssertEqual(interactionModel.bubbleContentMode, .hoverPreview)
    }

    func testPresentAutoOpensAttentionBubbleForExistingNotification() {
        let viewModel = makeViewModel()
        let attention = makeSession(
            id: "attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [attention]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))

        let bubblePresented = expectation(description: "existing attention bubble auto-opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)
            XCTAssertEqual(controller.currentExpandedRoute, .attentionNotification(attention))
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)
    }

    func testSilentPresentPrimesExistingAttentionWithoutOpeningBubble() {
        let viewModel = makeViewModel()
        let attention = makeSession(
            id: "attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [attention]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(
            atPetAnchor: CGPoint(x: 1200, y: 220),
            activatesApplication: false,
            presentsAutomaticContent: false
        )
        controller.applySessionSnapshotForTesting([attention])

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
        XCTAssertFalse(controller.isBubbleVisibleForTesting)

        let freshAttention = makeSession(
            id: "fresh-attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-2",
                kind: .question,
                message: "Need a new answer"
            )
        )
        controller.applySessionSnapshotForTesting([attention, freshAttention])

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)
        XCTAssertEqual(controller.currentExpandedRoute, .attentionNotification(freshAttention))
    }

    func testNewAttentionSessionAutoOpensBubbleInFloatingMode() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))

        let attention = makeSession(
            id: "attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        controller.applySessionSnapshotForTesting([attention, makeSession(id: "active", phase: .processing)])

        let bubblePresented = expectation(description: "new attention bubble auto-opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)
            XCTAssertEqual(controller.currentExpandedRoute, .attentionNotification(attention))
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)
    }

    func testSuppressedAttentionDoesNotOpenOrReplayButExplicitHoverStillWorks() {
        let sessionMonitor = makeSessionMonitor()
        let suppressAutoOpen = CurrentValueSubject<Bool, Never>(true)
        let controller = DetachedIslandWindowController(
            viewModel: makeViewModel(),
            sessionMonitor: sessionMonitor,
            onClose: {},
            shouldSuppressAttentionAutoOpen: { suppressAutoOpen.value }
        )
        defer { controller.dismiss() }

        let attention = makeSession(
            id: "suppressed-attention",
            phase: .waitingForInput,
            intervention: makeIntervention(id: "question-1", kind: .question, message: "Need your answer")
        )
        controller.applySessionSnapshotForTesting([attention])
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
        XCTAssertFalse(controller.isBubbleVisibleForTesting)

        suppressAutoOpen.send(false)
        controller.applySessionSnapshotForTesting([attention])
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)

        suppressAutoOpen.send(true)
        controller.presentHoverBubbleForTesting()
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)
        XCTAssertEqual(controller.currentExpandedRoute, .attentionNotification(attention))
    }

    func testSuppressedExistingAttentionDoesNotOpenOnFloatingPresentation() {
        let sessionMonitor = makeSessionMonitor()
        let suppressAutoOpen = CurrentValueSubject<Bool, Never>(true)
        sessionMonitor.instances = [makeSession(
            id: "existing-attention",
            phase: .waitingForInput,
            intervention: makeIntervention(id: "question-1", kind: .question, message: "Need your answer")
        )]
        let controller = DetachedIslandWindowController(
            viewModel: makeViewModel(),
            sessionMonitor: sessionMonitor,
            onClose: {},
            shouldSuppressAttentionAutoOpen: { suppressAutoOpen.value }
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220), activatesApplication: false)

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
        XCTAssertFalse(controller.isBubbleVisibleForTesting)

        suppressAutoOpen.send(false)
        controller.applySessionSnapshotForTesting(sessionMonitor.instances)
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
    }

    func testAttentionSuppressionPreservesExplicitClickAndPinnedAttentionHighlight() {
        let sessionMonitor = makeSessionMonitor()
        let attention = makeSession(
            id: "suppressed-attention",
            phase: .waitingForInput,
            intervention: makeIntervention(id: "question-1", kind: .question, message: "Need your answer")
        )
        let controller = DetachedIslandWindowController(
            viewModel: makeViewModel(),
            sessionMonitor: sessionMonitor,
            onClose: {},
            shouldSuppressAttentionAutoOpen: { true }
        )
        defer { controller.dismiss() }

        controller.applySessionSnapshotForTesting([attention])
        controller.simulatePetTapForTesting()
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)
        XCTAssertEqual(controller.currentExpandedRoute, .attentionNotification(attention))

        controller.togglePinnedBubbleForTesting()
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .pinned)

        let nextAttention = makeSession(
            id: "next-attention",
            phase: .waitingForInput,
            intervention: makeIntervention(id: "question-2", kind: .question, message: "Another answer")
        )
        controller.applySessionSnapshotForTesting([nextAttention])
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .pinned)
        XCTAssertEqual(controller.highlightedSessionStableID, nextAttention.stableId)
    }

    func testCompletedSessionAutoOpensCompletionBubbleInFloatingMode() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {},
            shouldSuppressAttentionAutoOpen: { true }
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))

        let completed = makeCompletedSession(id: "completed")
        controller.applySessionSnapshotForTesting([completed])

        let bubblePresented = expectation(description: "completion bubble auto-opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)

            guard let notification = controller.currentActiveCompletionNotificationForTesting else {
                XCTFail("Expected active completion notification")
                bubblePresented.fulfill()
                return
            }

            XCTAssertEqual(notification.session.stableId, completed.stableId)
            XCTAssertEqual(notification.kind, .completed)
            XCTAssertEqual(
                controller.currentExpandedRoute,
                .completionNotification(notification)
            )
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)
    }

    func testHiddenFloatingWindowKeepsCompletionUntilPresented() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let registry = SessionCompletionNotificationRegistry()
        let sessionId = "hidden-completion-\(UUID().uuidString)"
        let activityAt = Date()
        let processing = makeCodexCompletedSession(id: sessionId, phase: .processing, lastActivity: activityAt)
        let completed = makeCodexCompletedSession(id: sessionId, lastActivity: activityAt)
        sessionMonitor.instances = [processing]
        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            completionNotificationRegistry: registry,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.applySessionSnapshotForTesting([completed])
        XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
        XCTAssertEqual(registry.pendingNotifications.count, 1)

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.session.sessionId, sessionId)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    func testCodexCompletionBubbleOpensWhileClaudeSessionIsActive() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let sessionId = "codex-completed-\(UUID().uuidString)"
        let activityAt = Date()
        let activeClaude = makeSession(id: "claude-active", phase: .processing)
        let codexProcessing = makeCodexCompletedSession(
            id: sessionId,
            phase: .processing,
            lastActivity: activityAt
        )
        let codexCompleted = makeCodexCompletedSession(id: sessionId, lastActivity: activityAt)
        sessionMonitor.instances = [activeClaude, codexProcessing]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([activeClaude, codexCompleted])

        let presented = expectation(description: "codex completion appears despite active claude")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.session.sessionId, sessionId)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)
            presented.fulfill()
        }

        wait(for: [presented], timeout: 1.0)

        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, phase: .processing, lastActivity: activityAt)
        ])
        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, lastActivity: activityAt)
        ])

        let notDuplicated = expectation(description: "replayed codex completion is not queued twice")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.session.sessionId, sessionId)
            XCTAssertTrue(controller.pendingCompletionNotificationsForTesting.isEmpty)
            notDuplicated.fulfill()
        }

        wait(for: [notDuplicated], timeout: 1.0)
    }

    func testCodexCompletionBubbleOpensWhileAnotherCodexSessionIsActive() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let completedSessionId = "codex-completed-\(UUID().uuidString)"
        let activeSessionId = "codex-active-\(UUID().uuidString)"
        let activityAt = Date()
        let activeCodex = makeCodexCompletedSession(
            id: activeSessionId,
            phase: .processing,
            lastActivity: activityAt
        )
        let codexProcessing = makeCodexCompletedSession(
            id: completedSessionId,
            phase: .processing,
            lastActivity: activityAt
        )
        let codexCompleted = makeCodexCompletedSession(
            id: completedSessionId,
            lastActivity: activityAt
        )
        sessionMonitor.instances = [activeCodex, codexProcessing]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([activeCodex, codexCompleted])

        let presented = expectation(description: "codex completion appears despite another active codex")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.session.sessionId, completedSessionId)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)
            presented.fulfill()
        }

        wait(for: [presented], timeout: 1.0)
    }

    func testRemoteCodexEmptyStopOpensOnceAndLateReplyDoesNotReplay() throws {
        for phase in [SessionPhase.idle, .processing] {
            for pid in [nil, 4242] as [Int?] {
                try XCTContext.runActivity(named: "phase: \(phase), PID: \(String(describing: pid))") { _ in
                    try assertRemoteCodexEmptyStopOpensOnce(initialPhase: phase, hookPID: pid)
                }
            }
        }
    }

    private func assertRemoteCodexEmptyStopOpensOnce(
        initialPhase: SessionPhase,
        hookPID: Int? = nil
    ) throws {
        let sessionId = "remote-codex-late-reply-\(UUID().uuidString)"
        var initial = makeSession(id: sessionId, phase: initialPhase, clientInfo: .codexCLI())
        initial.provider = .codex
        initial.ingress = .remoteBridge
        initial.pid = initialPhase == .processing ? hookPID : nil

        try withRemoteCodexController(initial: initial) { controller in
            // Discovery snapshots omit the PID carried by real remote hooks.
            var snapshot = initial
            snapshot.pid = nil
            controller.applySessionSnapshotForTesting([snapshot])
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)

            var emptyStop = snapshot
            emptyStop.phase = .idle
            emptyStop.pid = hookPID
            emptyStop.hasRemoteCodexTurnCompletion = true
            controller.applySessionSnapshotForTesting([emptyStop])
            let notification = try XCTUnwrap(controller.currentActiveCompletionNotificationForTesting)
            XCTAssertNil(notification.session.lastMessage)
            XCTAssertEqual(notification.kind, .completed)
            XCTAssertEqual(controller.currentExpandedRoute, .completionNotification(notification))

            var reply = makeCodexCompletedSession(id: sessionId)
            reply.clientInfo = .codexCLI()
            reply.ingress = .remoteBridge
            reply.pid = hookPID.map { $0 + 1 }
            reply.hasRemoteCodexTurnCompletion = true
            var replay = reply
            replay.pid = nil
            controller.applySessionSnapshotForTesting([replay])
            XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.id, notification.id)
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting?.session.lastMessage)
            XCTAssertTrue(controller.pendingCompletionNotificationsForTesting.isEmpty)

            controller.applySessionSnapshotForTesting([reply])
            XCTAssertEqual(controller.currentActiveCompletionNotificationForTesting?.id, notification.id)
            let dismissed = expectation(description: "late reply notification dismisses without replay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
                controller.applySessionSnapshotForTesting([reply])
                XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
                XCTAssertTrue(controller.pendingCompletionNotificationsForTesting.isEmpty)
                dismissed.fulfill()
            }
            wait(for: [dismissed], timeout: 1.0)
        }
    }

    func testSuppressedRemoteCodexLateReplyDoesNotReplayAfterUnmuting() {
        let cases: [(pid: Int?, disconnect: Bool)] = [(nil, false), (4242, false), (4242, true)]
        for phase in [SessionPhase.idle, .processing] {
            for (pid, disconnect) in cases {
                XCTContext.runActivity(named: "phase: \(phase), PID: \(String(describing: pid)), disconnect: \(disconnect)") { _ in
                    assertSuppressedRemoteCodexStopDoesNotReplay(
                        initialPhase: phase, hookPID: pid, disconnectBeforeUnmuting: disconnect
                    )
                }
            }
        }
    }

    private func assertSuppressedRemoteCodexStopDoesNotReplay(
        initialPhase: SessionPhase,
        hookPID: Int? = nil,
        disconnectBeforeUnmuting: Bool = false
    ) {
        let originalMuteUntil = AppSettings.temporarilyMuteNotificationsUntil
        AppSettings.muteReminderNotifications(for: 60)
        defer { AppSettings.temporarilyMuteNotificationsUntil = originalMuteUntil }

        let sessionId = "remote-codex-suppressed-late-reply-\(UUID().uuidString)"
        var initial = makeSession(id: sessionId, phase: initialPhase, clientInfo: .codexCLI())
        initial.provider = .codex
        initial.ingress = .remoteBridge

        withRemoteCodexController(initial: initial) { controller in
            var emptyStop = initial
            emptyStop.phase = .idle
            emptyStop.pid = hookPID
            emptyStop.hasRemoteCodexTurnCompletion = true
            controller.applySessionSnapshotForTesting([emptyStop])
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)

            var reply = makeCodexCompletedSession(id: sessionId)
            reply.clientInfo = .codexCLI()
            reply.ingress = .remoteBridge
            reply.pid = hookPID.map { $0 + 1 }
            reply.hasRemoteCodexTurnCompletion = true
            controller.applySessionSnapshotForTesting([reply])
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)

            var replay = reply
            replay.pid = nil
            controller.applySessionSnapshotForTesting([replay])

            if disconnectBeforeUnmuting {
                replay.connectionState = .disconnected
                controller.applySessionSnapshotForTesting([replay])
                XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(replay))
                XCTAssertNil(SessionCompletionKey.make(for: replay))
                XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            }

            AppSettings.clearReminderNotificationMute()
            XCTAssertFalse(AppSettings.areReminderNotificationsSuppressed)
            controller.applySessionSnapshotForTesting([reply])
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            XCTAssertTrue(controller.pendingCompletionNotificationsForTesting.isEmpty)

            if disconnectBeforeUnmuting {
                // The next turn must still notify after the skipped turn reconnects.
                var next = reply
                next.phase = .processing
                next.hasRemoteCodexTurnCompletion = false
                next.completionSequence += 1
                controller.applySessionSnapshotForTesting([next])
                next.phase = .idle
                next.hasRemoteCodexTurnCompletion = true
                controller.applySessionSnapshotForTesting([next])
                XCTAssertEqual(
                    controller.currentActiveCompletionNotificationForTesting?.identity,
                    SessionCompletionNotification(session: next, kind: .completed).identity
                )
            }
        }
    }

    func testPresentDoesNotReplayExistingRemoteCodexCompletion() {
        for state in [SessionConnectionState.connected, .disconnected] {
            XCTContext.runActivity(named: "initial connection: \(state)") { _ in
                assertPresentDoesNotReplayRemoteCodexCompletion(connectionState: state)
            }
        }
    }

    private func assertPresentDoesNotReplayRemoteCodexCompletion(connectionState: SessionConnectionState) {
        var completed = makeCodexCompletedSession(id: "remote-codex-existing-\(UUID().uuidString)")
        completed.ingress = .remoteBridge
        completed.connectionState = connectionState
        completed.hasRemoteCodexTurnCompletion = true
        withRemoteCodexController(initial: completed) { controller in
            for (pid, state) in [
                (nil, SessionConnectionState.connected), (4242, .disconnected),
                (nil, .connected), (4243, .connected)
            ] as [(Int?, SessionConnectionState)] {
                completed.pid = pid
                completed.connectionState = state
                controller.applySessionSnapshotForTesting([completed])

                XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
                XCTAssertTrue(controller.pendingCompletionNotificationsForTesting.isEmpty)
            }
        }
    }

    private func withRemoteCodexController(
        initial: SessionState,
        _ body: (DetachedIslandWindowController) throws -> Void
    ) rethrows {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [initial]
        // Keep actor-owned dependencies alive through AppKit autorelease pools;
        // release them from asynchronous teardown with a Swift task context.
        let registry = SessionCompletionNotificationRegistry()
        completionRegistries.append(registry)
        let controller = DetachedIslandWindowController(
            viewModel: makeViewModel(),
            sessionMonitor: sessionMonitor,
            completionNotificationRegistry: registry,
            onClose: {}
        )
        controller.completionNotificationDismissDelay = 0.1
        defer { controller.dismiss() }
        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        try body(controller)
    }

    func testDismissedCodexCompletionDoesNotReopenAfterThreadRefresh() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let sessionId = "codex-completed-\(UUID().uuidString)"
        let activityAt = Date()
        let codexCompleted = makeCodexCompletedSession(id: sessionId, lastActivity: activityAt)
        sessionMonitor.instances = [
            makeCodexCompletedSession(id: sessionId, phase: .processing, lastActivity: activityAt)
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        controller.completionNotificationDismissDelay = 0.2
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([codexCompleted])

        let bubblePresented = expectation(description: "codex completion bubble auto-opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNotNil(controller.currentActiveCompletionNotificationForTesting)
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)

        let bubbleDismissed = expectation(description: "codex completion bubble auto-dismisses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 1.0)

        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, phase: .processing, lastActivity: activityAt)
        ])
        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, lastActivity: activityAt)
        ])

        XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
        waitForBubbleHidden(controller)
    }

    func testDismissedCodexCompletionCanOpenForLaterActivity() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let sessionId = "codex-completed-\(UUID().uuidString)"
        let firstActivityAt = Date()
        let laterActivityAt = firstActivityAt.addingTimeInterval(5)
        sessionMonitor.instances = [
            makeCodexCompletedSession(
                id: sessionId,
                phase: .processing,
                lastActivity: firstActivityAt,
                turnId: "turn-1"
            )
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        controller.completionNotificationDismissDelay = 0.2
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, lastActivity: firstActivityAt, turnId: "turn-1")
        ])

        let firstBubblePresented = expectation(description: "first codex completion opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNotNil(controller.currentActiveCompletionNotificationForTesting)
            firstBubblePresented.fulfill()
        }

        wait(for: [firstBubblePresented], timeout: 1.0)

        let firstBubbleDismissed = expectation(description: "first codex completion dismisses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            firstBubbleDismissed.fulfill()
        }

        wait(for: [firstBubbleDismissed], timeout: 1.0)

        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(
                id: sessionId,
                phase: .processing,
                lastActivity: laterActivityAt,
                turnId: "turn-2"
            )
        ])
        controller.applySessionSnapshotForTesting([
            makeCodexCompletedSession(id: sessionId, lastActivity: laterActivityAt, turnId: "turn-2")
        ])

        let laterBubblePresented = expectation(description: "later codex completion opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let notification = controller.currentActiveCompletionNotificationForTesting else {
                XCTFail("Expected later completion notification")
                laterBubblePresented.fulfill()
                return
            }

            XCTAssertEqual(notification.session.sessionId, sessionId)
            XCTAssertEqual(notification.session.lastActivity, laterActivityAt)
            laterBubblePresented.fulfill()
        }

        wait(for: [laterBubblePresented], timeout: 1.0)
    }

    func testQoderCLIEndedSessionAutoOpensCompletionBubbleAfterWaitingForInput() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = true
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let qoderCLIClientInfo = makeQoderCLIClientInfo()
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [
            makeSession(
                id: "qoder-cli",
                phase: .waitingForInput,
                clientInfo: qoderCLIClientInfo
            )
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([
            makeSession(
                id: "qoder-cli",
                phase: .ended,
                clientInfo: qoderCLIClientInfo,
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: "Qoder finished",
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: "Do it",
                    lastUserMessageDate: Date()
                )
            )
        ])

        let bubblePresented = expectation(description: "qoder cli ended bubble auto-opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)

            guard let notification = controller.currentActiveCompletionNotificationForTesting else {
                XCTFail("Expected active completion notification")
                bubblePresented.fulfill()
                return
            }

            XCTAssertEqual(notification.session.stableId, "qoder-cli")
            XCTAssertEqual(notification.kind, .ended)
            XCTAssertEqual(
                controller.currentExpandedRoute,
                .completionNotification(notification)
            )
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)
    }

    func testCompletionBubbleAutoDismissesEvenWhileHoveredInFloatingMode() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        let completed = makeCompletedSession(id: "completed")
        sessionMonitor.instances = [completed]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        controller.completionNotificationDismissDelay = 1.0
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.presentCompletionNotificationForTesting(
            SessionCompletionNotification(session: completed, kind: .completed)
        )

        let bubblePresented = expectation(description: "completion bubble becomes active")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNotNil(controller.currentActiveCompletionNotificationForTesting)
            controller.simulateCompletionNotificationHoverForTesting(true)
            bubblePresented.fulfill()
        }

        wait(for: [bubblePresented], timeout: 1.0)

        let bubbleDismissed = expectation(description: "completion bubble auto-dismisses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 2.0)
    }

    func testDisablingCompletionNotificationsPreventsFloatingCompletionBubble() {
        let originalAutoOpenCompletionPanel = AppSettings.autoOpenCompletionPanel
        AppSettings.autoOpenCompletionPanel = false
        defer { AppSettings.autoOpenCompletionPanel = originalAutoOpenCompletionPanel }

        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.applySessionSnapshotForTesting([makeCompletedSession(id: "completed")])

        let noBubble = expectation(description: "completion bubble stays hidden")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNil(controller.currentActiveCompletionNotificationForTesting)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            noBubble.fulfill()
        }

        wait(for: [noBubble], timeout: 1.0)
    }

    func testDismissAttentionBubbleHidesHoverPreview() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.presentHoverBubbleForTesting()

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)

        controller.dismissAttentionBubble()

        let bubbleDismissed = expectation(description: "attention bubble fully dismisses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 1.0)
    }

    func testClickedBubbleAutoHidesWhenNotHoveredWithinGraceDelay() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        controller.bubbleHoverGraceDelay = 0.1
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.simulatePetTapForTesting()

        let bubbleDismissed = expectation(description: "clicked bubble auto hides")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 1.0)
    }

    func testClickedBubbleStaysVisibleAfterBubbleHover() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        controller.bubbleHoverGraceDelay = 0.1
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.simulatePetTapForTesting()
        controller.simulateBubbleHoverForTesting(true)

        let bubbleRemainsVisible = expectation(description: "hover cancels auto hide")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
            XCTAssertTrue(controller.isBubbleVisibleForTesting)
            bubbleRemainsVisible.fulfill()
        }

        wait(for: [bubbleRemainsVisible], timeout: 1.0)
    }

    func testOutsideBubbleClickHidesPinnedBubble() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.togglePinnedBubbleForTesting()

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .pinned)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)

        controller.simulateOutsideBubbleClickForTesting(screenLocation: CGPoint(x: 32, y: 32))

        let bubbleDismissed = expectation(description: "outside click hides pinned bubble")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 1.0)
    }

    func testOutsideBubbleClickHidesHoverPreviewBubble() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [makeSession(id: "active", phase: .processing)]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1200, y: 220))
        controller.presentHoverBubbleForTesting()

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)

        controller.simulateOutsideBubbleClickForTesting(screenLocation: CGPoint(x: 32, y: 32))

        let bubbleDismissed = expectation(description: "outside click hides hover bubble")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(controller.renderedBubbleStateForTesting, .hidden)
            XCTAssertFalse(controller.isBubbleVisibleForTesting)
            bubbleDismissed.fulfill()
        }

        wait(for: [bubbleDismissed], timeout: 1.0)
    }

    func testPinnedBubbleKeepsSessionListAndHighlightStateSeparateFromRoute() {
        let active = makeSession(id: "active", phase: .processing)
        let attention = makeSession(
            id: "attention",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )
        var tracker = SessionManualAttentionTracker()
        let interactionModel = DetachedIslandInteractionModel()
        let bubbleViewState = DetachedIslandBubbleViewState()
        let viewModel = makeViewModel()

        interactionModel.togglePinned(canPresentBubble: true)
        _ = tracker.consumeNewAttentionSession(from: [active])
        let target = tracker.consumeNewAttentionSession(from: [active, attention])
        bubbleViewState.highlightedSessionStableID = target?.stableId

        XCTAssertEqual(interactionModel.bubbleContentMode, .pinnedList)
        XCTAssertEqual(
            DetachedIslandContentModel.route(
                for: [active, attention],
                viewModel: viewModel,
                mode: .pinnedList
            ),
            .sessionList
        )
        XCTAssertEqual(bubbleViewState.highlightedSessionStableID, attention.stableId)
    }

    func testWindowOriginPreservesPetAnchorWhenBubbleExpandsRight() {
        let hiddenLayout = DetachedIslandWindowLayout(
            containerSize: CGSize(width: 92, height: 92),
            petFrame: CGRect(x: 0, y: 0, width: 92, height: 92),
            bubbleFrame: nil,
            bubblePlacement: .topRight,
            petAnchorInWindow: CGPoint(x: 46, y: 46),
            bubbleContentMode: nil
        )
        let hiddenFrame = NSRect(origin: CGPoint(x: 220, y: 420), size: hiddenLayout.containerSize)
        let anchor = DetachedIslandWindowController.petAnchorScreenPoint(for: hiddenFrame, layout: hiddenLayout)

        let expandedLayout = DetachedIslandWindowLayout(
            containerSize: CGSize(width: 464, height: 164),
            petFrame: CGRect(x: 0, y: 36, width: 92, height: 92),
            bubbleFrame: CGRect(x: 104, y: 12, width: 360, height: 140),
            bubblePlacement: .topRight,
            petAnchorInWindow: CGPoint(x: 46, y: 82),
            bubbleContentMode: .hoverPreview
        )

        let expandedOrigin = DetachedIslandWindowController.windowOrigin(
            preservingPetAnchorAt: anchor,
            layout: expandedLayout
        )
        let expandedFrame = NSRect(origin: expandedOrigin, size: expandedLayout.containerSize)

        XCTAssertEqual(
            DetachedIslandWindowController.petAnchorScreenPoint(
                for: expandedFrame,
                layout: expandedLayout
            ).x,
            anchor.x,
            accuracy: 0.5
        )
        XCTAssertEqual(
            DetachedIslandWindowController.petAnchorScreenPoint(
                for: expandedFrame,
                layout: expandedLayout
            ).y,
            anchor.y,
            accuracy: 0.5
        )
    }

    func testWindowOriginPreservesPetAnchorWhenBubbleExpandsLeft() {
        let hiddenLayout = DetachedIslandWindowLayout(
            containerSize: CGSize(width: 92, height: 92),
            petFrame: CGRect(x: 0, y: 0, width: 92, height: 92),
            bubbleFrame: nil,
            bubblePlacement: .bottomLeft,
            petAnchorInWindow: CGPoint(x: 46, y: 46),
            bubbleContentMode: nil
        )
        let hiddenFrame = NSRect(origin: CGPoint(x: 980, y: 420), size: hiddenLayout.containerSize)
        let anchor = DetachedIslandWindowController.petAnchorScreenPoint(for: hiddenFrame, layout: hiddenLayout)

        let expandedLayout = DetachedIslandWindowLayout(
            containerSize: CGSize(width: 464, height: 164),
            petFrame: CGRect(x: 372, y: 0, width: 92, height: 92),
            bubbleFrame: CGRect(x: 0, y: 24, width: 360, height: 140),
            bubblePlacement: .bottomLeft,
            petAnchorInWindow: CGPoint(x: 418, y: 46),
            bubbleContentMode: .hoverPreview
        )

        let expandedOrigin = DetachedIslandWindowController.windowOrigin(
            preservingPetAnchorAt: anchor,
            layout: expandedLayout
        )
        let expandedFrame = NSRect(origin: expandedOrigin, size: expandedLayout.containerSize)

        XCTAssertEqual(
            DetachedIslandWindowController.petAnchorScreenPoint(
                for: expandedFrame,
                layout: expandedLayout
            ).x,
            anchor.x,
            accuracy: 0.5
        )
        XCTAssertEqual(
            DetachedIslandWindowController.petAnchorScreenPoint(
                for: expandedFrame,
                layout: expandedLayout
            ).y,
            anchor.y,
            accuracy: 0.5
        )
    }

    func testConversationPreviewBuilderPrefersInterventionSummaryForAttentionSessions() {
        let session = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Edit",
                    toolInput: nil,
                    receivedAt: Date()
                )
            ),
            intervention: makeIntervention(
                id: "approval-1",
                kind: .approval,
                message: "Allow editing config?"
            ),
            chatItems: [
                ChatHistoryItem(id: "user-1", type: .user("Do it"), timestamp: Date()),
                ChatHistoryItem(id: "assistant-1", type: .assistant("Working"), timestamp: Date())
            ]
        )

        XCTAssertEqual(
            SessionConversationPreviewBuilder.attentionSummary(for: session),
            "Allow editing config?"
        )
    }

    func testConversationPreviewBuilderFallsBackToConversationLastMessage() {
        let session = makeSession(
            id: "fallback",
            phase: .ended,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Final answer",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(
            SessionConversationPreviewBuilder.fallbackPreview(for: session),
            "Final answer"
        )
    }

    func testBubbleHideFadesBeforeCollapsingRenderedLayout() {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [
            makeSession(id: "active", phase: .processing)
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.presentHoverBubbleForTesting()
        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertTrue(controller.isBubbleVisibleForTesting)

        controller.hideBubbleForTesting()

        XCTAssertEqual(controller.renderedBubbleStateForTesting, .hoverPreview)
        XCTAssertFalse(controller.isBubbleVisibleForTesting)

        waitForBubbleHidden(controller)
    }

    func testBubbleHideCollapsePreservesPetAnchorAfterFade() throws {
        let viewModel = makeViewModel()
        let sessionMonitor = makeSessionMonitor()
        sessionMonitor.instances = [
            makeSession(id: "active", phase: .processing)
        ]

        let controller = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: {}
        )
        defer { controller.dismiss() }

        controller.present(atPetAnchor: CGPoint(x: 1260, y: 180))
        controller.presentHoverBubbleForTesting()

        let expandedAnchor = try XCTUnwrap(controller.currentPetAnchor)
        controller.hideBubbleForTesting()
        waitForBubbleHidden(controller)
        let collapsedAnchor = try XCTUnwrap(controller.currentPetAnchor)

        XCTAssertEqual(collapsedAnchor.x, expandedAnchor.x, accuracy: 0.5)
        XCTAssertEqual(collapsedAnchor.y, expandedAnchor.y, accuracy: 0.5)
    }

    private func waitForBubbleHidden(
        _ controller: DetachedIslandWindowController,
        timeout: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bubbleDismissed = expectation(description: "bubble fade completes before layout collapse")
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if controller.renderedBubbleStateForTesting == .hidden,
               controller.isBubbleVisibleForTesting == false {
                bubbleDismissed.fulfill()
                return
            }

            guard Date() < deadline else {
                XCTFail(
                    "Expected bubble to become hidden; got state=\(controller.renderedBubbleStateForTesting), visible=\(controller.isBubbleVisibleForTesting)",
                    file: file,
                    line: line
                )
                bubbleDismissed.fulfill()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                poll()
            }
        }

        poll()
        wait(for: [bubbleDismissed], timeout: timeout + 0.25)
    }

    private func makeViewModel(
        screenRect: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: screenRect,
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )
    }

    private func makeSessionMonitor() -> SessionMonitor {
        SessionMonitor(observeSharedState: false)
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil,
        clientInfo: SessionClientInfo? = nil,
        chatItems: [ChatHistoryItem] = [],
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: nil,
            lastUserMessageDate: nil
        )
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            clientInfo: clientInfo,
            intervention: intervention,
            phase: phase,
            chatItems: chatItems,
            conversationInfo: conversationInfo
        )
    }

    private func makeCompletedSession(id: String) -> SessionState {
        makeSession(
            id: id,
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "\(id)-user", type: .user("Do it"), timestamp: Date()),
                ChatHistoryItem(id: "\(id)-assistant", type: .assistant("All done"), timestamp: Date())
            ],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "All done",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do it",
                lastUserMessageDate: Date()
            )
        )
    }

    private func makeCodexCompletedSession(
        id: String,
        phase: SessionPhase = .idle,
        lastActivity: Date = Date(),
        turnId: String? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: id),
            phase: phase,
            chatItems: [
                ChatHistoryItem(
                    id: "\(id)-user",
                    type: .user("Do it"),
                    timestamp: lastActivity.addingTimeInterval(-5)
                ),
                ChatHistoryItem(
                    id: "\(id)-assistant",
                    type: .assistant("All done"),
                    timestamp: lastActivity
                )
            ],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "All done",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do it",
                lastUserMessageDate: lastActivity.addingTimeInterval(-5)
            ),
            latestTurnId: turnId,
            lastActivity: lastActivity,
            createdAt: lastActivity.addingTimeInterval(-10)
        )
    }

    private func makeQoderCLIClientInfo() -> SessionClientInfo {
        SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cli",
            name: "Qoder CLI",
            origin: "cli"
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
