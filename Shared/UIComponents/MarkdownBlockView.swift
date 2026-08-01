import SwiftUI

/// Markdown 块级渲染（任务 M2-007/008，ADR-002）：把 ``MarkdownBlock`` 数组渲染为 SwiftUI 视图。
///
/// 约定：所有块均保留 `.textSelection(.enabled)`（§6.5 第 4 条）；
/// 任何行内 markdown 解析失败回退纯文本 ``Text``，不丢内容。
public struct MarkdownBlockView: View {

    public let blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, markdown):
            markdownText(markdown)
                .font(headingFont(level))
                .textSelection(.enabled)
        case let .paragraph(markdown):
            markdownText(markdown)
                .textSelection(.enabled)
        case let .blockQuote(markdown):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.gray.opacity(0.4))
                    .frame(width: 3)
                markdownText(markdown)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
            }
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                        markdownText(item)
                            .textSelection(.enabled)
                    }
                }
            }
        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)
        case .thematicBreak:
            Divider()
        case let .plain(text):
            Text(text)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .body.weight(.semibold)
        }
    }

    /// 行内 markdown → Text；解析失败回退纯文本（§6.5 第 7 条）。
    private func markdownText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(markdown)
    }
}

/// 代码块视图（任务 M2-008）：语言小标 + 高亮代码，等宽、可选中、横向滚动不换行。
public struct CodeBlockView: View {

    public let language: String?
    public let code: String

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(AttributedString(CodeHighlighter.shared.highlighted(code, language: language)))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
