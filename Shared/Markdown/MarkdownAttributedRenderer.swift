import AppKit
import Foundation

/// Markdown 块 → NSAttributedString 渲染器（任务 M3-001，ADR-002 延伸）。
///
/// B-M3 起 assistant 稳定态消息改由只读 NSTextView 渲染（为了拿到选区与坐标），
/// 因此需要把 ``MarkdownBlock`` 数组转换为单一 NSAttributedString：
/// - 代码块复用 ``CodeHighlighter``（Highlightr 封装，超限/失败自动回退等宽纯文本）；
/// - 行内 markdown（粗斜体/行内码/链接）经 `AttributedString(markdown:)` 转换，
///   解析失败回退纯文本，不丢内容（§6.5 第 7 条）；
/// - 标题加粗放大、引用块斜体+缩进+次要色、列表加项目符号——保持简洁。
///
/// **确定性约定**：同一 ``MarkdownBlock`` 数组的纯文本产物（`.string`）恒定——
/// 块间恰好一个 `\n`、列表项前缀为 `• `/`N. `、代码块不含围栏。这是选区锚点
/// （``SelectionSnapshot``）坐标可复现的前提，修改渲染规则须同步审视 B-M3 锚点逻辑。
public enum MarkdownAttributedRenderer {

    /// 渲染块数组为单一 NSAttributedString。空数组返回空串。
    public static func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            result.append(renderBlock(block))
            // 块间恰好一个换行；该换行归属前一段落，携带段后间距以形成块间距。
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: baseFont,
                    .paragraphStyle: blockSpacingStyle,
                ]))
            }
        }
        return result
    }

    // MARK: - 块渲染

    private static func renderBlock(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case let .heading(level, markdown):
            let size = headingFontSize(level)
            let text = NSMutableAttributedString(attributedString: inline(markdown, baseSize: size))
            text.addAttribute(.paragraphStyle, value: blockSpacingStyle, range: text.fullRange)
            transformFonts(in: text, size: size) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            return text

        case let .paragraph(markdown):
            let text = NSMutableAttributedString(attributedString: inline(markdown))
            text.addAttribute(.paragraphStyle, value: blockSpacingStyle, range: text.fullRange)
            return text

        case let .blockQuote(markdown):
            let text = NSMutableAttributedString(attributedString: inline(markdown))
            text.addAttributes([
                .paragraphStyle: quoteStyle,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: text.fullRange)
            transformFonts(in: text) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return text

        case let .list(items, ordered):
            let text = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 {
                    text.append(NSAttributedString(string: "\n", attributes: [
                        .font: baseFont,
                        .paragraphStyle: itemSpacingStyle,
                    ]))
                }
                let prefix = ordered ? "\(index + 1). " : "• "
                text.append(NSAttributedString(string: prefix, attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: itemSpacingStyle,
                ]))
                let itemText = NSMutableAttributedString(attributedString: inline(item))
                itemText.addAttribute(.paragraphStyle, value: itemSpacingStyle, range: itemText.fullRange)
                text.append(itemText)
            }
            return text

        case let .codeBlock(language, code):
            // 高亮产物（含超限/失败的等宽纯文本回退）+ 浅灰背景，对应原 CodeBlockView 观感。
            let text = NSMutableAttributedString(
                attributedString: CodeHighlighter.shared.highlighted(code, language: language)
            )
            text.addAttributes([
                .backgroundColor: NSColor.gray.withAlphaComponent(0.10),
                .paragraphStyle: blockSpacingStyle,
            ], range: text.fullRange)
            return text

        case .thematicBreak:
            return NSAttributedString(string: String(repeating: "─", count: 24), attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: blockSpacingStyle,
            ])

        case let .plain(raw):
            return NSAttributedString(string: raw, attributes: [
                .font: baseFont,
                .paragraphStyle: blockSpacingStyle,
            ])
        }
    }

    // MARK: - 行内 markdown

    /// 行内 markdown → NSAttributedString；失败回退纯文本（保内容）。
    ///
    /// 排坑（M3-001 实测，macOS 15 SDK）：`NSAttributedString(markdown:)` 与
    /// `NSAttributedString(AttributedString(markdown:))` 都**只记录**
    /// `.inlinePresentationIntent` 意图属性，不解析为字体字形——必须自行枚举意图加粗/斜体/等宽。
    /// 意图解析后移除该属性，避免 AppKit 二次处理。
    /// 无字体属性的区段补基础字体（NSTextView 无属性时默认 12pt Helvetica，与 SwiftUI body 不一致）。
    private static func inline(_ markdown: String, baseSize: CGFloat = NSFont.systemFontSize) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: baseSize)
        guard let parsed = try? NSAttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full),
            baseURL: nil
        ) else {
            return NSAttributedString(string: markdown, attributes: [.font: base])
        }
        let text = NSMutableAttributedString(attributedString: parsed)
        let full = text.fullRange

        // 1) 行内意图 → 字体字形（先收集再改，避免枚举期间突变）。
        var intentRuns: [(NSRange, InlinePresentationIntent)] = []
        text.enumerateAttribute(.inlinePresentationIntent, in: full, options: []) { value, range, _ in
            if let intent = value as? InlinePresentationIntent {
                intentRuns.append((range, intent))
            } else if let raw = value as? Int {
                intentRuns.append((range, InlinePresentationIntent(rawValue: UInt(raw))))
            }
        }
        for (range, intent) in intentRuns {
            var font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? base
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            text.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            text.removeAttribute(.inlinePresentationIntent, range: range)
        }

        // 2) 无字体属性的区段补基础字体。
        var bareRanges: [NSRange] = []
        text.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { bareRanges.append(range) }
        }
        for range in bareRanges {
            text.addAttribute(.font, value: base, range: range)
        }
        return text
    }

    // MARK: - 字体工具

    private static func transformFonts(
        in text: NSMutableAttributedString,
        size: CGFloat? = nil,
        _ transform: (NSFont) -> NSFont
    ) {
        let full = text.fullRange
        var replacements: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            var font = (value as? NSFont) ?? NSFont.systemFont(ofSize: size ?? NSFont.systemFontSize)
            font = transform(font)
            if let size, font.pointSize != size {
                font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            }
            replacements.append((range, font))
        }
        for (range, font) in replacements {
            text.addAttribute(.font, value: font, range: range)
        }
    }

    private static func headingFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 16
        default: return 14
        }
    }

    private static var baseFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }

    /// 块级段后间距（块间一个换行 + 6pt 间距，近似原 SwiftUI 块渲染 spacing: 8）。
    /// 计算属性（同 baseFont）：NSParagraphStyle 非 Sendable，static let 过不了严格并发检查。
    private static var blockSpacingStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        return style
    }

    /// 列表项间距（项内较块间更紧凑）。
    private static var itemSpacingStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        return style
    }

    /// 引用块：缩进 + 段后间距。
    private static var quoteStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.firstLineHeadIndent = 16
        style.headIndent = 16
        return style
    }
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
