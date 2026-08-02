import AppKit
import SwiftUI

/// 可选中的只读消息文本（任务 M3-001）：NSViewRepresentable 包装只读 NSTextView。
///
/// SwiftUI `.textSelection` 无法读取选区内容与坐标，B-M3 支线追问需要精确锚点，
/// 故 assistant 稳定态消息与工具结果区改走本组件：
/// - 不可编辑、可选中、背景透明，宽度跟随 SwiftUI 布局、高度按内容自适应；
/// - 选区变化经 `onSelectionChange` 回调 ``SelectionSnapshot``（选区清空/纯空白回 nil）；
/// - 坐标为渲染后纯文本的 UTF-16 偏移（语义见 ``SelectionSnapshot`` 注释）。
///
/// 每条消息一个实例，天然不存在跨消息选区。与既有 `.textSelection(.enabled)` 的
/// Text（user/流式消息）互不干扰：两套选择系统独立，不会互相清空。
public struct SelectableMessageText: NSViewRepresentable {

    /// 所属消息 id（写入 snapshot.messageID）。
    public let messageID: String
    /// 渲染产物（assistant 消息为 ``MarkdownAttributedRenderer`` 输出）。
    public let attributedText: NSAttributedString
    /// 选区变化回调；nil 表示无有效选区。回调在主线程触发。
    public let onSelectionChange: (SelectionSnapshot?) -> Void

    public init(
        messageID: String,
        attributedText: NSAttributedString,
        onSelectionChange: @escaping (SelectionSnapshot?) -> Void
    ) {
        self.messageID = messageID
        self.attributedText = attributedText
        self.onSelectionChange = onSelectionChange
    }

    /// 便捷入口：纯文本 + 单一字体/颜色（工具结果区等无 markdown 场景）。
    public init(
        messageID: String,
        text: String,
        font: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = NSColor.labelColor,
        onSelectionChange: @escaping (SelectionSnapshot?) -> Void
    ) {
        self.init(
            messageID: messageID,
            attributedText: NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
            ]),
            onSelectionChange: onSelectionChange
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(messageID: messageID, onSelectionChange: onSelectionChange)
    }

    /// 选区内容 → 快照（BR-03 空白过滤的唯一实现，供 Coordinator 与测试共用）：
    /// 空/纯空白（含空格、换行、制表符等混合空白）→ nil；含非空白字符 → snapshot。
    static func makeSnapshot(
        messageID: String, quote: String, start: Int, length: Int
    ) -> SelectionSnapshot? {
        guard length > 0, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SelectionSnapshot(messageID: messageID, quote: quote, start: start, length: length)
    }

    public func makeNSView(context: Context) -> NSTextView {
        let textView = AutoSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // 文本顶格，无内边距，与原 SwiftUI Text 观感一致。
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 宽度跟随父布局、高度按内容撑开（SwiftUI 据此取 intrinsic size）。
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(attributedText)
        return textView
    }

    public func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        // 排坑（2026-08-02 GUI 冒烟）：NSTextStorage 的字体修正（fixFontAttributeInRange）
        // 会在 setAttributedString 后改写字体属性，使 attributedString() 与源永不相等——
        // 若按属性串比较会反复 set → 无限布局事务循环（主线程卡死、内存膨胀）。
        // 故只按纯文本比较：渲染器对同内容确定性输出，文本相同即属性相同。
        if textView.string != attributedText.string {
            textView.textStorage?.setAttributedString(attributedText)
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// 选区监听。NSTextView delegate 回调本就在主线程触发，显式 @MainActor 满足 Swift 6 并发标注。
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        private let messageID: String
        fileprivate var onSelectionChange: (SelectionSnapshot?) -> Void

        init(messageID: String, onSelectionChange: @escaping (SelectionSnapshot?) -> Void) {
            self.messageID = messageID
            self.onSelectionChange = onSelectionChange
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                onSelectionChange(nil)
                return
            }
            let range = textView.selectedRange()
            guard range.location != NSNotFound, range.length > 0 else {
                onSelectionChange(nil)
                return
            }
            let nsString = textView.string as NSString
            guard NSMaxRange(range) <= nsString.length else {
                onSelectionChange(nil)
                return
            }
            let quote = nsString.substring(with: range)
            // 过滤纯空白选区（空选区已被上方 length > 0 拦截；逻辑单一实现见 makeSnapshot）。
            onSelectionChange(SelectableMessageText.makeSnapshot(
                messageID: messageID, quote: quote,
                start: range.location, length: range.length
            ))
        }
    }

    /// 按内容自适应高度的 NSTextView（2026-08-02 排坑：GUI 冒烟发现消息行重叠、
    /// 页面无法滚动）。NSTextView 默认不向 SwiftUI 报告有效 intrinsicContentSize
    /// （返回 noIntrinsicMetric），NSViewRepresentable 无法确定行高 → LazyVStack
    /// 行高塌陷、ScrollView 内容高度错误。修法：intrinsicContentSize 经
    /// layoutManager 实测排版高度回报；宽度变化时作废重算（换行数随宽度变）。
    final class AutoSizingTextView: NSTextView {
        override var intrinsicContentSize: NSSize {
            guard let layoutManager, let textContainer else {
                return super.intrinsicContentSize
            }
            layoutManager.ensureLayout(for: textContainer)
            let height = layoutManager.usedRect(for: textContainer).height
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
        }

        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = abs(newSize.width - frame.width) > 0.5
            super.setFrameSize(newSize)
            if widthChanged {
                invalidateIntrinsicContentSize()
            }
        }
    }
}
