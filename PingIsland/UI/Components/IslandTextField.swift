import AppKit
import SwiftUI

struct IslandTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var isFocused: Bool
    var isEditable: Bool = true
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    // ── T30：可注入的激活与窗口 key 判定（测试用 spy 替换）──────────
    /// 激活应用：只有 mouseDown 路径（用户显式点击输入框）会调用
    var activateApplication: () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
    }
    /// 宿主窗口是否已是 key：syncFocus 路径据此决定是否恢复第一响应者
    var isWindowKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    func makeNSView(context: Context) -> IslandNSTextField {
        let textField = IslandNSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit(_:))
        textField.configureTextAppearance()
        textField.focusHandler = { [weak textField, weak coordinator = context.coordinator] in
            guard let textField else { return }
            coordinator?.focus(textField)
        }
        return textField
    }

    func updateNSView(_ textField: IslandNSTextField, context: Context) {
        context.coordinator.parent = self

        context.coordinator.syncText(text, for: textField)

        textField.placeholderString = placeholder
        textField.isEditable = isEditable
        textField.isEnabled = isEditable
        textField.configureTextAppearance()

        DispatchQueue.main.async {
            context.coordinator.syncFocus(for: textField)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IslandTextField

        init(parent: IslandTextField) {
            self.parent = parent
        }

        func syncText(_ text: String, for textField: IslandNSTextField) {
            guard !textField.hasActiveMarkedText else { return }
            if textField.stringValue != text {
                textField.stringValue = text
            }
        }

        func syncFocus(for textField: IslandNSTextField) {
            let hasFocus = hasFocus(textField)
            if parent.isFocused {
                if hasFocus {
                    textField.configureEditorAppearance()
                } else if let window = textField.window, parent.isWindowKey(window) {
                    // ── T30：同步重聚焦只在窗口已是 key 时进行 ──────────
                    // 以前这里无条件 NSApp.activate：用户切到别的 App 后，
                    // 只要会话状态一变（洪峰期每秒数百次）就把键盘焦点抢回来。
                    focus(textField, allowsActivation: false)
                }
            } else if hasFocus && !parent.isEditable {
                textField.window?.makeFirstResponder(nil)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? IslandNSTextField else { return }
            parent.onFocusChanged(true)
            textField.configureTextAppearance()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            guard !textField.hasActiveMarkedText else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                parent.text = textField.stringValue
            }
            parent.onFocusChanged(false)
        }

        @objc func submit(_ sender: NSTextField) {
            guard !sender.hasActiveMarkedText else { return }
            parent.text = sender.stringValue
            parent.onSubmit()
        }

        /// 把输入框设为第一响应者
        ///
        /// - Parameter allowsActivation: 是否允许激活应用并置 key。
        ///   mouseDown 路径（用户显式点击）用默认 true；syncFocus 路径
        ///   （SwiftUI 状态同步）传 false——绝不激活，只在窗口已是
        ///   key 时恢复第一响应者。
        func focus(_ textField: IslandNSTextField, allowsActivation: Bool = true) {
            guard parent.isEditable, let window = textField.window else { return }
            if allowsActivation {
                // ── T30 激活溯源：显式激活调用点打来源标记 ──────────────
                FocusTrace.source("textField.mouseDown.activate")
                parent.activateApplication()
                window.makeKey()
            }
            window.makeFirstResponder(textField)
            textField.configureEditorAppearance()
        }

        private func hasFocus(_ textField: IslandNSTextField) -> Bool {
            guard let firstResponder = textField.window?.firstResponder else { return false }
            return firstResponder === textField || firstResponder === textField.currentEditor()
        }
    }
}

final class IslandNSTextField: NSTextField {
    var focusHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
        configureEditorAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        configureEditorAppearance()
        return didBecomeFirstResponder
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configureTextAppearance() {
        textColor = .white
        placeholderAttributedString = NSAttributedString(
            string: placeholderString ?? "",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: font ?? NSFont.systemFont(ofSize: 13),
            ]
        )
        configureEditorAppearance()
    }

    func configureEditorAppearance() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .controlAccentColor
    }
}

private extension NSTextField {
    var hasActiveMarkedText: Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true
    }
}
