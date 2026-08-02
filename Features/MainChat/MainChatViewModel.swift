import Foundation
import Observation
import Core
import Shared

/// 引文回跳请求（M3-010）：右侧支线栏点击锚点引文后，主对话滚动到锚点消息并短暂高亮。
/// `token` 保证同一消息连续两次回跳也能触发 SwiftUI onChange。
public struct AnchorJump: Equatable, Sendable {
    public let token: UUID
    /// 锚点消息 id（主对话 ScrollViewReader 滚动目标）。
    public let messageID: String
    /// 锚点解析结果（ADR-003）。当前 UI 只按消息整体高亮——
    /// exact 的精确范围高亮（回设 NSTextView selection）为 stretch，未做。
    public let resolution: AnchorResolution

    public init(messageID: String, resolution: AnchorResolution) {
        self.token = UUID()
        self.messageID = messageID
        self.resolution = resolution
    }
}

/// 主对话视图模型（任务 M1-012）：绑定 ``ConversationStore``，向视图暴露快照与操作。
///
/// 核心约束：UI 不直接读写 Pipe、不接触 ACP SDK 类型——全部经 ConversationStore。
@Observable
@MainActor
public final class MainChatViewModel {

    /// 当前线程消息（按 sequence 排序，含流式占位）。
    /// setter 为 internal：ViewModel 单测（@testable）直接播种消息。
    public internal(set) var messages: [Message] = []
    /// 主对话状态机阶段。
    public private(set) var phase: ConversationPhase = .idle
    /// 当前活跃线程 id（快照驱动；追问请求组装用）。setter internal 供测试。
    public internal(set) var threadID: String?
    /// 输入框文本。
    public var input: String = ""
    /// 简版错误条（三态引导页归 M1-013）。
    public var errorBanner: String?
    /// 当前有效选区快照（任务 M3-001）：assistant 稳定态消息/工具结果的
    /// SelectableMessageText 选区变化时写入；nil 表示无有效选区。
    public var currentSelection: SelectionSnapshot?

    // MARK: - 追问入口（M3-003）

    /// 冻结的选区快照（点击「追问」瞬间固定，BR-04：此后用户改选区不影响本次追问）。
    public private(set) var frozenSelection: SelectionSnapshot?
    /// 冻结时一并固定的锚点消息渲染纯文本（坐标换算与上下文指纹基准，随选区同属一次冻结）。
    public private(set) var frozenAnchorPlainText: String?
    /// 问题编辑面板是否展开。
    public var isComposingBranchQuestion = false
    /// 追问输入框文本。
    public var branchQuestionInput = ""
    /// 追问请求出口（App 层接线到 BranchPanelViewModel.startCreation；
    /// 创建进度/完成切换均由支线面板负责，本 VM 不订阅创建状态流）。
    public var onRequestBranchCreation: ((BranchCreationRequest) -> Void)?

    // MARK: - 引文回跳（M3-010）

    /// 最近一次回跳请求（视图 onChange 滚动；token 保证重复回跳可触发）。
    public private(set) var anchorJump: AnchorJump?
    /// 正在高亮的消息 id（短暂停留后自动清除，渐隐由 MessageRow 动画承担）。
    public private(set) var highlightedMessageID: String?
    /// 高亮停留时长（1.2s，规格 1~1.5s 区间内取值）。
    static let highlightDuration: Duration = .milliseconds(1200)

    private let store: ConversationStore
    /// B-M1 临时方案：新线程的 project_root 取进程工作目录（M4-007 再提供选择入口）。
    private let projectRoot: String
    private var snapshotTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

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

    // MARK: - 追问入口（M3-003）

    /// 点击「追问」：冻结当前选区快照与锚点纯文本（BR-04），展开问题编辑面板。
    /// 无有效选区或锚点消息已不在列表中时保守忽略。
    public func beginBranchComposition() {
        guard let selection = currentSelection,
              let message = messages.first(where: { $0.id == selection.messageID }) else { return }
        frozenSelection = selection
        frozenAnchorPlainText = Self.anchorPlainText(for: message)
        branchQuestionInput = ""
        isComposingBranchQuestion = true
    }

    /// 取消追问：丢弃冻结快照，未发 prompt 零额度（composingQuestion 阶段本就不耗额度）。
    public func cancelBranchComposition() {
        frozenSelection = nil
        frozenAnchorPlainText = nil
        branchQuestionInput = ""
        isComposingBranchQuestion = false
    }

    /// 确认追问：组装 ``BranchCreationRequest`` 交出口回调（支线面板接管创建编排与进度展示），
    /// 随后关闭编辑面板。创建取消/重试归支线面板（取消在 sendingSeed 之前不耗额度，§7.3）。
    public func confirmBranchQuestion() {
        let question = branchQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空问题不动作（UI 侧确认按钮已禁用，此为双保险），保持编辑面板与冻结快照。
        guard !question.isEmpty else { return }
        guard let frozen = frozenSelection,
              let anchorPlainText = frozenAnchorPlainText,
              let threadID else {
            // 冻结上下文缺失（如线程已切换）：不组装半成品请求，直接收起面板。
            cancelBranchComposition()
            return
        }
        let request = BranchCreationRequest(
            requestID: UUID().uuidString,
            threadID: threadID,
            parentBranchID: nil,
            snapshot: frozen,
            anchorPlainText: anchorPlainText,
            userQuestion: question,
            projectRoot: projectRoot
        )
        cancelBranchComposition()
        onRequestBranchCreation?(request)
    }

    /// 锚点消息 → 渲染后纯文本（M3-003；创建支线时 UTF-16→Character 换算与
    /// 上下文指纹的基准，须与 SelectableMessageText 内 NSTextView 的 string 一致）：
    /// - assistant 正文：Markdown 块级渲染产物的 `.string`（与渲染管线同源）；
    /// - 工具调用卡片等其他消息：content 本身。
    /// 注意（M3-001 遗留）：工具卡片折叠态传入 NSTextView 的是截断文本，
    /// 此时选区坐标相对截断文本；锚点消费侧以 quote 匹配为主（AnchorResolver 规则 2），
    /// 展开态坐标则与全文一致。
    public static func anchorPlainText(for message: Message) -> String {
        if message.role == .assistant && message.kind == .text {
            return MarkdownAttributedRenderer.render(MarkdownBlockParser.parse(message.content)).string
        }
        return message.content
    }

    // MARK: - 引文回跳（M3-010）

    /// 支线栏引文点击入口：滚动到锚点消息（视图消费 ``anchorJump``）+ 短暂高亮。
    /// 只改滚动与背景高亮，不触碰用户选区、不替换当前支线（§7.7 交互约束）。
    public func handleAnchorJump(_ jump: AnchorJump) {
        anchorJump = jump
        highlightedMessageID = jump.messageID
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            self?.highlightedMessageID = nil
        }
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        messages = snapshot.messages
        phase = snapshot.phase
        threadID = snapshot.threadID
    }
}
