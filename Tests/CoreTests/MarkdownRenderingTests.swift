import AppKit
import Foundation
import Testing
import Shared

/// Markdown 块级解析测试（M2-007，ADR-002）：
/// GFM 常见块切块、畸形/未识别输入降级 plain、保内容不丢。
@Suite("MarkdownBlockParser：块级解析（M2-007）")
struct MarkdownBlockParserTests {

    @Test("段落与标题切块，标题带层级且不含 # 前缀")
    func headingAndParagraph() {
        let blocks = MarkdownBlockParser.parse("# 标题一\n\n正文段落。\n\n## 标题二")
        #expect(blocks == [
            .heading(level: 1, markdown: "标题一"),
            .paragraph(markdown: "正文段落。"),
            .heading(level: 2, markdown: "标题二"),
        ])
    }

    @Test("围栏代码块：提取语言与代码，代码不含围栏标记与结尾换行")
    func codeBlock() {
        let text = "前文\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n后文"
        let blocks = MarkdownBlockParser.parse(text)
        #expect(blocks == [
            .paragraph(markdown: "前文"),
            .codeBlock(language: "swift", code: "let a = 1\nlet b = 2"),
            .paragraph(markdown: "后文"),
        ])
    }

    @Test("无语言标注的代码块 language 为 nil")
    func codeBlockWithoutLanguage() {
        let blocks = MarkdownBlockParser.parse("```\nplain code\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "plain code")])
    }

    @Test("无序/有序列表：逐项拆分，不含 - 与 1. 标记")
    func lists() {
        let unordered = MarkdownBlockParser.parse("- 苹果\n- 香蕉")
        #expect(unordered == [.list(items: ["苹果", "香蕉"], ordered: false)])
        let ordered = MarkdownBlockParser.parse("1. 第一步\n2. 第二步")
        #expect(ordered == [.list(items: ["第一步", "第二步"], ordered: true)])
    }

    @Test("引用块：内容不含 > 前缀")
    func blockQuote() {
        let blocks = MarkdownBlockParser.parse("> 引用一句话")
        #expect(blocks == [.blockQuote(markdown: "引用一句话")])
    }

    @Test("行内 markdown 片段原样保留（交由渲染层 AttributedString 处理）")
    func inlineMarkdownPreserved() {
        let blocks = MarkdownBlockParser.parse("这是 **加粗** 与 `行内码` 与 [链接](https://example.com)")
        guard case .paragraph(let markdown) = blocks.first else {
            Issue.record("应为段落块")
            return
        }
        #expect(markdown.contains("**加粗**"))
        #expect(markdown.contains("`行内码`"))
        #expect(markdown.contains("[链接](https://example.com)"))
    }

    @Test("分隔线切块")
    func thematicBreak() {
        let blocks = MarkdownBlockParser.parse("上文\n\n---\n\n下文")
        #expect(blocks == [
            .paragraph(markdown: "上文"),
            .thematicBreak,
            .paragraph(markdown: "下文"),
        ])
    }

    @Test("空文本与纯空白 → 空数组，不崩溃")
    func emptyInput() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("  \n\n ").isEmpty)
    }

    @Test("畸形/不完整 markdown（流式截断形态）：宽松解析不崩溃，内容不丢")
    func malformedInput() {
        // 未闭合围栏代码块：cmark 宽松解析为到文末的代码块。
        let blocks = MarkdownBlockParser.parse("```swift\nlet a = 1")
        #expect(blocks == [.codeBlock(language: "swift", code: "let a = 1")])
        // 未闭合强调：宽松解析为普通文本，内容保留。
        let inline = MarkdownBlockParser.parse("这是 **未闭合")
        guard case .paragraph(let markdown) = inline.first else {
            Issue.record("应为段落块")
            return
        }
        #expect(markdown.contains("未闭合"))
    }

    @Test("表格等未建模块降级 plain，原文保留（第一阶段不结构化渲染表格）")
    func tableFallsBackToPlain() {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownBlockParser.parse(text)
        #expect(blocks.count == 1)
        guard case .plain(let raw) = blocks.first else {
            Issue.record("表格应降级为 plain 块")
            return
        }
        #expect(raw.contains("A"))
        #expect(raw.contains("1"))
    }

    @Test("超长文本解析不崩溃（128KB 量级，对应 G0 播种上限）")
    func veryLongInput() {
        let paragraph = String(repeating: "长文本段落。", count: 10_000)
        let blocks = MarkdownBlockParser.parse(paragraph + "\n\n```\n" + String(repeating: "x", count: 50_000) + "\n```")
        #expect(blocks.count == 2)
    }
}

/// 代码块高亮测试（M2-008，ADR-002）：语言区分、超限熔断、未知语言与失败回退。
@Suite("CodeHighlighter：代码高亮与回退（M2-008）")
struct CodeHighlighterTests {

    private let highlighter = CodeHighlighter()

    @Test("已知语言产出带颜色属性的高亮结果，且原文完整")
    func knownLanguageHighlighted() throws {
        let code = "func hello() -> String { return \"hi\" }"
        let result = highlighter.highlighted(code, language: "swift")
        #expect(result.string == code)
        var colorCount = 0
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if value != nil { colorCount += 1 }
        }
        #expect(colorCount > 0)
    }

    @Test("超长块（> charLimit）走无高亮路径：原文完整、无颜色属性、仅等宽字体")
    func overLimitSkipsHighlight() {
        let code = String(repeating: "let a = 1\n", count: 2_000) // 20_000 字符 > 10_000
        #expect(code.count > CodeHighlighter.charLimit)
        let result = highlighter.highlighted(code, language: "swift")
        #expect(result.string == code)
        var hasColor = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, _, stop in
            if value != nil { hasColor = true; stop.pointee = true }
        }
        #expect(!hasColor)
    }

    @Test("未知语言不崩溃，原文完整（highlight.js 自动检测或回退纯文本均可）")
    func unknownLanguageDoesNotCrash() {
        let code = "some exotic content !!!"
        let result = highlighter.highlighted(code, language: "no_such_language_xyz")
        #expect(result.string == code)
    }

    @Test("无语言标注（nil）不崩溃，原文完整")
    func nilLanguage() {
        let code = "plain code block"
        #expect(highlighter.highlighted(code, language: nil).string == code)
    }

    @Test("同一代码重复高亮命中缓存且结果一致")
    func cachingConsistent() {
        let code = "print(\"cache\")"
        let first = highlighter.highlighted(code, language: "python")
        let second = highlighter.highlighted(code, language: "python")
        #expect(first == second)
    }
}
