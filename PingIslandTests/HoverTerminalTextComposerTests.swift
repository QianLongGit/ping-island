import XCTest
@testable import Ping_Island

// ============================================================
// HoverTerminalTextComposerTests — 悬停卡片发送输入行单元测试
// ------------------------------------------------------------
// 覆盖四类验收面（全部纯函数 / 闭包注入断言，不依赖真实终端）：
//   1. 输入规范化：换行剥离（取首行）+ 长度上限 500 双重钳制
//   2. 渲染矩阵：仅空闲态（idle / waitingForInput）且开关 on 显示
//   3. 发送路由：规范化文本透传 sender；成功清空 + 轻反馈
//   4. 安全红线：空白不发 / 失败静默保留草稿 / 运行中防重入
// ============================================================

@MainActor
final class HoverTerminalTextComposerTests: XCTestCase {

    // MARK: - 构造助手

    /// 最小可用会话：sender 注入下 clientInfo / tmux 均不参与判定
    private func makeSession() -> SessionState {
        SessionState(
            sessionId: "test-session",
            cwd: "/tmp/demo-project"
        )
    }

    /// 发送录制器：捕获 sender 收到的文本序列与桩结果
    private final class SendRecorder {
        var calls: [String] = []
        var stubResult = true

        func sender() -> (String, SessionState) async -> Bool {
            { [self] text, _ in
                calls.append(text)
                return stubResult
            }
        }
    }

    /// 门控录制器：sender 挂起直到测试显式放行（防重入时序控制）
    private final class GatedSendRecorder {
        var calls: [String] = []
        private(set) var enteredCount = 0
        private var pendingContinuation: CheckedContinuation<Bool, Never>?

        func sender() -> (String, SessionState) async -> Bool {
            { [self] text, _ in
                calls.append(text)
                enteredCount += 1
                return await withCheckedContinuation { continuation in
                    pendingContinuation = continuation
                }
            }
        }

        func resume(result: Bool) {
            pendingContinuation?.resume(returning: result)
            pendingContinuation = nil
        }
    }

    // MARK: - 输入规范化（防注入 + 防巨文本）

    func testNormalizedDraftKeepsFirstLineOnly() {
        XCTAssertEqual(HoverTerminalTextComposerModel.normalizedDraft("first\nsecond"), "first")
        XCTAssertEqual(HoverTerminalTextComposerModel.normalizedDraft("first\r\nsecond"), "first")
        XCTAssertEqual(HoverTerminalTextComposerModel.normalizedDraft("plain"), "plain")
    }

    func testNormalizedDraftClampsToMaxLength() {
        let oversized = String(repeating: "a", count: HoverTerminalTextComposerModel.maxLength + 100)
        let normalized = HoverTerminalTextComposerModel.normalizedDraft(oversized)
        XCTAssertEqual(normalized.count, HoverTerminalTextComposerModel.maxLength)
    }

    func testNormalizedDraftIsEmptyForLeadingNewlineInput() {
        // 首行为空：与 TerminalTextSender.sanitizedSingleLine 的拒发语义对齐
        XCTAssertEqual(HoverTerminalTextComposerModel.normalizedDraft("\nsecond"), "")
        XCTAssertEqual(HoverTerminalTextComposerModel.normalizedDraft("\n"), "")
    }

    func testClampDraftNormalizesInPlace() {
        let model = HoverTerminalTextComposerModel(sender: SendRecorder().sender())
        model.draft = "hello\nrm -rf /"
        model.clampDraft()
        XCTAssertEqual(model.draft, "hello")

        model.draft = String(repeating: "b", count: 600)
        model.clampDraft()
        XCTAssertEqual(model.draft.count, HoverTerminalTextComposerModel.maxLength)
    }

    // MARK: - 发送可用判定

    func testCanSendRequiresNonBlankDraft() {
        let model = HoverTerminalTextComposerModel(sender: SendRecorder().sender())

        model.draft = "hi"
        XCTAssertTrue(model.canSend)

        model.draft = "   "
        XCTAssertFalse(model.canSend)

        model.draft = ""
        XCTAssertFalse(model.canSend)

        model.draft = "\nignored"
        XCTAssertFalse(model.canSend)
    }

    // MARK: - 渲染矩阵（开关 + 会话相位）

    func testShouldShowComposerOnlyForIdlePhasesWhenEnabled() {
        let allPhases: [SessionPhase] = [
            .idle,
            .processing,
            .waitingForInput,
            .waitingForApproval(PermissionContext(
                toolUseId: "tu",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: Date()
            )),
            .compacting,
            .ended
        ]
        let expected: [Bool] = [true, false, true, false, false, false]

        for (phase, isVisible) in zip(allPhases, expected) {
            XCTAssertEqual(
                HoverTerminalTextComposerModel.shouldShowComposer(phase: phase, isEnabled: true),
                isVisible,
                "phase \(phase) 预期 isVisible=\(isVisible)"
            )
        }
    }

    func testShouldShowComposerHiddenWhenSwitchOff() {
        // 开关默认 false：off 时输入行整体不渲染（第一道门）
        for phase: SessionPhase in [.idle, .waitingForInput] {
            XCTAssertFalse(
                HoverTerminalTextComposerModel.shouldShowComposer(phase: phase, isEnabled: false)
            )
        }
    }

    // MARK: - 发送路由（成功清空 / 失败静默）

    func testSendRoutesNormalizedFirstLineToSender() async {
        let recorder = SendRecorder()
        let model = HoverTerminalTextComposerModel(sender: recorder.sender())
        let session = makeSession()

        model.draft = "git status\nrm -rf /"
        await model.send(to: session)

        // 换行之后的内容绝不可达（与 N3 服务层红线一致）
        XCTAssertEqual(recorder.calls, ["git status"])
    }

    func testSendSuccessClearsDraftAndMarksDelivered() async {
        let recorder = SendRecorder()
        recorder.stubResult = true
        let model = HoverTerminalTextComposerModel(sender: recorder.sender())

        model.draft = "cargo build"
        await model.send(to: makeSession())

        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isDelivered)
        XCTAssertFalse(model.isSending)

        model.clearDeliveryFeedback()
        XCTAssertFalse(model.isDelivered)
    }

    func testSendFailureKeepsDraftAndStaysSilent() async {
        let recorder = SendRecorder()
        recorder.stubResult = false
        let model = HoverTerminalTextComposerModel(sender: recorder.sender())

        model.draft = "cargo build"
        await model.send(to: makeSession())

        // 失败静默：草稿保留供重试，不出现成功反馈（诊断由服务层落盘）
        XCTAssertEqual(model.draft, "cargo build")
        XCTAssertFalse(model.isDelivered)
        XCTAssertFalse(model.isSending)
    }

    func testSendSkipsWhenDraftIsEffectivelyBlank() async {
        let recorder = SendRecorder()
        let model = HoverTerminalTextComposerModel(sender: recorder.sender())

        model.draft = "   "
        await model.send(to: makeSession())

        XCTAssertTrue(recorder.calls.isEmpty, "空白草稿不得触达 sender")
    }

    // MARK: - 防重入（发送中忽略再次提交）

    func testSendIgnoresReentrantCallWhileInFlight() async {
        let gate = GatedSendRecorder()
        let model = HoverTerminalTextComposerModel(sender: gate.sender())
        let session = makeSession()

        model.draft = "first command"
        async let outstanding: Void = model.send(to: session)

        // 等待第一次发送进入挂起的 sender 内部（isSending 已置位）
        while gate.enteredCount == 0 {
            await Task.yield()
        }

        await model.send(to: session) // 重入提交：必须被忽略
        gate.resume(result: true)
        _ = await outstanding

        XCTAssertEqual(gate.calls.count, 1, "发送中不得重复投递")
        XCTAssertEqual(model.draft, "")
    }
}
