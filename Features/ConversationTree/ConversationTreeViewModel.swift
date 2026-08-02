import Foundation
import Observation
import Core
import Shared

/// 左侧卡片式对话树视图模型（M4-002/003/004，流程文档 §8.2）。
///
/// 职责边界：
/// - 树结构来自 ``BranchTreeBuilder`` 纯函数构建（数据只读 ``BranchRepository``，
///   不依赖当前打开的右侧标签；§8.2 实现要求）；
/// - 折叠只影响 ``visibleNodes`` 派生（UI 层内存集合），不改数据、不写库（TREE-05）；
/// - 树展示**全部**支线（含 merged/closed；关闭标签不删支线，TREE-04 仍可查看）；
/// - 刷新时机：线程切换（订阅主线快照）+ 面板 ``BranchPanelViewModel/onBranchesChanged``
///   出口回调；支线集合无变化时跳过重建，流式 delta 不触发整树重建（M4-001 要求）。
@Observable
@MainActor
public final class ConversationTreeViewModel {

    /// 节点卡片信息（M4-003）：首问摘要/轮数/最近活动/状态/已回流/孤儿标记。
    public struct CardInfo: Equatable, Sendable {
        /// 首条非 seed user 问题截断；空则锚点引文占位（§8.2 空摘要规则）。
        public let title: String
        /// 轮数（非 seed user 消息数，与右侧面板同源）。
        public let roundCount: Int
        /// 最近活动时间（DEC-09 排序字段，即 branch.updated_at）。
        public let lastActivity: Date
        public let status: BranchStatus
        /// 「已回流」标记（merge_note_id 存在；含 merged 与 merged 后 closed）。
        public let mergedBack: Bool
        /// 锚点父引用异常（孤儿/成环节点），卡片给警示标记。
        public let isOrphan: Bool
    }

    // MARK: - 可观察状态

    /// 当前线程 id（主线快照驱动；测试可直接 internal 写入后调 ``refresh()``）。
    public internal(set) var threadID: String?
    /// 当前线程标题（根节点卡片）。
    public private(set) var threadTitle: String = ""
    /// 完整树（含折叠节点的全部数据；折叠不影响这里）。
    public private(set) var tree: BranchTree = BranchTree(roots: [], issues: [])
    /// 每节点卡片信息（branchID → CardInfo）。
    public private(set) var cardInfos: [String: CardInfo] = [:]
    /// 折叠的节点 id（仅内存；TREE-05 数据不变）。
    public private(set) var collapsedIDs: Set<String> = []
    /// 当前选中支线（与右侧激活标签双向同步；nil = 未选中/主线）。
    public var selectedBranchID: String?

    // MARK: - 出口回调（App 层接线）

    /// 点击节点出口（App 层接线到 BranchPanelViewModel.openFromTree + 回跳；M4-004/005）。
    public var onSelectBranch: ((String) -> Void)?

    // MARK: - 依赖

    private let branches: BranchRepository
    private let threads: ThreadRepository
    private let messages: MessageRepository
    private let conversation: ConversationStore

    /// 上次构建用的支线集合（无变化跳过重建；流式 delta 不动 branches 行故天然防抖）。
    private var lastBranches: [Branch] = []
    private var threadObserverTask: Task<Void, Never>?
    private var started = false

    public init(
        branches: BranchRepository,
        threads: ThreadRepository,
        messages: MessageRepository,
        conversation: ConversationStore
    ) {
        self.branches = branches
        self.threads = threads
        self.messages = messages
        self.conversation = conversation
    }

    // MARK: - 生命周期

    /// 启动：订阅主线快照跟踪活跃线程，线程变化时刷新（与右侧面板同模式，BR-18 恢复入口）。
    public func start() {
        guard !started else { return }
        started = true
        threadObserverTask = Task { [weak self, conversation] in
            for await snapshot in await conversation.snapshots() {
                guard let self, !Task.isCancelled else { return }
                if snapshot.threadID != self.threadID {
                    self.threadID = snapshot.threadID
                    self.refresh()
                }
            }
        }
    }

    /// 停止（视图消失）：取消订阅 Task。
    public func stop() {
        threadObserverTask?.cancel()
        threadObserverTask = nil
        started = false
    }

    /// 刷新树与卡片信息（库内读取；支线集合无变化时跳过重建）。
    public func refresh() {
        guard let threadID else {
            tree = BranchTree(roots: [], issues: [])
            cardInfos = [:]
            threadTitle = ""
            lastBranches = []
            return
        }
        threadTitle = (try? threads.listThreads().first(where: { $0.id == threadID })?.title) ?? ""
        let all = (try? branches.listBranches(threadID: threadID)) ?? []
        guard all != lastBranches else { return }
        lastBranches = all
        tree = BranchTreeBuilder.build(branches: all)
        var infos: [String: CardInfo] = [:]
        for branch in all {
            let history = (try? messages.messages(threadID: threadID, branchID: branch.id)) ?? []
            let isOrphan = tree.flattened().first(where: { $0.id == branch.id })?.isOrphan ?? false
            infos[branch.id] = CardInfo(
                title: BranchPanelViewModel.title(for: branch, messages: history),
                roundCount: BranchPanelViewModel.roundCount(messages: history),
                lastActivity: branch.updatedAt,
                status: branch.status,
                mergedBack: branch.mergeNoteID != nil,
                isOrphan: isOrphan
            )
        }
        cardInfos = infos
    }

    // MARK: - 派生数据

    /// 可见节点（先序 + 折叠过滤；折叠节点的整棵子树隐藏但数据保留，TREE-05）。
    public var visibleNodes: [BranchTreeNode] {
        var result: [BranchTreeNode] = []
        func walk(_ node: BranchTreeNode) {
            result.append(node)
            guard !collapsedIDs.contains(node.id) else { return }
            for child in node.children { walk(child) }
        }
        for root in tree.roots { walk(root) }
        return result
    }

    // MARK: - 交互

    /// 折叠/展开切换（仅 UI 层；不改数据）。
    public func toggleCollapse(_ branchID: String) {
        if collapsedIDs.contains(branchID) {
            collapsedIDs.remove(branchID)
        } else {
            collapsedIDs.insert(branchID)
        }
    }

    /// 点击节点：记录选中并通知出口（激活右侧标签 + 回跳锚点由 App 层编排，M4-004/005）。
    public func select(branchID: String) {
        selectedBranchID = branchID
        onSelectBranch?(branchID)
    }
}
