import SwiftUI
import Core
import Shared

/// 主对话界面（任务 M1-012）：消息列表 + 流式渲染 + 输入区。
///
/// B-M1 渲染从简：纯文本 + `.textSelection(.enabled)`；
/// Markdown/高亮归 M2-007/008，NSTextView 选区归 B-M3。
public struct MainChatView: View {

    @State private var viewModel: MainChatViewModel
    @FocusState private var inputFocused: Bool

    public init(viewModel: MainChatViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = viewModel.errorBanner {
                errorBar(banner)
            }
            messageList
            Divider()
            inputArea
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button("新对话") { viewModel.newConversation() }
            }
        }
        .task { await viewModel.start() }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageRow(message: message, onRetry: { viewModel.retry() })
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $viewModel.input)
                .font(.body)
                .frame(minHeight: 40, maxHeight: 120)
                .focused($inputFocused)
            Button("发送") { viewModel.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canSend)
        }
        .padding(12)
    }

    // MARK: - 错误条（三态引导页归 M1-013，此处简版）

    private func errorBar(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
                .lineLimit(2)
            Spacer()
            Button("关闭") { viewModel.errorBanner = nil }
        }
        .padding(8)
        .background(.yellow.opacity(0.15))
    }
}

/// 单条消息行：user 右对齐着色 / assistant 左对齐；流式光标；终态徽标与重试。
private struct MessageRow: View {

    let message: Message
    let onRetry: () -> Void

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
                content: record.contentText ?? message.content
            )
        } else if message.kind == .notice {
            Label(message.content, systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text(displayContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
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
