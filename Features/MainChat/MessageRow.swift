import SwiftUI
import Core
import Shared

/// 单条消息行：user 右对齐着色 / assistant 左对齐；流式光标；终态徽标与重试。
/// （自 MainChatView.swift 抽出为模块内共享组件，M3-007 支线消息流复用同款渲染。）
struct MessageRow: View {

    let message: Message
    let onRetry: () -> Void
    /// 选区变化回调（M3-001）：assistant 稳定态正文与工具结果区的选区快照。
    let onSelectionChange: (SelectionSnapshot?) -> Void
    /// 引文回跳高亮（M3-010）：true 时整行背景短暂高亮（渐隐由调用方控制翻转时机）。
    /// 精确到选中范围的高亮（把 range 设进 NSTextView selection）为 stretch，未做。
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.kind != .notice {
                Text(roleTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
            statusBadge
        }
        // 回跳高亮：只改背景，不触碰 NSTextView 选区（高亮后不改写用户选区，M3-010）。
        .background(isHighlighted ? Color.yellow.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeOut(duration: 0.6), value: isHighlighted)
    }

    /// 工具调用渲染为折叠卡片（M2-002）；metadata 解码失败回退纯文本，不崩溃。
    /// 权限拒绝 notice（M2-006）渲染为居中警示小字，不走气泡。
    @ViewBuilder
    private var content: some View {
        if message.kind == .toolCall, let record = message.toolCallRecord() {
            ToolCallCard(
                title: record.title ?? "工具调用",
                status: record.status.rawValue,
                kind: record.kind,
                paths: record.paths ?? [],
                content: record.contentText ?? message.content,
                messageID: message.id,
                onSelectionChange: onSelectionChange
            )
        } else if message.kind == .notice {
            Label(message.content, systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            bodyContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 消息正文（M2-007/M3-001）：assistant 稳定态走 Markdown → NSAttributedString →
    /// 只读 NSTextView（``SelectableMessageText``，可回报选区快照）；
    /// 流式中与 user 消息保持纯文本 `.textSelection`（流式先保可见，§6.5 第 1 条），
    /// 两套选择系统相互独立、不会互覆。
    @ViewBuilder
    private var bodyContent: some View {
        if message.role == .assistant && message.status != .streaming {
            SelectableMessageText(
                messageID: message.id,
                attributedText: MarkdownAttributedRenderer.render(MarkdownBlockParser.parse(message.content)),
                onSelectionChange: onSelectionChange
            )
        } else {
            Text(displayContent)
                .textSelection(.enabled)
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user: return "我"
        case .assistant: return "Kimi"
        case .system: return "系统"
        }
    }

    /// 流式中追加光标；空占位显示「正在生成…」。
    private var displayContent: String {
        if message.status == .streaming {
            return message.content.isEmpty ? "正在生成…" : message.content + " ▍"
        }
        return message.content
    }

    private var background: some ShapeStyle {
        switch message.role {
        case .user: return AnyShapeStyle(.blue.opacity(0.12))
        default: return AnyShapeStyle(.gray.opacity(0.08))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch message.status {
        case .interrupted:
            Label("已中断（内容不完整）", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            HStack(spacing: 8) {
                Label("生成失败", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重试", action: onRetry)
                    .font(.caption)
            }
        case .streaming, .completed:
            EmptyView()
        }
    }
}
