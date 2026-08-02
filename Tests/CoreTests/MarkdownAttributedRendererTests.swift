import AppKit
import Foundation
import Testing
import Shared

/// MarkdownAttributedRenderer 测试（M3-001）：
/// 各块类型的纯文本与属性正确性；纯文本与 MarkdownBlockParser 输入的确定性映射
/// （锚点坐标可复现的前提）。
@Suite("MarkdownAttributedRenderer：块 → NSAttributedString（M3-001）")
struct MarkdownAttributedRendererTests {

    // MARK: - 工具

    private func font(of text: NSAttributedString, in substring: String) -> NSFont? {
        let range = (text.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    private func hasTrait(_ trait: NSFontDescriptor.SymbolicTraits, in font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(trait) ?? false
    }

    // MARK: - 纯文本确定性

    @Test("空数组 → 空串")
    func emptyBlocks() {
        #expect(MarkdownAttributedRenderer.render([]).string == "")
    }

    @Test("块间恰好一个换行：段落+标题+列表的纯文本映射恒定")
    func deterministicPlainText() {
        let blocks = MarkdownBlockParser.parse("# 标题\n\n正文段落。\n\n- 苹果\n- 香蕉")
        let rendered = MarkdownAttributedRenderer.render(blocks)
        #expect(rendered.string == "标题\n正文段落。\n• 苹果\n• 香蕉")
    }

    @Test("有序列表前缀为 1. / 2.，引用与代码块原文完整")
    func deterministicPlainTextFull() {
        let markdown = "> 引用一句\n\n1. 第一步\n2. 第二步\n\n```swift\nlet a = 1\n```"
        let rendered = MarkdownAttributedRenderer.render(MarkdownBlockParser.parse(markdown))
        #expect(rendered.string == "引用一句\n1. 第一步\n2. 第二步\nlet a = 1")
    }

    @Test("同一输入重复渲染纯文本一致（锚点坐标可复现）")
    func renderIsDeterministic() {
        let blocks = MarkdownBlockParser.parse("# T\n\n**加粗** 正文\n\n```py\nprint(1)\n```\n\n> 引用")
        let first = MarkdownAttributedRenderer.render(blocks)
        let second = MarkdownAttributedRenderer.render(blocks)
        #expect(first.string == second.string)
        #expect(first == second)
    }

    @Test("thematicBreak 渲染为固定分隔线，plain 块原样保留")
    func thematicBreakAndPlain() {
        let blocks = MarkdownBlockParser.parse("上文\n\n---\n\n下文")
        let rendered = MarkdownAttributedRenderer.render(blocks)
        #expect(rendered.string.hasPrefix("上文\n"))
        #expect(rendered.string.hasSuffix("\n下文"))
        #expect(rendered.string.contains(String(repeating: "─", count: 24)))
    }

    // MARK: - 属性正确性

    @Test("段落：纯文本正确，基础字体为系统字号")
    func paragraph() {
        let rendered = MarkdownAttributedRenderer.render([.paragraph(markdown: "正文段落。")])
        #expect(rendered.string == "正文段落。")
        let font = font(of: rendered, in: "正文")
        #expect(font?.pointSize == NSFont.systemFontSize)
    }

    @Test("标题：加粗且随层级放大（1 级 22pt，4 级 14pt）")
    func headingBoldAndSized() {
        let h1 = MarkdownAttributedRenderer.render([.heading(level: 1, markdown: "标题一")])
        let f1 = font(of: h1, in: "标题一")
        #expect(hasTrait(.bold, in: f1))
        #expect(f1?.pointSize == 22)

        let h4 = MarkdownAttributedRenderer.render([.heading(level: 4, markdown: "标题四")])
        let f4 = font(of: h4, in: "标题四")
        #expect(hasTrait(.bold, in: f4))
        #expect(f4?.pointSize == 14)
    }

    @Test("行内 markdown 生效：加粗片段带 bold 字形，普通片段不带")
    func inlineBold() {
        let rendered = MarkdownAttributedRenderer.render([.paragraph(markdown: "这是 **加粗** 文字")])
        #expect(rendered.string == "这是 加粗 文字")
        #expect(hasTrait(.bold, in: font(of: rendered, in: "加粗")))
        #expect(!hasTrait(.bold, in: font(of: rendered, in: "这是")))
    }

    @Test("引用块：斜体 + 缩进 + 次要色")
    func blockQuote() {
        let rendered = MarkdownAttributedRenderer.render([.blockQuote(markdown: "引用一句")])
        #expect(hasTrait(.italic, in: font(of: rendered, in: "引用")))
        let range = (rendered.string as NSString).range(of: "引用")
        let style = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == 16)
        let color = rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.secondaryLabelColor)
    }

    @Test("代码块：走 CodeHighlighter，等宽字体且原文完整")
    func codeBlock() {
        let code = "let a = 1\nlet b = 2"
        let rendered = MarkdownAttributedRenderer.render([.codeBlock(language: "swift", code: code)])
        #expect(rendered.string == code)
        let font = font(of: rendered, in: "let a")
        #expect(font?.isFixedPitch == true)
    }

    @Test("超长代码块走等宽纯文本回退，原文完整（熔断不丢内容）")
    func overLimitCodeBlock() {
        let code = String(repeating: "let a = 1\n", count: 2_000) // 20_000 字符 > charLimit
        let rendered = MarkdownAttributedRenderer.render([.codeBlock(language: "swift", code: code)])
        #expect(rendered.string == code)
        #expect(font(of: rendered, in: "let a")?.isFixedPitch == true)
    }

    @Test("畸形行内 markdown 不崩溃，内容不丢（宽松解析）")
    func malformedInline() {
        let rendered = MarkdownAttributedRenderer.render([.paragraph(markdown: "这是 **未闭合")])
        #expect(rendered.string.contains("未闭合"))
    }

    @Test("列表项带项目符号/编号前缀，项间一个换行")
    func listPrefixes() {
        let unordered = MarkdownAttributedRenderer.render([.list(items: ["苹果", "香蕉"], ordered: false)])
        #expect(unordered.string == "• 苹果\n• 香蕉")
        let ordered = MarkdownAttributedRenderer.render([.list(items: ["第一步", "第二步"], ordered: true)])
        #expect(ordered.string == "1. 第一步\n2. 第二步")
    }
}

/// SelectionSnapshot 测试（M3-001）：值语义与端点计算。
@Suite("SelectionSnapshot：选区快照模型（M3-001）")
struct SelectionSnapshotTests {

    @Test("end = start + length；等值与编解码")
    func valueSemantics() throws {
        let snapshot = SelectionSnapshot(messageID: "m1", quote: "选中文本", start: 4, length: 8)
        #expect(snapshot.end == 12)
        #expect(snapshot == SelectionSnapshot(messageID: "m1", quote: "选中文本", start: 4, length: 8))

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SelectionSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}
