import AppKit
import SwiftUI
import XCTest
@testable import Ping_Island

@MainActor
final class IslandTextFieldTests: XCTestCase {
    func testTextFieldAcceptsFirstMouseForInactivePanelClicks() {
        let textField = IslandNSTextField()

        XCTAssertTrue(textField.acceptsFirstMouse(for: nil))
    }

    func testTextFieldUsesVisibleTextAndPlaceholderColors() {
        let textField = IslandNSTextField()
        textField.placeholderString = "Type Something ..."

        textField.configureTextAppearance()

        XCTAssertEqual(textField.textColor, NSColor.white)
        XCTAssertEqual(
            textField.placeholderAttributedString?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.white.withAlphaComponent(0.38)
        )
    }

    func testEditableTextFieldKeepsFirstResponderDuringTransientFocusMismatch() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = IslandNSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        let parent = IslandTextField(
            placeholder: "Answer",
            text: .constant(""),
            isFocused: false,
            isEditable: true
        )
        let coordinator = IslandTextField.Coordinator(parent: parent)
        textField.delegate = coordinator
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(textField)
        defer { window.orderOut(nil) }

        coordinator.focus(textField)
        XCTAssertTrue(isEditing(textField, in: window))

        coordinator.syncFocus(for: textField)

        XCTAssertTrue(isEditing(textField, in: window))
    }

    func testMarkedTextChangeStaysLocalUntilCompositionCommits() throws {
        var publishedText = ""
        let (window, textField, coordinator) = makeFocusedTextField(
            text: Binding(
                get: { publishedText },
                set: { publishedText = $0 }
            )
        )
        defer { window.orderOut(nil) }

        let editor = try XCTUnwrap(textField.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "ni" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())

        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: textField)
        )

        XCTAssertEqual(publishedText, "")

        editor.unmarkText()
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: textField)
        )

        XCTAssertEqual(publishedText, "ni")
    }

    func testMarkedTextSyncDoesNotOverwriteActiveComposition() throws {
        let (window, textField, coordinator) = makeFocusedTextField(text: .constant(""))
        defer { window.orderOut(nil) }

        let editor = try XCTUnwrap(textField.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "zhong" as NSString,
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())

        coordinator.syncText("", for: textField)

        XCTAssertEqual(editor.string, "zhong")
        XCTAssertTrue(editor.hasMarkedText())
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - T30 同步重聚焦不得激活 App
    //
    // syncFocus 路径（SwiftUI 状态同步）只在窗口已是 key 时恢复第一
    // 响应者，绝不调用 NSApp.activate；mouseDown 路径（用户显式点击）
    // 照常激活。激活用可注入闭包做 spy，焦点断言真实窗口的 firstResponder。
    // ══════════════════════════════════════════════════════════════

    func testSyncFocusRefocusesWithoutActivatingWhenWindowIsKey() {
        var activationCount = 0
        let (window, textField, coordinator) = makeKeyAwareTextField(
            isWindowKey: true,
            activateApplication: { activationCount += 1 }
        )
        defer { window.orderOut(nil) }

        coordinator.syncFocus(for: textField)

        XCTAssertEqual(activationCount, 0, "syncFocus 路径不得激活应用")
        XCTAssertTrue(isEditing(textField, in: window), "窗口已是 key 时应恢复第一响应者")
    }

    func testSyncFocusNeitherActivatesNorRefocusesWhenWindowIsNotKey() {
        var activationCount = 0
        let (window, textField, coordinator) = makeKeyAwareTextField(
            isWindowKey: false,
            activateApplication: { activationCount += 1 }
        )
        defer { window.orderOut(nil) }

        coordinator.syncFocus(for: textField)

        XCTAssertEqual(activationCount, 0, "syncFocus 路径不得激活应用")
        XCTAssertFalse(isEditing(textField, in: window), "窗口不是 key 时不得抢回第一响应者")
    }

    func testSyncFocusUsesRealWindowKeyStateWhenAvailable() throws {
        var activationCount = 0
        let (window, textField, coordinator) = makeKeyAwareTextField(
            isWindowKey: nil,
            activateApplication: { activationCount += 1 }
        )
        defer { window.orderOut(nil) }

        window.makeKey()
        // 无头测试环境拿不到 key 窗口时跳过：不由本测试下结论
        guard window.isKeyWindow else {
            throw XCTSkip("测试宿主无法提供 key 窗口；真实窗口态断言由注入用例覆盖")
        }

        coordinator.syncFocus(for: textField)

        XCTAssertEqual(activationCount, 0, "syncFocus 路径不得激活应用")
        XCTAssertTrue(isEditing(textField, in: window), "真实 key 窗口下应恢复第一响应者")
    }

    func testMouseDownStillActivatesApplicationAndFocuses() async throws {
        var activationCount = 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: IslandTextField(
                placeholder: "Answer",
                text: .constant(""),
                isFocused: false,
                isEditable: true,
                activateApplication: { activationCount += 1 },
                isWindowKey: { _ in false }
            )
            .frame(width: 180, height: 24)
        )
        window.contentView = hostingView
        defer { window.orderOut(nil) }

        // 走真实的 makeNSView 接线：focusHandler 由生产代码绑定
        let textField = try await hostedTextField(in: hostingView)
        XCTAssertEqual(activationCount, 0)

        textField.mouseDown(with: try XCTUnwrap(mouseDownEvent(in: window)))

        XCTAssertEqual(activationCount, 1, "mouseDown 路径仍须激活应用")
        XCTAssertTrue(isEditing(textField, in: window))
    }

    /// 构造带注入闭包的输入框；isWindowKey 传 nil 时用真实窗口 key 状态
    private func makeKeyAwareTextField(
        isWindowKey: Bool?,
        activateApplication: @escaping () -> Void
    ) -> (window: NSWindow, textField: IslandNSTextField, coordinator: IslandTextField.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = IslandNSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        var representable = IslandTextField(
            placeholder: "Answer",
            text: .constant(""),
            isFocused: true,
            isEditable: true,
            activateApplication: activateApplication
        )
        if let isWindowKey {
            representable.isWindowKey = { _ in isWindowKey }
        }
        let coordinator = IslandTextField.Coordinator(parent: representable)
        textField.delegate = coordinator
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(textField)
        return (window, textField, coordinator)
    }

    /// 轮询等待 SwiftUI 把 IslandNSTextField 挂到宿主视图上
    private func hostedTextField(
        in view: NSView,
        timeout: TimeInterval = 2.0
    ) async throws -> IslandNSTextField {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let textField = firstDescendant(of: view, as: IslandNSTextField.self) {
                return textField
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("SwiftUI 未在宿主视图上创建 IslandNSTextField")
        throw XCTSkip("宿主视图未创建输入框")
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(of: subview, as: type) {
                return match
            }
        }
        return nil
    }

    private func mouseDownEvent(in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 60, y: 40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    private func isEditing(_ textField: IslandNSTextField, in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }
        return firstResponder === textField || firstResponder === textField.currentEditor()
    }

    private func makeFocusedTextField(
        text: Binding<String>
    ) -> (window: NSWindow, textField: IslandNSTextField, coordinator: IslandTextField.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = IslandNSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        let parent = IslandTextField(
            placeholder: "Answer",
            text: text,
            isFocused: true,
            isEditable: true
        )
        let coordinator = IslandTextField.Coordinator(parent: parent)
        textField.delegate = coordinator
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(textField)
        coordinator.focus(textField)
        XCTAssertTrue(isEditing(textField, in: window))

        return (window, textField, coordinator)
    }
}
