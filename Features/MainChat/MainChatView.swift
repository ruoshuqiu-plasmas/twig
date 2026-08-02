import SwiftUI
import Core
import Shared

/// 主对话界面（任务 M1-012）：消息列表 + 流式渲染 + 输入区。
///
/// B-M3 起追加：选中文字后的「追问」浮动入口与问题编辑面板（M3-003）、
/// 引文回跳的滚动与高亮（M3-010）。消息行渲染抽为模块内共享的 ``MessageRow``（M3-007 复用）。
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
            if let recovery = viewModel.recoveryBanner {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("知道了") { viewModel.recoveryBanner = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.gray.opacity(0.08))
            }
            messageList
            if viewModel.isComposingBranchQuestion {
                Divider()
                branchComposePanel
            }
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
                        MessageRow(
                            message: message,
                            onRetry: { viewModel.retry() },
                            onSelectionChange: { viewModel.currentSelection = $0 },
                            isHighlighted: viewModel.highlightedMessageID == message.id
                        )
                        .id(message.id)
                    }
                }
                .padding()
            }
            // 追问浮动入口（M3-003）取舍：贴在选区附近需要从 SelectableMessageText
            // 透出 firstRect 回调并换算 SwiftUI 坐标，改动跨 Shared 组件且要处理滚动跟随，
            // 成本偏高；择简为固定在对话区右下角的浮动胶囊按钮。
            // （候选改进：firstRect 贴选区浮动——记工程笔记候选，G3 后再评估。）
            .overlay(alignment: .bottomTrailing) {
                if viewModel.currentSelection != nil && !viewModel.isComposingBranchQuestion {
                    Button {
                        viewModel.beginBranchComposition()
                    } label: {
                        Label("追问", systemImage: "text.bubble")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .padding(16)
                }
            }
            .onChange(of: viewModel.anchorJump) { _, jump in
                // 引文回跳（M3-010）：滚动到锚点消息；高亮由 highlightedMessageID 驱动。
                if let jump {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(jump.messageID, anchor: .center)
                    }
                }
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

    // MARK: - 追问编辑面板（M3-003）

    /// 引文预览 + 多行输入 + 确认/取消。确认后请求交支线面板编排，本面板即关闭。
    private var branchComposePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = viewModel.frozenSelection?.quote {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            TextEditor(text: $viewModel.branchQuestionInput)
                .font(.body)
                .frame(minHeight: 48, maxHeight: 100)
            HStack {
                Spacer()
                Button("取消") { viewModel.cancelBranchComposition() }
                Button("创建支线") { viewModel.confirmBranchQuestion() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.branchQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.bar)
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
