import SwiftUI
import Core
import Shared

/// 左侧卡片式对话树视图（M4-002/003，流程文档 §8.2）。
/// 根 = 主线程卡片；支线按 parent_branch_id 缩进挂接（``BranchTreeNode/depth``）。
/// 折叠只隐藏子树（ViewModel 内存集合），不改数据（TREE-05）。
public struct ConversationTreeView: View {

    let viewModel: ConversationTreeViewModel

    public init(viewModel: ConversationTreeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            rootCard
            Divider()
            if viewModel.visibleNodes.isEmpty {
                Spacer()
                Text("暂无支线\n选中主线回答中的文字即可追问")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.visibleNodes, id: \.id) { node in
                            nodeCard(node)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - 根节点（主线程）

    private var rootCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text(viewModel.threadTitle.isEmpty ? "主线程" : viewModel.threadTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
    }

    // MARK: - 支线节点卡片（M4-003）

    private func nodeCard(_ node: BranchTreeNode) -> some View {
        let info = viewModel.cardInfos[node.id]
        let isSelected = viewModel.selectedBranchID == node.id
        return HStack(spacing: 0) {
            // 缩进（TREE-02：层级 = depth * 14pt）。
            Color.clear.frame(width: CGFloat(node.depth) * 14)
            // 折叠 chevron（仅有子节点时；TREE-05 折叠只隐藏）。
            if node.children.isEmpty {
                Color.clear.frame(width: 16)
            } else {
                Button {
                    viewModel.toggleCollapse(node.id)
                } label: {
                    Image(systemName: viewModel.collapsedIDs.contains(node.id)
                          ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(info?.title ?? node.branch.anchorQuote)
                        .font(.callout)
                        .lineLimit(2)
                    if node.isOrphan {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("锚点父引用异常，已挂到根节点")
                    }
                }
                HStack(spacing: 6) {
                    statusBadge(node.branch.status)
                    if info?.mergedBack == true {
                        Text("已回流")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text("\(info?.roundCount ?? 0) 轮")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let lastActivity = info?.lastActivity {
                        Text(lastActivity, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.select(branchID: node.id) }
    }

    private func statusBadge(_ status: BranchStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .open: return ("open", .blue)
            case .merged: return ("merged", .green)
            case .closed: return ("closed", .gray)
            }
        }()
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
