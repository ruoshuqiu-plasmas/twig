import Foundation

/// 选区快照（任务 M3-001）：用户在 assistant 消息或工具结果中选中的一段文字的冻结记录。
///
/// **锚点坐标语义（B-M3 既定决策，勿改）**：
/// `start`/`length` 是相对该消息**渲染后纯文本**（即 NSTextView 内 `NSAttributedString.string`）
/// 的 UTF-16 偏移，**不是**原始 markdown 源的偏移。渲染管线（`MarkdownBlockParser` →
/// `MarkdownAttributedRenderer`）是确定性的，回跳定位时对同一消息重新渲染即可复现坐标。
///
/// 冻结语义：点击「追问」即把当前 snapshot 固定为支线锚点（浮动按钮 UI 归 M3-003）。
/// 每条消息一个 NSTextView，天然不存在跨消息选区，故快照只属于单条消息。
public struct SelectionSnapshot: Equatable, Hashable, Sendable, Codable {

    /// 所属消息 id（Message.id）。
    public let messageID: String
    /// 选中文字原文。
    public let quote: String
    /// 起始偏移（UTF-16 code units，相对渲染后纯文本）。
    public let start: Int
    /// 长度（UTF-16 code units）。
    public let length: Int

    public init(messageID: String, quote: String, start: Int, length: Int) {
        self.messageID = messageID
        self.quote = quote
        self.start = start
        self.length = length
    }

    /// 结束偏移（不含）。
    public var end: Int { start + length }
}
