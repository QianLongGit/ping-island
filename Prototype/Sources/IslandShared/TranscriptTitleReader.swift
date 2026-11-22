import Foundation

// ═══════════════════════════════════════════════════════════════
// TranscriptTitleReader —— 转写尾部标题读取器（Task 11 远程会话
// 标题透传 · bridge 侧数据层）
//
// ▸ 场景：远程会话的 transcript jsonl 在 SSH 主机上，Mac 侧
//   ConversationParser 读不到（displayTitle 第 2 级断链）。远程
//   bridge 在 hook 进程内调用本读取器，从转写尾部提取最新
//   custom-title（Claude 2.x，每轮重写）/ summary（Claude 1.x
//   旧格式兜底），随 wire 顶层字段 conversationTitle 发往 Mac。
//
// ▸ 语义：与 App 侧 ConversationParser.parseContent 对齐——倒序
//   扫描取最新记录，custom-title 优先于 summary（即使 summary
//   记录更晚）。
//
// ▸ 红线：
//   - 大转写（2.7MB+ 常见）只 seek 读尾部 ≤128KB，禁全文件读；
//   - 任何失败（缺文件/坏行/解码失败）静默返回 nil，绝不抛错、
//     绝不阻塞 hook 事件主流程（性能预算 <5ms）。
// ═══════════════════════════════════════════════════════════════

public enum TranscriptTitleReader {

    /// 尾部读取预算（字节）：128KB。custom-title 每轮重写且总在
    /// 文件末尾附近，预算覆盖数千轮对话绰绰有余。
    public static let tailByteBudget = 128 * 1024

    // ── 对外唯一入口 ────────────────────────────────────────────

    /// 从转写 jsonl 尾部提取最新会话标题。
    /// - 复杂度：O(min(fileSize, 128KB))；读失败返回 nil。
    public static func latestTitle(transcriptPath: String?) -> String? {
        // 路径防御：nil / 空串 / 纯空白一律直接落空
        guard let path = transcriptPath?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil  // 文件不存在 / 无读权限：静默 nil
        }
        defer { try? handle.close() }

        // 任何 I/O 异常（文件被截断、并发写导致的奇态）都不得
        // 逃逸到 hook 主流程——统一 do/catch 吞掉。
        do {
            return try latestTitle(from: handle)
        } catch {
            return nil
        }
    }

    // ── 尾部读取与解析 ──────────────────────────────────────────

    /// seek 到尾部预算窗口并解析。所有可抛错误由调用点吞掉。
    private static func latestTitle(from handle: FileHandle) throws -> String? {
        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else { return nil }

        // 窗口起点：小文件从头读；大文件只取最后 tailByteBudget 字节
        let windowOffset = fileSize > tailByteBudget
            ? fileSize - UInt64(tailByteBudget)
            : 0
        handle.seek(toFileOffset: windowOffset)
        guard let windowData = try handle.read(upToCount: Int(
            min(fileSize - windowOffset, UInt64(tailByteBudget))
        )), !windowData.isEmpty else {
            return nil
        }

        // seek 落点可能切在行中间：非整块读取时丢弃首行残段。
        // （首行残段还可能切在 UTF-8 多字节字符中间，故先在字节
        //   层面找换行再解码，随后用 lossy 解码兜底残余奇字节。）
        var data = windowData
        if windowOffset > 0, let firstNewline = windowData.firstIndex(of: UInt8(ascii: "\n")) {
            data = windowData[(firstNewline + 1)...]
        }
        let text = String(decoding: data, as: UTF8.self)

        return latestTitle(inTailText: text)
    }

    /// 尾部文本倒序扫描：先命中 custom-title 即最新且最高优先；
    /// summary 命中后仍继续向前找是否有更晚的 custom-title。
    /// （语义对齐 ConversationParser：结果 = customTitle ?? summary）
    private static func latestTitle(inTailText text: String) -> String? {
        var customTitle: String?
        var summary: String?

        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue  // 坏 JSON 行 / 半行残段：跳过，绝不中断
            }

            let type = json["type"] as? String

            // Claude 2.x：custom-title 记录每轮重写（用户 /rename
            // 的标题持久化处），空白标题视为无效继续向前找
            if customTitle == nil, type == "custom-title",
               let titleText = json["customTitle"] as? String,
               !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                customTitle = titleText
                break  // 倒序首命中即最新，且优先级最高，可提前收束
            }

            // Claude 1.x 旧格式兜底：summary 记录
            if summary == nil, type == "summary",
               let summaryText = json["summary"] as? String,
               !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summary = summaryText
            }
        }

        return customTitle ?? summary
    }
}
