import Foundation
import Observation
import Core
import Shared

/// 右侧支线标签栏视图模型（任务 M3-007，流程文档 §7.7；嵌套交互 M3-009、
/// 引文回跳 M3-010、10 轮提示 M3-013 的可测逻辑均收口在本层）。
///
/// 职责边界：
/// - 支线列表来自 ``BranchRepository``（过滤 closed 与 UI 层关闭的标签）；
/// - 支线消息流订阅 ``ConversationStore/branchSnapshots``（按 branchID 路由，BR-17），
///   发送/重试走 ``ConversationStore`` 支线 API，不直接读写 Pipe；
/// - 创建编排交 ``BranchSessionCoordinator``（本层只订阅状态流驱动进度与自动切标签）；
/// - 合并交 ``BranchMergeService``（含「本地已保存未注入」中间态的恢复入口）；
/// - 「关闭标签」仅 UI 层（``hiddenBranchIDs`` 内存集合），支线上下文与数据常驻（BR-15 语义）。
@Observable
@MainActor
public final class BranchPanelViewModel {

    /// 进行中的支线创建（requestID 级别；ready 后移除并转为正式标签）。
    public struct PendingCreation: Equatable, Sendable {
        public let request: BranchCreationRequest
        public var state: BranchCreationState

        public var requestID: String { request.requestID }
    }

    /// 合并按钮结果状态映射（§7.8 UI 语义；中间态可恢复）。
    public enum MergeUIState: Equatable, Sendable {
        /// 未合并（按钮可用）。
        case idle
        /// 合并进行中。
        case merging
        /// 已回流并注入 ACP 主线程。
        case mergedInjected
        /// 中间态：本地已保存未注入（§7.8），可经 ``BranchPanelViewModel/retryInjection(branchID:)`` 恢复。
        case savedNotInjected(noteID: String)
        /// 合并失败（摘要失败等；库内零写入，可重试）。
        case failed(reason: String)
    }

    /// 支线内滚动请求（嵌套锚点回跳降级用；token 保证重复触发）。
    public struct ScrollRequest: Equatable, Sendable {
        public let token = UUID()
        public let messageID: String?

        public init(messageID: String?) {
            self.messageID = messageID
        }
    }

    // MARK: - 可观察状态

    /// 可见支线（status != closed 且未被 UI 层关闭），按创建时间升序。
    public private(set) var visibleBranches: [Branch] = []
    /// 当前激活标签（didSet 通知出口，供左侧树同步选中态）。
    public var activeBranchID: String? {
        didSet { onActiveBranchChanged?(activeBranchID) }
    }
    /// 当前活跃线程 id（主线快照驱动；测试可直接 internal 写入后调 ``refresh()``）。
    public internal(set) var threadID: String?
    /// 每支线消息流（快照订阅实时更新；上下文未打开的支线为启动时从库内读出的历史，BR-18）。
    public private(set) var branchMessages: [String: [Message]] = [:]
    /// 每支线阶段（发送禁用与流式展示用）。
    public private(set) var branchPhases: [String: ConversationPhase] = [:]
    /// 每支线发送失败提示（简版错误条；视图可关闭）。
    public var branchErrors: [String: String] = [:]
    /// 进行中的创建（进度展示 + 取消/重试入口）。
    public private(set) var pendingCreations: [PendingCreation] = []
    /// 每支线合并状态（按钮映射）。
    public private(set) var mergeStates: [String: MergeUIState] = [:]
    /// 每支线输入框文本。
    public var branchInputs: [String: String] = [:]
    /// 支线内当前选区（M3-009 嵌套追问入口；branchID → 选区快照）。
    public var branchSelections: [String: SelectionSnapshot] = [:]
    /// 支线内滚动请求（嵌套锚点回跳降级：切标签后滚动到锚点消息）。
    public private(set) var scrollRequests: [String: ScrollRequest] = [:]

    // MARK: - 嵌套追问编辑（M3-009）

    /// 嵌套追问的冻结选区（点击支线内「追问」瞬间固定，BR-04 同语义）。
    public private(set) var frozenNestedSelection: SelectionSnapshot?
    /// 嵌套追问的父支线 id（冻结时所属支线）。
    public private(set) var frozenNestedParentID: String?
    /// 嵌套问题编辑面板是否展开。
    public var isComposingNestedQuestion = false
    /// 嵌套追问输入框文本。
    public var nestedQuestionInput = ""

    // MARK: - 出口回调（App 层接线）

    /// 主线锚点回跳出口（App 层接线到 MainChatViewModel.handleAnchorJump）。
    public var onJumpToMainline: ((AnchorJump) -> Void)?
    /// 支线集合/状态变化出口（App 层接线到 ConversationTreeViewModel.refresh；M4-004）。
    public var onBranchesChanged: (() -> Void)?
    /// 激活标签变化出口（App 层接线到左侧树选中态同步；M4-004）。
    public var onActiveBranchChanged: ((String?) -> Void)?

    // MARK: - 依赖

    private let branches: BranchRepository
    private let threads: ThreadRepository
    private let messages: MessageRepository
    private let conversation: ConversationStore
    private let coordinator: BranchSessionCoordinator
    private let mergeService: BranchMergeService

    /// UI 层关闭的标签（仅内存；支线上下文与数据常驻，BR-15；重启后重新可见）。
    private var hiddenBranchIDs: Set<String> = []
    /// 从左侧树强制打开的 closed 支线（仅内存；TREE-04 已回流/已关闭节点仍可查看，不改 status）。
    private var forceOpenedIDs: Set<String> = []
    /// 10 轮提示「忽略」标记（内存，本轮会话不再提示；M3-013）。
    private var tenRoundDismissed: Set<String> = []

    private var threadObserverTask: Task<Void, Never>?
    private var snapshotTasks: [String: Task<Void, Never>] = [:]
    private var started = false

    public init(
        branches: BranchRepository,
        threads: ThreadRepository,
        messages: MessageRepository,
        conversation: ConversationStore,
        coordinator: BranchSessionCoordinator,
        mergeService: BranchMergeService
    ) {
        self.branches = branches
        self.threads = threads
        self.messages = messages
        self.conversation = conversation
        self.coordinator = coordinator
        self.mergeService = mergeService
    }

    // MARK: - 生命周期

    /// 面板是否有可见内容（窗口据此决定是否展示右栏）。
    public var hasVisibleContent: Bool {
        !visibleBranches.isEmpty || !pendingCreations.isEmpty
    }

    /// 启动：订阅主线快照跟踪活跃线程，线程变化时刷新支线列表（BR-18 重启恢复入口）。
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

    /// 停止（视图消失）：取消全部订阅 Task；支线上下文在 ConversationStore 常驻，不受影响。
    public func stop() {
        threadObserverTask?.cancel()
        threadObserverTask = nil
        for task in snapshotTasks.values { task.cancel() }
        snapshotTasks.removeAll()
        started = false
    }

    /// 刷新支线列表与历史消息（库内读取；实时更新由快照订阅覆盖）。
    public func refresh() {
        guard let threadID else {
            visibleBranches = []
            return
        }
        let all = (try? branches.listBranches(threadID: threadID)) ?? []
        visibleBranches = all.filter {
            ($0.status != .closed || forceOpenedIDs.contains($0.id)) && !hiddenBranchIDs.contains($0.id)
        }
        for branch in visibleBranches {
            // 上下文未打开的支线：从库内补历史（快照订阅 replay 为空快照，由 threadID 守卫跳过）。
            if let history = try? messages.messages(threadID: threadID, branchID: branch.id) {
                branchMessages[branch.id] = history
            }
            ensureSnapshotSubscription(branchID: branch.id)
            if mergeStates[branch.id] == nil, branch.status == .merged {
                // 重启后恢复已回流徽标（具体注入态以消息 metadata 为准，此处保守按已注入展示）。
                mergeStates[branch.id] = .mergedInjected
            }
        }
        if activeBranchID == nil || !visibleBranches.contains(where: { $0.id == activeBranchID }) {
            activeBranchID = visibleBranches.last?.id
        }
        onBranchesChanged?()
    }

    // MARK: - 标签切换与关闭

    /// 切换标签（§7.7：不改变左侧树结构；上下文未打开则顺带打开以支持继续对话）。
    public func select(branchID: String) {
        activeBranchID = branchID
        guard let branch = visibleBranches.first(where: { $0.id == branchID }),
              let projectRoot = threadProjectRoot(branch.threadID) else { return }
        Task { [conversation] in
            // 已有上下文直接复用（重读消息）；失败保守忽略，发送路径另有错误提示。
            _ = try? await conversation.openBranch(
                branchID: branchID, threadID: branch.threadID, projectRoot: projectRoot
            )
        }
    }

    /// 关闭标签（仅 UI 层隐藏；不删支线、不销毁上下文、不动 status，BR-15/§7.7）。
    /// 关父不毁子（M3-009）：子支线上下文在 ConversationStore 按 branchID 独立登记，
    /// 父标签隐藏不影响子支线数据与流式。
    public func closeTab(branchID: String) {
        hiddenBranchIDs.insert(branchID)
        forceOpenedIDs.remove(branchID)
        refresh()
    }

    /// 从左侧树打开支线（M4-004，TREE-04）：closed 支线经 forceOpenedIDs 临时可见
    /// （不改 status、不写库），hidden 标签解除隐藏，随后切到该标签。
    /// 面板尚未 start（threadID 未知，如重启后右栏未出现）时先按支线所属线程补位——
    /// 否则 refresh 早退会把 visibleBranches 清空，点击完全无反应。
    public func openFromTree(branchID: String) {
        if threadID == nil, let branch = try? branches.branch(id: branchID) {
            threadID = branch.threadID
        }
        hiddenBranchIDs.remove(branchID)
        forceOpenedIDs.insert(branchID)
        refresh()
        select(branchID: branchID)
    }

    // MARK: - 支线创建（追问出口，M3-003/M3-009）

    /// 发起支线创建：登记 pending → 订阅 coordinator 状态流驱动进度 →
    /// ready 后解析新支线行、刷新列表并自动切到该标签（§7.7）。
    public func startCreation(_ request: BranchCreationRequest) {
        guard !pendingCreations.contains(where: { $0.requestID == request.requestID }) else { return }
        pendingCreations.append(PendingCreation(request: request, state: .idle))
        Task { [weak self, coordinator] in
            let stream = await coordinator.startCreation(request)
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.updatePending(requestID: request.requestID, state: state)
                if state == .ready {
                    self.handleCreationReady(request)
                }
                // failed：流保持开启（retryCreation 后续推进经同一订阅回流），pending 保留供重试。
            }
        }
    }

    /// 重试创建（BR-07 显式重试；经 coordinator 复用已建行，不重复播种）。
    public func retryCreation(requestID: String) {
        guard pendingCreations.contains(where: { $0.requestID == requestID }) else { return }
        Task { [coordinator] in
            await coordinator.retryCreation(requestID: requestID)
        }
    }

    /// 取消创建（§7.3：sendingSeed 之前取消绝不发 prompt，零额度）。
    /// 从 pending 列表移除；状态流后续推进（failed=已取消）因无对应 pending 自动落空。
    public func cancelCreation(requestID: String) {
        Task { [coordinator] in
            await coordinator.cancelCreation(requestID: requestID)
        }
        pendingCreations.removeAll { $0.requestID == requestID }
    }

    // MARK: - 嵌套追问（M3-009）

    /// 支线内点击「追问」：冻结支线作用域选区（BR-04 同语义），展开嵌套编辑面板。
    public func beginNestedComposition(parentBranchID: String) {
        guard let selection = branchSelections[parentBranchID],
              let message = branchMessages[parentBranchID]?.first(where: { $0.id == selection.messageID })
        else { return }
        frozenNestedSelection = selection
        frozenNestedParentID = parentBranchID
        // 锚点纯文本与主线同源（assistant 渲染产物 / 其他消息 content），注释见 MainChatViewModel。
        nestedFrozenAnchorPlainText = MainChatViewModel.anchorPlainText(for: message)
        nestedQuestionInput = ""
        isComposingNestedQuestion = true
    }

    public func cancelNestedComposition() {
        frozenNestedSelection = nil
        frozenNestedParentID = nil
        nestedFrozenAnchorPlainText = nil
        nestedQuestionInput = ""
        isComposingNestedQuestion = false
    }

    /// 确认嵌套追问：请求带 parentBranchID=当前支线（锚点消息属于支线，锚点纯文本同源）。
    public func confirmNestedQuestion() {
        let question = nestedQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空问题不动作（UI 侧按钮已禁用，双保险），保持编辑面板与冻结快照。
        guard !question.isEmpty else { return }
        guard let frozen = frozenNestedSelection,
              let parentID = frozenNestedParentID,
              let anchorPlainText = nestedFrozenAnchorPlainText,
              let threadID else {
            cancelNestedComposition()
            return
        }
        let projectRoot = threadProjectRoot(threadID)
        guard let projectRoot else {
            cancelNestedComposition()
            return
        }
        let request = BranchCreationRequest(
            requestID: UUID().uuidString,
            threadID: threadID,
            parentBranchID: parentID,
            snapshot: frozen,
            anchorPlainText: anchorPlainText,
            userQuestion: question,
            projectRoot: projectRoot
        )
        cancelNestedComposition()
        startCreation(request)
    }

    /// 嵌套冻结的锚点纯文本（随选区同属一次冻结）。
    private var nestedFrozenAnchorPlainText: String?

    // MARK: - 支线对话

    public func sendBranch(branchID: String) {
        let text = (branchInputs[branchID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        branchInputs[branchID] = ""
        Task { [weak self, conversation] in
            do {
                try await conversation.sendBranchMessage(branchID: branchID, text: text)
            } catch {
                self?.branchErrors[branchID] = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    public func retryBranch(branchID: String) {
        Task { [weak self, conversation] in
            do {
                try await conversation.retryBranch(branchID: branchID)
            } catch {
                self?.branchErrors[branchID] = "重试失败：\(error.localizedDescription)"
            }
        }
    }

    /// 支线是否可发送（流式中禁发，store 内双保险）。
    public func canSend(branchID: String) -> Bool {
        let text = (branchInputs[branchID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && (branchPhases[branchID] ?? .idle).canSend
    }

    // MARK: - 合并回主线（§7.8）

    /// 合并回主线：结果映射到 ``MergeUIState``（含「本地已保存未注入」中间态）。
    public func merge(branchID: String) {
        mergeStates[branchID] = .merging
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mergeService.merge(branchID: branchID)
                switch result {
                case .merged(let noteID, let injected):
                    mergeStates[branchID] = injected ? .mergedInjected : .savedNotInjected(noteID: noteID)
                case .alreadyMerged(let noteID, let injected):
                    // 幂等重复点击：不产生重复笔记（BR-14），状态按注入结果刷新。
                    mergeStates[branchID] = injected ? .mergedInjected : .savedNotInjected(noteID: noteID)
                }
                refresh()
            } catch {
                mergeStates[branchID] = .failed(reason: String(describing: error))
            }
        }
    }

    /// 中间态恢复：重试注入 ACP 主线程（§7.8「已保存未注入」）。
    public func retryInjection(branchID: String) {
        guard case .savedNotInjected(let noteID) = mergeStates[branchID] else { return }
        mergeStates[branchID] = .merging
        Task { [weak self] in
            guard let self else { return }
            do {
                let injected = try await mergeService.retryInjection(noteID: noteID)
                mergeStates[branchID] = injected ? .mergedInjected : .savedNotInjected(noteID: noteID)
            } catch {
                mergeStates[branchID] = .savedNotInjected(noteID: noteID)
                branchErrors[branchID] = "注入重试失败：\(String(describing: error))"
            }
        }
    }

    /// 合并并关闭（M3-013）：合并成功（含中间态，库内 status 已 merged）后流转 closed，
    /// 标签随 refresh 过滤移除；合并失败则不关闭。
    public func mergeAndClose(branchID: String) {
        merge(branchID: branchID)
        Task { [weak self] in
            guard let self else { return }
            // 等 merge 的 Task 先行落定状态（merge 内部亦是 Task，按序轮询合并终态）。
            while mergeStates[branchID] == .merging {
                try? await Task.sleep(for: .milliseconds(20))
            }
            switch mergeStates[branchID] {
            case .mergedInjected, .savedNotInjected:
                try? branches.updateStatus(branchID: branchID, status: .closed)
                refresh()
            default:
                break
            }
        }
    }

    // MARK: - 10 轮提示（M3-013，BR-16）

    /// round > 10（用户非 seed 消息数）且未忽略且支线仍 open 时显示提示。
    public func shouldShowTenRoundBanner(branchID: String) -> Bool {
        guard let branch = visibleBranches.first(where: { $0.id == branchID }),
              branch.status == .open,
              !tenRoundDismissed.contains(branchID) else { return false }
        return roundCount(branchID: branchID) > Self.tenRoundThreshold
    }

    /// 「忽略」：本轮会话不再提示（内存标记）。
    public func dismissTenRoundBanner(branchID: String) {
        tenRoundDismissed.insert(branchID)
    }

    // MARK: - 引文回跳（M3-010，BR-12）

    /// 点击锚点引文：主线锚点 → 解析后回调主对话滚动高亮；
    /// 嵌套锚点（在父支线消息流中）→ 降级为切到父支线标签 + 滚动到锚点消息
    /// （择简：精确范围高亮与跨支线 AnchorResolver 解析归 G3 stretch，注释说明）。
    public func jumpToAnchor(branchID: String) {
        guard let branch = visibleBranches.first(where: { $0.id == branchID }) else { return }
        if let parentID = branch.parentBranchID {
            select(branchID: parentID)
            scrollRequests[parentID] = ScrollRequest(messageID: branch.anchorMessageID)
            return
        }
        guard let anchorMessageID = branch.anchorMessageID,
              let anchorMessage = try? messages.messages(threadID: threadID ?? branch.threadID, branchID: nil)
                .first(where: { $0.id == anchorMessageID }) else { return }
        let plainText = MainChatViewModel.anchorPlainText(for: anchorMessage)
        let resolution = AnchorResolver.resolve(
            plainText: plainText,
            messageID: anchorMessageID,
            quote: branch.anchorQuote,
            start: branch.anchorStart,
            length: branch.anchorLength,
            contextHash: branch.anchorContextHash
        )
        onJumpToMainline?(AnchorJump(messageID: anchorMessageID, resolution: resolution))
    }

    // MARK: - 派生数据（可测纯逻辑）

    /// 轮数：快照中 role==user 且 kind==text 且非 seed 的消息数（M3-013）。
    public func roundCount(branchID: String) -> Int {
        Self.roundCount(messages: branchMessages[branchID] ?? [])
    }

    /// 标签标题：首个非 seed user 问题截 20 字，空则锚点引文占位（§7.7）。
    public func title(for branch: Branch) -> String {
        Self.title(for: branch, messages: branchMessages[branch.id] ?? [])
    }

    static let tenRoundThreshold = 10

    static func roundCount(messages: [Message]) -> Int {
        messages.filter { $0.role == .user && $0.kind == .text && !isSeed($0) }.count
    }

    static func title(for branch: Branch, messages: [Message]) -> String {
        if let question = messages.first(where: {
            $0.role == .user && $0.kind == .text && !isSeed($0)
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            return String(question.prefix(20))
        }
        let quote = branch.anchorQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.isEmpty ? "支线" : String(quote.prefix(20))
    }

    /// seed 识别（播种背景消息，metadata 含 seedContext/seed_context）：
    /// 与 ``BranchMergeService/isSeedMessage(_:)`` 同源，支线流中默认折叠为「背景已注入」。
    static func isSeed(_ message: Message) -> Bool {
        BranchMergeService.isSeedMessage(message)
    }

    /// 创建状态 → 进度文案（「组装背景/创建会话/播种…」）。
    static func creationProgressText(_ state: BranchCreationState) -> String {
        switch state {
        case .idle, .composingQuestion: return "准备中…"
        case .preparingContext: return "组装背景…"
        case .compressingContext: return "压缩背景…"
        case .creatingSession: return "创建会话…"
        case .sendingSeed: return "播种背景…"
        case .streaming: return "等待支线回答…"
        case .ready: return "就绪"
        case .failed(_, let reason): return "创建失败：\(reason)"
        }
    }

    // MARK: - 内部

    /// 线程 projectRoot 查询（嵌套追问/支线打开时的 cwd；查不到保守返回 nil）。
    private func threadProjectRoot(_ threadID: String) -> String? {
        try? threads.listThreads().first(where: { $0.id == threadID })?.projectRoot
    }

    private func ensureSnapshotSubscription(branchID: String) {
        guard snapshotTasks[branchID] == nil else { return }
        snapshotTasks[branchID] = Task { [weak self, conversation] in
            for await snapshot in await conversation.branchSnapshots(branchID: branchID) {
                guard let self, !Task.isCancelled else { return }
                // 上下文未打开的支线 replay 为空白快照（threadID 为 nil）：
                // 跳过，保留 refresh 从库内读出的历史，避免清空。
                guard snapshot.threadID != nil else { continue }
                branchMessages[branchID] = snapshot.messages
                branchPhases[branchID] = snapshot.phase
            }
        }
    }

    private func updatePending(requestID: String, state: BranchCreationState) {
        guard let index = pendingCreations.firstIndex(where: { $0.requestID == requestID }) else { return }
        pendingCreations[index].state = state
    }

    /// ready 后定位新建支线行（branches 行不带 requestID：
    /// 按锚点消息 + 引文 + seed_context 含追问文本匹配，取最新一行；兜底取全表最新）。
    private func handleCreationReady(_ request: BranchCreationRequest) {
        pendingCreations.removeAll { $0.requestID == request.requestID }
        let all = (try? branches.listBranches(threadID: request.threadID)) ?? []
        let matched = all.filter {
            $0.anchorMessageID == request.snapshot.messageID
                && $0.anchorQuote == request.snapshot.quote
                && ($0.seedContext?.contains(request.userQuestion) ?? false)
        }.last
        let created = matched ?? all.last
        refresh()
        if let created {
            select(branchID: created.id)
        }
    }
}
