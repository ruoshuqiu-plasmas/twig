import Foundation
import Markdown

/// Markdown 块级模型（任务 M2-007，ADR-002）：
/// swift-markdown AST → 扁平块数组，供 SwiftUI 块级自渲染。
/// 块为纯值类型，不携带任何 AST 引用，可安全跨层传递。
public enum MarkdownBlock: Equatable, Sendable {
    /// 标题（level 1~6；markdown 为行内片段，粗斜体/行内码等由 AttributedString(markdown:) 处理）。
    case heading(level: Int, markdown: String)
    /// 普通段落（行内 markdown）。
    case paragraph(markdown: String)
    /// 引用块（内部内容的行内 markdown，多段以换行连接）。
    case blockQuote(markdown: String)
    /// 列表（每项为行内 markdown；ordered 区分有序/无序）。
    case list(items: [String], ordered: Bool)
    /// 围栏代码块（language 可为 nil；code 不含围栏标记）。
    case codeBlock(language: String?, code: String)
    /// 分隔线。
    case thematicBreak
    /// 未识别/降级块：原样文本（表格、HTML 块等第一阶段不结构化渲染，保内容不丢）。
    case plain(String)
}

/// Markdown 块级解析器（任务 M2-007）。
///
/// 设计约定（ADR-002）：
/// - 只在消息进入稳定态后调用，流式阶段不解析；
/// - swift-markdown 解析本身不抛错，畸形输入会宽松解析；
///   任何未建模的块类型一律降级为 `.plain` 原样保留——**保内容、不崩溃**（§6.5 第 7 条）。
public enum MarkdownBlockParser {

    /// 解析完整 markdown 文本为块数组。空文本/纯空白返回空数组。
    public static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let document = Document(parsing: text)
        return document.children.compactMap(block(from:))
    }

    // MARK: - 私有

    private static func block(from markup: any Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, markdown: inlineMarkdown(of: heading))
        case is Paragraph:
            return .paragraph(markdown: trimmed(markup.format()))
        case let quote as BlockQuote:
            // quote.format() 每行带 "> " 前缀（cmark 源格式保留），逐行剥掉。
            let inner = quote.format()
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    var l = line
                    while l.hasPrefix(">") {
                        l = l.dropFirst()
                        if l.hasPrefix(" ") { l = l.dropFirst() }
                    }
                    return l
                }
                .joined(separator: "\n")
            return .blockQuote(markdown: trimmed(inner))
        case let list as OrderedList:
            return .list(items: listItems(of: list), ordered: true)
        case let list as UnorderedList:
            return .list(items: listItems(of: list), ordered: false)
        case let code as CodeBlock:
            // CodeBlock.code 可能带结尾换行，去掉便于渲染与计数。
            var content = code.code
            while content.hasSuffix("\n") { content.removeLast() }
            return .codeBlock(language: code.language, code: content)
        case is ThematicBreak:
            return .thematicBreak
        default:
            // 表格、HTML 块等未建模类型：format() 还原原文，降级 plain，不丢内容。
            let raw = trimmed(markup.format())
            return raw.isEmpty ? nil : .plain(raw)
        }
    }

    /// 取标题的行内内容（不含 `#` 前缀）。
    private static func inlineMarkdown(of heading: Heading) -> String {
        trimmed(heading.children.map { $0.format() }.joined())
    }

    /// 取列表各项内容（不含 `-`/`1.` 标记；项内多段以换行连接）。
    private static func listItems(of list: any Markup) -> [String] {
        list.children.map { item in
            item.children.map { trimmed($0.format()) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// format() 对块级节点会带入块间分隔空行（前导 `\n\n`）与结尾换行，统一两端清洗。
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
