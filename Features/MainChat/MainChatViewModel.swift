import Foundation
import Observation
import Core
import Shared

/// 主对话视图模型（任务 M1-012）：绑定 ``ConversationStore``，向视图暴露快照与操作。
///
/// 核心约束：UI 不直接读写 Pipe、不接触 ACP SDK 类型——全部经 ConversationStore。
@Observable
@MainActor
public final class MainChatViewModel {

    /// 当前线程消息（按 sequence 排序，含流式占位）。
    public private(set) var messages: [Message] = []
    /// 主对话状态机阶段。
    public private(set) var phase: ConversationPhase = .idle
    /// 输入框文本。
    public var input: String = ""
    /// 简版错误条（三态引导页归 M1-013）。
    public var errorBanner: String?
    /// 当前有效选区快照（任务 M3-001 临时入口）：assistant 稳定态消息/工具结果的
    /// SelectableMessageText 选区变化时写入；nil 表示无有效选区。
    /// 「追问」浮动按钮 UI 归 M3-003——届时点击追问即冻结该 snapshot 进入支线创建流程。
    public var currentSelection: SelectionSnapshot?

    private let store: ConversationStore
    /// B-M1 临时方案：新线程的 project_root 取进程工作目录（M4-007 再提供选择入口）。
    private let projectRoot: String
    private var snapshotTask: Task<Void, Never>?

    public init(store: ConversationStore, projectRoot: String) {
        self.store = store
        self.projectRoot = projectRoot
    }

    /// 是否可发送（流式中禁发，双保险之一；store 内同样拦截）。
    public var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase.canSend
    }

    /// 启动：订阅快照 + 打开最近线程（无则新建）。
    public func start() async {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self, store] in
            for await snapshot in await store.snapshots() {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
            }
        }
        do {
            try await store.openMostRecentOrCreate(projectRoot: projectRoot)
        } catch {
            // 登录失效（凭据文件在但已过期）在 session 创建时才暴露，保守识别后引导登录（G1-04）。
            errorBanner = StartupIssue.isAuthRelated(errorMessage: error.localizedDescription)
                ? "Kimi Code CLI 登录可能已失效：请在终端运行 kimi 并输入 /login 重新登录，然后重启应用。"
                : "会话初始化失败：\(error.localizedDescription)"
        }
    }

    public func send() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        Task {
            do {
                try await store.send(text: text)
            } catch {
                errorBanner = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    public func newConversation() {
        Task {
            do {
                try await store.newConversation(projectRoot: projectRoot)
            } catch {
                errorBanner = "新建对话失败：\(error.localizedDescription)"
            }
        }
    }

    /// 显式重试（产生新请求，§5.7）。
    public func retry() {
        Task {
            do {
                try await store.retry()
            } catch {
                errorBanner = "重试失败：\(error.localizedDescription)"
            }
        }
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        messages = snapshot.messages
        phase = snapshot.phase
    }
}
