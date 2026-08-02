import SwiftUI
import Core
import Shared

/// 右侧支线标签栏（任务 M3-007，流程文档 §7.7）：标签页条 + 锚点引文回跳 +
/// 支线消息流 + 输入框 + 合并回主线 + 10 轮提示；嵌套追问（M3-009）入口在支线流内。
///
/// 布局/交互细节（NSTextView 坐标、滚动跟随、动画观感）归 G3 手工冒烟清单，单测只覆盖
/// ``BranchPanelViewModel`` 可测逻辑。
public struct BranchPanelView: View {

    @State private var viewModel: BranchPanelViewModel
    /// seed 消息「背景已注入」展开标记（视图态，按消息 id）。
    @State private var expandedSeedIDs: Set<String> = []

    public init(viewModel: BranchPanelViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingCreations.isEmpty {
                pendingSection
                Divider()
            }
            tabBar
            Divider()
            if let branch = activeBranch {
                branchContent(branch)
            } else {
                Text("创建中的支线就绪后将在此打开")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var activeBranch: Branch? {
        viewModel.visibleBranches.first(where: { $0.id == viewModel.activeBranchID })
    }

    // MARK: - 创建进度（「组装背景/创建会话/播种…」）

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.pendingCreations, id: \.requestID) { pending in
                HStack(spacing: 8) {
                    if case .failed(let retryable, _) = pending.state {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(BranchPanelViewModel.creationProgressText(pending.state))
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        if retryable {
                            Button("重试") { viewModel.retryCreation(requestID: pending.requestID) }
                                .font(.caption)
                        }
                        Button("关闭") { viewModel.cancelCreation(requestID: pending.requestID) }
                            .font(.caption)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text(BranchPanelViewModel.creationProgressText(pending.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pending.request.userQuestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        // §7.3：sendingSeed 之前取消零额度。
                        Button("取消") { viewModel.cancelCreation(requestID: pending.requestID) }
                            .font(.caption)
                    }
                }
            }
        }
        .padding(8)
        .background(.blue.opacity(0.06))
    }

    // MARK: - 标签页条（标题 + 状态徽标 + 关闭）

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.visibleBranches, id: \.id) { branch in
                    tabItem(branch)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func tabItem(_ branch: Branch) -> some View {
        let isActive = branch.id == viewModel.activeBranchID
        return HStack(spacing: 4) {
            statusDot(branch.status)
            Text(viewModel.title(for: branch))
                .lineLimit(1)
            Button {
                // 仅 UI 层关闭：支线上下文与数据常驻（BR-15）。
                viewModel.closeTab(branchID: branch.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08),
                    in: Capsule())
        .onTapGesture { viewModel.select(branchID: branch.id) }
    }

    /// open 蓝 / merged 绿 / closed 灰（closed 已被过滤，防御保留）。
    private func statusDot(_ status: BranchStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 6, height: 6)
    }

    private func statusColor(_ status: BranchStatus) -> Color {
        switch status {
        case .open: return .blue
        case .merged: return .green
        case .closed: return .gray
        }
    }

    // MARK: - 支线内容

    @ViewBuilder
    private func branchContent(_ branch: Branch) -> some View {
        // 锚点引文（可点击回跳，M3-010）。
        Button {
            viewModel.jumpToAnchor(branchID: branch.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.caption2)
                Text(branch.anchorQuote)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.06))
        }
        .buttonStyle(.plain)

        if viewModel.shouldShowTenRoundBanner(branchID: branch.id) {
            tenRoundBanner(branch)
        }

        messageList(branch)

        if let error = viewModel.branchErrors[branch.id] {
            HStack {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("关闭") { viewModel.branchErrors[branch.id] = nil }
                    .font(.caption)
            }
            .padding(.horizontal, 8)
        }

        mergeSection(branch)
        Divider()

        // 嵌套追问（M3-009）：支线内选区 → 追问入口/编辑面板。
        if viewModel.isComposingNestedQuestion, viewModel.frozenNestedParentID == branch.id {
            nestedComposePanel
        } else if viewModel.branchSelections[branch.id] != nil {
            HStack {
                Spacer()
                Button {
                    viewModel.beginNestedComposition(parentBranchID: branch.id)
                } label: {
                    Label("追问", systemImage: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        inputArea(branch)
    }

    /// 10 轮提示（M3-013，BR-16）。
    private func tenRoundBanner(_ branch: Branch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
            Text("支线已超过 10 轮，建议合并回主线并关闭")
                .font(.caption)
            Spacer()
            Button("合并并关闭") { viewModel.mergeAndClose(branchID: branch.id) }
                .font(.caption)
            Button("忽略") { viewModel.dismissTenRoundBanner(branchID: branch.id) }
                .font(.caption)
        }
        .padding(8)
        .background(.orange.opacity(0.12))
    }

    // MARK: - 支线消息流（复用 MessageRow 同款渲染；seed 默认折叠）

    private func messageList(_ branch: Branch) -> some View {
        let messages = viewModel.branchMessages[branch.id] ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages, id: \.id) { message in
                        if BranchPanelViewModel.isSeed(message) {
                            seedRow(message)
                        } else {
                            MessageRow(
                                message: message,
                                onRetry: { viewModel.retryBranch(branchID: branch.id) },
                                onSelectionChange: { viewModel.branchSelections[branch.id] = $0 }
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.scrollRequests[branch.id]) { _, request in
                // 嵌套锚点回跳（降级）：切标签后滚动到锚点消息。
                if let messageID = request?.messageID {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(messageID, anchor: .center)
                    }
                }
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// seed 消息折叠行：「背景已注入」，点击展开原文。
    private func seedRow(_ message: Message) -> some View {
        let expanded = expandedSeedIDs.contains(message.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded {
                    expandedSeedIDs.remove(message.id)
                } else {
                    expandedSeedIDs.insert(message.id)
                }
            } label: {
                Label("背景已注入", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 合并回主线（§7.8 结果状态映射）

    @ViewBuilder
    private func mergeSection(_ branch: Branch) -> some View {
        let state = viewModel.mergeStates[branch.id] ?? (branch.status == .merged ? .mergedInjected : .idle)
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Button("合并回主线") { viewModel.merge(branchID: branch.id) }
                    .font(.caption)
                    .disabled(branch.status != .open)
            case .merging:
                ProgressView()
                    .controlSize(.small)
                Text("正在合并…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .mergedInjected:
                Label("已回流主线", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .savedNotInjected:
                // §7.8 中间态：本地已保存未注入，可恢复。
                Label("已保存未注入", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("重试注入") { viewModel.retryInjection(branchID: branch.id) }
                    .font(.caption)
            case .failed(let reason):
                Label("合并失败：\(reason)", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("重试") { viewModel.merge(branchID: branch.id) }
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 嵌套追问编辑面板（M3-009）

    private var nestedComposePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = viewModel.frozenNestedSelection?.quote {
                Text(quote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            TextEditor(text: $viewModel.nestedQuestionInput)
                .font(.callout)
                .frame(minHeight: 40, maxHeight: 80)
            HStack {
                Spacer()
                Button("取消") { viewModel.cancelNestedComposition() }
                Button("创建嵌套支线") { viewModel.confirmNestedQuestion() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.nestedQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - 输入区

    private func inputArea(_ branch: Branch) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: Binding(
                get: { viewModel.branchInputs[branch.id] ?? "" },
                set: { viewModel.branchInputs[branch.id] = $0 }
            ))
            .font(.callout)
            .frame(minHeight: 36, maxHeight: 100)
            Button("发送") { viewModel.sendBranch(branchID: branch.id) }
                .disabled(!viewModel.canSend(branchID: branch.id))
        }
        .padding(12)
    }
}
