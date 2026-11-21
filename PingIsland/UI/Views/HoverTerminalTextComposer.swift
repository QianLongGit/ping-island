//
//  HoverTerminalTextComposer.swift
//  PingIsland
//
//  悬停卡片终端发送输入行：会话空闲时把单行文本送进宿主终端
//

import Combine
import SwiftUI

// ============================================================
// HoverTerminalTextComposerModel — 发送输入行可测逻辑层
// ------------------------------------------------------------
// 职责边界（与 TerminalTextSender 服务层互补）：
//   - 本层只管 UI 侧规则：输入钳制 / 渲染矩阵 / 发送编排；
//   - 通道选择 / 开关短路 / 远程拒绝全部由服务层裁决
//     （terminalTextSendingEnabled off 时 send 返回 false，
//      本层渲染门是第一道门，服务层短路是最后一道门）。
//
// 安全红线（与 N3 服务层一致，双保险）：
//   1. 换行剥离——发送前取首行，Enter 只能由服务层独立步骤触发；
//   2. 长度上限——500 字符，防误粘贴巨文本撑爆终端输入缓冲；
//   3. 空白不发——纯空格 / 纯换行草稿不触达 sender；
//   4. 防重入——发送中忽略再次提交，绝不重复投递。
// ============================================================

@MainActor
final class HoverTerminalTextComposerModel: ObservableObject {

    /// 输入长度上限（防误粘贴巨文本）
    static let maxLength = 500

    // MARK: - 状态

    /// 当前草稿（视图绑定；onChange 时经 clampDraft 钳制）
    @Published var draft: String = ""

    /// 送达轻反馈：成功后置位，由视图延迟清除
    @Published private(set) var isDelivered: Bool = false

    /// 发送中（防重入标记）
    @Published private(set) var isSending: Bool = false

    /// 文本投递入口（默认接 TerminalTextSender，测试整体可替换）
    private let sender: (String, SessionState) async -> Bool

    init(sender: @escaping (String, SessionState) async -> Bool = { text, session in
        await TerminalTextSender.shared.send(text: text, to: session)
    }) {
        self.sender = sender
    }

    // MARK: - 纯函数（测试面）

    /// 规范化草稿：取首行（掐断换行注入向量）+ 截断到上限。
    ///
    /// 首行为空（如 "\nsecond"）返回空串——与
    /// TerminalTextSender.sanitizedSingleLine 的拒发语义对齐。
    static func normalizedDraft(_ text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        return String(firstLine.prefix(maxLength))
    }

    /// 渲染矩阵：仅开关 on 且会话非运行时显示输入行。
    ///
    /// - idle / waitingForInput：agent 已收工等输入——发送安全
    /// - processing / compacting：agent 运行中——绝不注入干扰
    /// - waitingForApproval / ended：审批卡 / 已结束各自接管，不渲染
    static func shouldShowComposer(phase: SessionPhase, isEnabled: Bool) -> Bool {
        guard isEnabled else { return false }
        switch phase {
        case .idle, .waitingForInput:
            return true
        case .processing, .compacting, .waitingForApproval, .ended:
            return false
        }
    }

    /// 当前草稿是否可发送（规范化后非纯空白）
    var canSend: Bool {
        !Self.normalizedDraft(draft)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    // MARK: - 编排

    /// onChange 钳制：粘贴多行 / 超长文本时立即规范化到合法形态。
    ///
    /// 赋值同值不会再次触发 onChange（SwiftUI 值相等短路），无循环。
    func clampDraft() {
        let normalized = Self.normalizedDraft(draft)
        if normalized != draft {
            draft = normalized
        }
    }

    /// 提交发送：防重入 → 规范化 → 空白短路 → 投递。
    ///
    /// 成功：清空草稿 + 置位送达反馈；
    /// 失败：静默保留草稿（诊断已由 TerminalTextSender 落盘）。
    func send(to session: SessionState) async {
        guard !isSending else { return }

        let text = Self.normalizedDraft(draft)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isSending = true
        defer { isSending = false }

        guard await sender(text, session) else { return }

        draft = ""
        isDelivered = true
    }

    /// 清除送达反馈（视图端延迟调用）
    func clearDeliveryFeedback() {
        isDelivered = false
    }
}

// ============================================================
// HoverTerminalTextComposer — 发送输入行视图（薄层）
// ------------------------------------------------------------
// 视图职责仅剩：渲染门判定 + 输入框 / 按钮摆盘 + 反馈节拍。
// 渲染条件与开关、会话相位双绑定：开关切换或 phase 变化
// 即时生效（运行中的会话实时收起输入行）。
// ============================================================

struct HoverTerminalTextComposer: View {
    let session: SessionState

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model = HoverTerminalTextComposerModel()

    var body: some View {
        if HoverTerminalTextComposerModel.shouldShowComposer(
            phase: session.phase,
            isEnabled: settings.terminalTextSendingEnabled
        ) {
            composerRow
                .onChange(of: model.draft) { _, _ in
                    model.clampDraft()
                }
                .onChange(of: model.isDelivered) { _, delivered in
                    guard delivered else { return }
                    // 送达轻反馈：0.8s 后图标归位
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        model.clearDeliveryFeedback()
                    }
                }
        }
    }

    // MARK: - 摆盘

    private var composerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            // 单行输入框（IslandTextField 天然 usesSingleLineMode，
            // 回车走 onSubmit——换行永远进不了草稿，双保险之一）
            IslandTextField(
                placeholder: "发送一行文本到终端…",
                text: $model.draft,
                isFocused: false,
                onSubmit: { submit() }
            )
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )

            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: model.isDelivered ? "checkmark" : "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(model.isDelivered ? .green : TerminalColors.blue)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend || model.isSending)
        .opacity(model.canSend || model.isSending ? 1 : 0.45)
    }

    // MARK: - 动作

    private func submit() {
        guard model.canSend else { return }
        Task {
            await model.send(to: session)
        }
    }
}
