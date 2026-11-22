import Foundation
import IslandShared
import Testing

// ═══════════════════════════════════════════════════════════════
// 转写尾部标题读取器（Task 11 远程会话标题透传 · bridge 侧数据层）
//
// 远程 bridge 在 hook 进程内从 transcript jsonl 尾部（≤128KB
// seek）提取最新 custom-title / summary，随 wire 顶层字段
// conversationTitle 发往 Mac。语义与 App 侧 ConversationParser
// 对齐：倒序扫描，custom-title 优先于 summary（Claude 2.x 每轮
// 重写 custom-title；summary 为 1.x 旧格式兜底）。
//
// 红线约束在此验证：
//   ▸ 大文件只读尾部（头部记录不可见）
//   ▸ 坏 JSON 行 / 空文件 / 缺文件一律静默 nil，绝不抛错
// ═══════════════════════════════════════════════════════════════

// MARK: - Fixture

/// 把 jsonl 行序列写入临时文件，返回路径（用例结束不主动清理，
/// 临时目录由系统回收）。
private func writeTranscript(_ lines: [String]) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-title-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("session.jsonl")
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

/// 单条 user 记录（占位普通行，用于稀释标题行位置）。
private func userLine(_ text: String) -> String {
    """
    {"type":"user","isMeta":false,"message":{"role":"user","content":"\(text)"}}
    """
}

/// custom-title 记录（Claude 2.x：每轮重写）。
private func customTitleLine(_ title: String) -> String {
    """
    {"type":"custom-title","customTitle":"\(title)"}
    """
}

/// summary 记录（Claude 1.x 旧格式兜底）。
private func summaryLine(_ text: String) -> String {
    """
    {"type":"summary","summary":"\(text)"}
    """
}

// MARK: - 基础提取

@Test func latestCustomTitleWinsOverOlder() throws {
    let path = try writeTranscript([
        userLine("turn-1"),
        customTitleLine("旧标题"),
        userLine("turn-2"),
        customTitleLine("Kero-Island"),
        userLine("turn-3"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "Kero-Island")
}

@Test func summaryFallsBackWhenNoCustomTitle() throws {
    let path = try writeTranscript([
        summaryLine("旧摘要"),
        userLine("turn-1"),
        summaryLine("迁移的会话"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "迁移的会话")
}

@Test func customTitleBeatsNewerSummary() throws {
    // 优先级语义（对齐 ConversationParser）：customTitle ?? summary，
    // 即使 summary 记录出现在更晚的行，custom-title 依然优先。
    let path = try writeTranscript([
        customTitleLine("用户重命名"),
        summaryLine("更晚写入的摘要"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "用户重命名")
}

@Test func blankCustomTitleSkippedAndFallsThrough() throws {
    let path = try writeTranscript([
        customTitleLine("   "),
        summaryLine("摘要兜底"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "摘要兜底")
}

// MARK: - 容错

@Test func noTitleRecordsReturnsNil() throws {
    let path = try writeTranscript([
        userLine("turn-1"),
        userLine("turn-2"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == nil)
}

@Test func emptyFileReturnsNil() throws {
    let path = try writeTranscript([])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == nil)
}

@Test func malformedLinesTolerated() throws {
    let path = try writeTranscript([
        "{ 坏掉的半行",
        customTitleLine("坏行之后的标题"),
        "another-garbage-line",
        userLine("turn-1"),
    ])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "坏行之后的标题")
}

@Test func missingFileReturnsNil() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-\(UUID().uuidString).jsonl").path

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: missing) == nil)
}

@Test func nilPathReturnsNil() {
    #expect(TranscriptTitleReader.latestTitle(transcriptPath: nil) == nil)
    #expect(TranscriptTitleReader.latestTitle(transcriptPath: "") == nil)
}

// MARK: - 尾部 seek 预算

@Test func headRecordsBeyondTailBudgetAreInvisible() throws {
    // 构造远超 128KB 的文件：custom-title 只在头部（预算之外），
    // 尾部全是普通行 → 必须返回 nil（证明没有全文件读）。
    let padding = Array(repeating: userLine("padding-padding-padding"), count: 6000)  // ~300KB
    let path = try writeTranscript([customTitleLine("头部标题")] + padding)

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == nil)
}

@Test func tailRecordsWithinBudgetAreVisible() throws {
    // 大文件（>128KB）尾部有 custom-title → 正常命中。
    let padding = Array(repeating: userLine("padding-padding-padding"), count: 6000)
    let path = try writeTranscript(padding + [customTitleLine("尾部标题")])

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: path) == "尾部标题")
}

@Test func truncatedFirstLineInTailBlockIsDropped() throws {
    // seek 落点可能切在行中间：尾部块首行是半行 JSON，必须丢弃
    // 而不是让解析失败。手工拼一个「半行 + 完整标题」的尾部内容。
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-title-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("session.jsonl")

    let headPadding = String(repeating: "x", count: 128 * 1024 + 512)  // 越过预算的头部填充
    let truncatedHead = "{\"type\":\"custom-title\",\"customTit"  // seek 切出的半行
    let content = headPadding + "\n" + truncatedHead + "\n" + customTitleLine("半行之后的标题")
    try content.write(to: url, atomically: true, encoding: .utf8)

    #expect(TranscriptTitleReader.latestTitle(transcriptPath: url.path) == "半行之后的标题")
}
