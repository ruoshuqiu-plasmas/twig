import Foundation
import Observation
import Core
import Shared

/// 主线程列表视图模型（M4-007，DEC-10 第一阶段操作集合：
/// 创建/列表/切换/独立 project_root/最近活动排序/恢复选中/重命名；
/// 删除/归档/跨线程移动/合并不在本阶段）。
///
/// 职责边界：
/// - 列表数据来自 ``ThreadRepository/listThreads()``（库内已按 updated_at 最近活动排序）；
/// - 切换/新建经 ``ConversationStore``（session 创建与上下文激活归 store，本层不碰 ACP）；
/// - 重命名直连 ``ThreadRepository/renameThread``（纯数据操作，不需要 session 参与）；
/// - 活跃线程 id 由主线快照驱动同步（与支线面板/对话树同一订阅模式）。
@Observable
@MainActor
public final class ThreadListViewModel {

    // MARK: - 可观察状态

    /// 全部线程（最近活动降序）。
    public private(set) var threads: [ConversationThread] = []
    /// 当前活跃线程 id（快照驱动；测试可直接 internal 写入）。
    public internal(set) var activeThreadID: String?
    /// 正在就地重命名的线程 id（非空时该行显示编辑框）。
    public var renamingThreadID: String?
    /// 重命名编辑框草稿。
    public var renameDraft = ""
    /// 简版错误条。
    public var errorBanner: String?

    // MARK: - 依赖

    private let threadRepo: ThreadRepository
    private let store: ConversationStore
    private var snapshotTask: Task<Void, Never>?
    private var started = false

    public init(threads: ThreadRepository, store: ConversationStore) {
        self.threadRepo = threads
        self.store = store
    }

    // MARK: - 生命周期

    /// 启动：订阅主线快照同步活跃线程（切换后高亮随动），并刷新列表。
    public func start() {
        guard !started else { return }
        started = true
        snapshotTask = Task { [weak self, store] in
            for await snapshot in await store.snapshots() {
                guard let self, !Task.isCancelled else { return }
                if snapshot.threadID != self.activeThreadID {
                    self.activeThreadID = snapshot.threadID
                    // 切换后刷新：激活的线程 updated_at 可能已变（如自动标题生成）。
                    self.refresh()
                }
            }
        }
        refresh()
    }

    public func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        started = false
    }

    /// 刷新线程列表（库内读取，最近活动降序）。
    public func refresh() {
        threads = (try? threadRepo.listThreads()) ?? []
    }

    // MARK: - 操作（DEC-10 集合）

    /// 切换线程（各自 project_root/session/消息与支线树由 store 保障，THREAD-01/03）。
    public func switchTo(threadID: String) {
        guard threadID != activeThreadID else { return }
        Task { [weak self, store] in
            do {
                try await store.switchToThread(id: threadID)
            } catch {
                self?.errorBanner = "切换线程失败：\(error.localizedDescription)"
            }
        }
    }

    /// 创建线程并激活（标题可空 = 默认标题，首条问题自动生成；project_root 由视图层选取）。
    public func createThread(title: String?, projectRoot: String) {
        Task { [weak self, store] in
            do {
                try await store.newConversation(title: title, projectRoot: projectRoot)
                self?.refresh()
            } catch {
                self?.errorBanner = "新建对话失败：\(error.localizedDescription)"
            }
        }
    }

    /// 进入就地重命名。
    public func beginRename(threadID: String) {
        renamingThreadID = threadID
        renameDraft = threads.first(where: { $0.id == threadID })?.title ?? ""
    }

    /// 取消重命名。
    public func cancelRename() {
        renamingThreadID = nil
        renameDraft = ""
    }

    /// 提交重命名（空草稿视为取消；重命名不触碰 updated_at，不影响最近活动排序）。
    public func commitRename() {
        guard let threadID = renamingThreadID else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingThreadID = nil
        renameDraft = ""
        guard !title.isEmpty else { return }
        do {
            try threadRepo.renameThread(id: threadID, title: title)
            refresh()
        } catch {
            errorBanner = "重命名失败：\(error.localizedDescription)"
        }
    }
}
