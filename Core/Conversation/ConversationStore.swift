import Foundation
import Logging
import Shared

/// 主对话状态机阶段（流程文档 §5.7 原文路径）：
/// `idle → sending → streaming → completed`，分支 `failed` / `interrupted`。
public enum ConversationPhase: Sendable, Equatable {
    /// 空闲，可发送。
    case idle
    /// 已落库 user + 占位 assistant 消息，等待首个 delta。
    case sending
    /// 正在接收流式 delta。
    case streaming
    /// 本轮完成。
    case completed
    /// 中断（保留已接收内容，不伪装为完整回答）。
    case interrupted
    /// 失败；`retryable` 区分可重试/不可重试（§5.7）。
    case failed(retryable: Bool, reason: String)

    /// 该阶段下是否允许发起新的发送。
    public var canSend: Bool {
        switch self {
        case .idle, .completed, .interrupted, .failed: return true
        case .sending, .streaming: return false
        }
    }
}

/// 主对话发送驱动缝（生产实现见 ``LiveConversationDriver``；测试注入假实现）。
/// 核心约束不变：SDK 类型不扩散——本协议只出现领域类型。
public protocol ConversationDriver: Sendable {
    /// 为本地归属（thread/branch）创建 ACP session 并登记映射，返回 sessionID。
    func makeSession(cwd: String, owner: SessionStore.Owner) async throws -> String
    /// 发送 prompt（完成/失败经事件流回传；直接抛出视为发送失败）。
    func sendPrompt(sessionID: String, text: String) async throws
    /// 订阅指定 session 的领域事件流（按 session 路由由 SessionStore 保证）。
    func events(for sessionID: String) async -> AsyncStream<AgentEvent>
}

/// 会话上下文键（M3-008）：threadID + branchID 二维定位；
/// `branchID == nil` 即主线，主线公开 API 行为与 B-M1 完全一致。
public struct ConversationKey: Hashable, Sendable {
    public let threadID: String
    public let branchID: String?

    public init(threadID: String, branchID: String? = nil) {
        self.threadID = threadID
        self.branchID = branchID
    }
}

/// 主对话界面快照（ViewModel 订阅；主线快照仅承载当前活跃线程）。
public struct ConversationSnapshot: Sendable, Equatable {
    public var threadID: String?
    /// 支线快照携带 branchID；主线快照恒为 nil（既有构造兼容，默认 nil）。
    public var branchID: String?
    public var messages: [Message]
    public var phase: ConversationPhase

    public init(threadID: String?, branchID: String? = nil, messages: [Message], phase: ConversationPhase) {
        self.threadID = threadID
        self.branchID = branchID
        self.messages = messages
        self.phase = phase
    }
}

/// 主对话状态机与会话编排（任务 M1-012，流程文档 §5.7；M3-008 起泛化到支线维度）。
///
/// 职责：
/// - 发送即存：user message 立即落库（completed），assistant 占位（streaming）；
/// - delta 顺序追加到同一消息（内存即时 + 节流落库，终态强制落库）；
/// - 工具事件聚合成 ``MessageKind/toolCall`` 卡片消息（M2-002，同节奏落库）；
/// - 完成原子置 completed；中断保留已收内容置 interrupted；
/// - 重试产生明确的新 assistant 消息与新请求，不静默重复扣费；
/// - 跨会话路由：每 ``ConversationKey``（主线/支线）独立上下文与消费循环，
///   按 session 绑定，UI 切换/关闭标签不销毁上下文，后台流式继续写入
///   （G1-06 结构性保证；BR-17 主线与支线并发不串线的结构基础）。
///
/// 不属本层：permission 决策（M2-005 策略器）、工具卡片渲染（Features 层）、
/// 支线记录创建与种子背景组装（BranchContextAssembler/BranchSessionCoordinator）。
public actor ConversationStore {

    private let threads: ThreadRepository
    private let messages: MessageRepository
    /// 重连后由 ``updateDriver(_:)`` 替换（旧 driver 绑定的 client 已随进程死亡）。
    private var driver: any ConversationDriver
    private let logger: Logger
    /// delta 节流落库间隔（秒）；测试注入 0 使每个 delta 立即落库。
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// 单会话运行上下文（按 ``ConversationKey`` 登记；切换线程/关闭标签不销毁，
    /// 后台流式继续写入；本轮不提供上下文销毁 API）。
    private struct ThreadContext {
        var threadID: String
        /// nil = 主线。
        var branchID: String?
        var projectRoot: String
        var sessionID: String
        var phase: ConversationPhase = .idle
        var messages: [Message] = []
        /// 当前流式中的 assistant 消息 id（一轮 prompt 至多一条）。
        var streamingMessageID: String?
        /// 尚未落库的 delta 缓冲（节流）。
        var pendingDelta = ""
        var lastFlush = Date.distantPast
        /// 工具调用聚合器（M2-002：tool_call/update → 生命周期记录）。
        var toolCallTracker = ToolCallTracker()
        /// toolCallID → 对话流卡片消息 id（一次调用一条消息，就地更新）。
        var toolCallMessageIDs: [String: String] = [:]
        /// 已更新但尚未落库的工具卡片消息 id（与 delta 共用节流节奏）。
        var pendingToolMessageIDs: Set<String> = []
        var consumptionTask: Task<Void, Never>?

        var key: ConversationKey { ConversationKey(threadID: threadID, branchID: branchID) }
    }

    private var contexts: [ConversationKey: ThreadContext] = [:]
    private var activeThreadID: String?
    private var snapshotContinuations: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]
    /// 支线快照订阅（按 branchID 分组，支持多订阅者；与主线快照流互不干扰）。
    private var branchContinuations: [String: [UUID: AsyncStream<ConversationSnapshot>.Continuation]] = [:]

    public init(
        threads: ThreadRepository,
        messages: MessageRepository,
        driver: any ConversationDriver,
        flushInterval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger = Logger(label: "twig.conversation.store")
    ) {
        self.threads = threads
        self.messages = messages
        self.driver = driver
        self.flushInterval = flushInterval
        self.now = now
        self.logger = logger
    }

    // MARK: - 快照订阅

    /// 当前快照（活跃线程为空时为空白快照）。
    public func currentSnapshot() -> ConversationSnapshot {
        guard let activeThreadID else {
            return ConversationSnapshot(threadID: nil, messages: [], phase: .idle)
        }
        return snapshot(for: ConversationKey(threadID: activeThreadID))
    }

    /// 订阅主线快照流（先回放当前值，再推送后续变更；支持多订阅者）。
    public func snapshots() -> AsyncStream<ConversationSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    /// 支线当前快照（支线未打开时为空白快照，branchID 字段保留入参）。
    public func currentBranchSnapshot(branchID: String) -> ConversationSnapshot {
        guard let key = branchKey(branchID: branchID) else {
            return ConversationSnapshot(threadID: nil, branchID: branchID, messages: [], phase: .idle)
        }
        return snapshot(for: key)
    }

    /// 订阅支线快照流（先回放当前值，再推送后续变更；支持多订阅者）。
    public func branchSnapshots(branchID: String) -> AsyncStream<ConversationSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            branchContinuations[branchID, default: [:]][id] = continuation
            continuation.yield(currentBranchSnapshot(branchID: branchID))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeBranchContinuation(branchID: branchID, id: id) }
            }
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func removeBranchContinuation(branchID: String, id: UUID) {
        branchContinuations[branchID]?.removeValue(forKey: id)
        if branchContinuations[branchID]?.isEmpty == true {
            branchContinuations.removeValue(forKey: branchID)
        }
    }

    private func publish() {
        let snapshot = currentSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    /// 事件驱动的快照推送：支线 key 只推支线订阅者；
    /// 主线 key 仅在活跃线程时走现有 ``publish()``（与 B-M1 行为一致）。
    private func publishIfNeeded(_ key: ConversationKey) {
        if key.branchID != nil {
            publishBranch(key)
        } else if key.threadID == activeThreadID {
            publish()
        }
    }

    private func publishBranch(_ key: ConversationKey) {
        guard let branchID = key.branchID, let continuations = branchContinuations[branchID] else { return }
        let snapshot = snapshot(for: key)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func snapshot(for key: ConversationKey) -> ConversationSnapshot {
        guard let ctx = contexts[key] else {
            return ConversationSnapshot(threadID: nil, branchID: key.branchID, messages: [], phase: .idle)
        }
        return ConversationSnapshot(
            threadID: key.threadID, branchID: key.branchID, messages: ctx.messages, phase: ctx.phase
        )
    }

    /// 按 branchID 反查上下文键（branchID 全局唯一）。
    private func branchKey(branchID: String) -> ConversationKey? {
        contexts.keys.first { $0.branchID == branchID }
    }

    // MARK: - 线程激活

    /// 启动入口：打开最近线程（无则新建）并激活。
    public func openMostRecentOrCreate(projectRoot: String) async throws {
        let thread = try threads.listThreads().first
            ?? threads.createThread(title: Self.defaultThreadTitle, projectRoot: projectRoot, at: now())
        try await activate(thread)
    }

    /// 「新对话」按钮：新建线程并激活（旧线程的流式上下文保留，后台继续写入）。
    /// `title` 为空时用默认标题（M4-007：首条问题自动生成标题，见 ``send(key:text:metadata:)``）。
    public func newConversation(title: String? = nil, projectRoot: String) async throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let thread = try threads.createThread(
            title: trimmed.isEmpty ? Self.defaultThreadTitle : trimmed,
            projectRoot: projectRoot, at: now()
        )
        try await activate(thread)
    }

    /// 切回已存在的线程（B-M1 最小切换能力；完整多线程归 M4-007）。
    public func switchToThread(id threadID: String) async throws {
        guard let thread = try threads.listThreads().first(where: { $0.id == threadID }) else {
            logger.warning("切换目标线程不存在（保守忽略）：\(threadID.prefix(8))…")
            return
        }
        try await activate(thread)
    }

    private func activate(_ thread: ConversationThread) async throws {
        let key = ConversationKey(threadID: thread.id)
        // 已有上下文：先冲刷未落库缓冲再重读，直接复用（session 仍存活则消费循环继续）。
        if var ctx = contexts[key] {
            flushPending(&ctx)
            ctx.messages = try messages.messages(threadID: thread.id)
            contexts[key] = ctx
            activeThreadID = thread.id
            publish()
            return
        }
        let sessionID = try await driver.makeSession(cwd: thread.projectRoot, owner: .thread(thread.id))
        var ctx = ThreadContext(
            threadID: thread.id, branchID: nil, projectRoot: thread.projectRoot, sessionID: sessionID
        )
        ctx.messages = try messages.messages(threadID: thread.id)
        contexts[key] = ctx
        activeThreadID = thread.id
        await startConsumption(key: key)
        publish()
    }

    // MARK: - 支线打开（M3-008）

    /// 打开支线会话：新建 ACP session（owner=.branch）并加载支线消息，起独立消费循环；
    /// 已有上下文则复用（重读消息，session 仍存活则消费循环继续）。返回支线快照。
    /// 支线记录（branches 行）与种子背景组装由上层（BranchSessionCoordinator）负责，本层不感知。
    @discardableResult
    public func openBranch(branchID: String, threadID: String, projectRoot: String) async throws -> ConversationSnapshot {
        let key = ConversationKey(threadID: threadID, branchID: branchID)
        if var ctx = contexts[key] {
            flushPending(&ctx)
            ctx.messages = try messages.messages(threadID: threadID, branchID: branchID)
            contexts[key] = ctx
            publishBranch(key)
            return snapshot(for: key)
        }
        let sessionID = try await driver.makeSession(cwd: projectRoot, owner: .branch(branchID))
        var ctx = ThreadContext(
            threadID: threadID, branchID: branchID, projectRoot: projectRoot, sessionID: sessionID
        )
        ctx.messages = try messages.messages(threadID: threadID, branchID: branchID)
        contexts[key] = ctx
        await startConsumption(key: key)
        publishBranch(key)
        return snapshot(for: key)
    }

    // MARK: - 发送与重试

    /// 发送用户消息到主线活跃线程（§5.7：发送即存 + 占位 streaming 消息）。
    /// streaming/sending 阶段重复发送直接忽略（UI 同步禁发，双保险）。
    public func send(text: String) async throws {
        guard let threadID = activeThreadID else {
            throw ConversationStoreError.noActiveThread
        }
        try await send(key: ConversationKey(threadID: threadID), text: text)
    }

    /// 发送用户消息到支线（M3-008）。`metadata` 编码进 user 消息的 metadataJSON
    /// （种子消息标记 `seed_context` 等，照 ``applyToolCallDenied`` 的编码模式）。
    /// 支线未打开（未 ``openBranch(branchID:threadID:projectRoot:)``）时抛出 ``ConversationStoreError/branchNotOpen(_:)``。
    public func sendBranchMessage(branchID: String, text: String, metadata: [String: String]? = nil) async throws {
        guard let key = branchKey(branchID: branchID) else {
            throw ConversationStoreError.branchNotOpen(branchID)
        }
        try await send(key: key, text: text, metadata: metadata)
    }

    private func send(key: ConversationKey, text: String, metadata: [String: String]? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var ctx = contexts[key] else {
            throw ConversationStoreError.noActiveThread
        }
        guard ctx.phase.canSend else {
            logger.debug("流式中忽略重复发送（\(Self.logLabel(key))）")
            return
        }

        // metadata 编码模式与 applyToolCallDenied 一致（[String: String] → JSON 字符串）。
        var metadataJSON: String?
        if let metadata, let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = String(data: data, encoding: .utf8)
        }

        let date = now()
        let userMessage = Message(
            id: UUID().uuidString, threadID: key.threadID, branchID: key.branchID,
            role: .user, content: trimmed,
            sequence: try messages.nextSequence(threadID: key.threadID, branchID: key.branchID),
            status: .completed, createdAt: date, updatedAt: date, metadataJSON: metadataJSON
        )
        try messages.insert(userMessage)
        // M4-007（DEC-10）：默认标题的主线在首条问题落库后自动生成标题（截 20 字）。
        if key.branchID == nil, userMessage.sequence == 1 {
            let current = try? threads.listThreads().first(where: { $0.id == key.threadID })
            if let thread = current ?? nil, thread.title == Self.defaultThreadTitle {
                try? threads.renameThread(id: key.threadID, title: String(trimmed.prefix(20)))
            }
        }
        let placeholder = Message(
            id: UUID().uuidString, threadID: key.threadID, branchID: key.branchID,
            role: .assistant, content: "",
            sequence: try messages.nextSequence(threadID: key.threadID, branchID: key.branchID),
            status: .streaming, createdAt: date, updatedAt: date
        )
        try messages.insert(placeholder)

        ctx.messages.append(contentsOf: [userMessage, placeholder])
        ctx.streamingMessageID = placeholder.id
        ctx.phase = .sending
        contexts[key] = ctx
        publishIfNeeded(key)

        do {
            try await driver.sendPrompt(sessionID: ctx.sessionID, text: trimmed)
        } catch {
            // ACPClient.prompt 会同时广播 .failed 事件；若消费循环已处理则此处为幂等兜底。
            failStreamingIfNeeded(key: key, reason: error.localizedDescription)
        }
    }

    /// 显式重试主线活跃线程：取最后一条 user 消息，生成**新的** assistant 占位并重发——
    /// 旧消息状态不改写，新请求由用户显式触发（§5.7「不得悄悄重复扣取额度」）。
    public func retry() async throws {
        guard let threadID = activeThreadID else { return }
        try await retry(key: ConversationKey(threadID: threadID))
    }

    /// 支线显式重试（M3-008）：语义与主线 ``retry()`` 一致。
    public func retryBranch(branchID: String) async throws {
        guard let key = branchKey(branchID: branchID) else { return }
        try await retry(key: key)
    }

    private func retry(key: ConversationKey) async throws {
        guard var ctx = contexts[key] else { return }
        guard case .failed = ctx.phase, let lastUser = ctx.messages.last(where: { $0.role == .user }) else {
            logger.debug("当前状态不支持重试（\(Self.logLabel(key))）")
            return
        }
        let date = now()
        let placeholder = Message(
            id: UUID().uuidString, threadID: key.threadID, branchID: key.branchID,
            role: .assistant, content: "",
            sequence: try messages.nextSequence(threadID: key.threadID, branchID: key.branchID),
            status: .streaming, createdAt: date, updatedAt: date
        )
        try messages.insert(placeholder)
        ctx.messages.append(placeholder)
        ctx.streamingMessageID = placeholder.id
        ctx.phase = .sending
        contexts[key] = ctx
        publishIfNeeded(key)
        do {
            try await driver.sendPrompt(sessionID: ctx.sessionID, text: lastUser.content)
        } catch {
            failStreamingIfNeeded(key: key, reason: error.localizedDescription)
        }
    }

    // MARK: - 回流注入（M3-011）

    /// 向指定线程的主线 session 注入背景补充文本（BranchMergeService 回流用，§7.8 步骤 5）。
    /// 与 ``send(text:)`` 的本质区别：注入是背景补充而非用户发言——
    /// **不落库 user 消息、不产生 assistant 占位**（回流笔记已由 recordMerge 落库）。
    /// agent 若仍回应，其 delta 因无流式占位被 ``appendDelta`` 保守记录并丢弃，
    /// 属可接受行为（注入文本已显式要求「无需回复」）。
    /// 不改变主线 phase；主线正在流式时发送失败原样抛出（调用方按中间态处理，可重试）。
    /// 主线上下文未打开（线程从未激活）时抛 ``ConversationStoreError/threadNotOpen(_:)``。
    public func injectContextToMainThread(threadID: String, text: String) async throws {
        let key = ConversationKey(threadID: threadID)
        guard let ctx = contexts[key] else {
            throw ConversationStoreError.threadNotOpen(threadID)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await driver.sendPrompt(sessionID: ctx.sessionID, text: trimmed)
    }

    /// 中断主线指定线程的流式（M1-013 进程级路径与事件流终止均经此收口）。
    public func interrupt(threadID: String) {
        interrupt(key: ConversationKey(threadID: threadID))
    }

    /// 中断支线的流式（M3-008；语义与主线 ``interrupt(threadID:)`` 一致）。
    public func interruptBranch(branchID: String) {
        guard let key = branchKey(branchID: branchID) else { return }
        interrupt(key: key)
    }

    private func interrupt(key: ConversationKey) {
        guard var ctx = contexts[key] else { return }
        if let messageID = ctx.streamingMessageID {
            finishStreaming(&ctx, messageID: messageID, status: .interrupted)
            ctx.phase = .interrupted
        }
        // 挂起的工具调用一并终态收口（M2-002）。
        settlePendingToolCalls(&ctx, status: .interrupted)
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    // MARK: - 进程中断与恢复（M1-013）

    /// 子进程异常退出时调用：全部会话（主线与支线）的流式消息标记 interrupted
    /// （保留已收内容，G1-07；支线覆盖为 M3-008 扩展）。
    public func interruptAllStreaming() {
        for key in contexts.keys {
            interrupt(key: key)
        }
    }

    /// 重连后替换驱动（新 ACPClient）。
    public func updateDriver(_ driver: any ConversationDriver) {
        self.driver = driver
    }

    /// 重连成功后为全部已知会话（主线与支线）**重建** session（G1-08；M3-008 起
    /// 支线以 owner=.branch 重建）：旧 session 随进程死亡不可用，本方法只建新 session、
    /// 不做续接假象（list/resume/load 恢复策略归 M4-010）；历史全在本地库，不依赖 agent 侧重放。
    public func renewSessions() async throws {
        for key in contexts.keys {
            guard var ctx = contexts[key] else { continue }
            ctx.consumptionTask?.cancel()
            let owner: SessionStore.Owner = ctx.branchID.map { .branch($0) } ?? .thread(key.threadID)
            let sessionID = try await driver.makeSession(cwd: ctx.projectRoot, owner: owner)
            ctx.sessionID = sessionID
            contexts[key] = ctx
            await startConsumption(key: key)
        }
        logger.info("session 已全部重建（共 \(self.contexts.count) 个会话上下文）")
    }

    // MARK: - 事件消费

    private func startConsumption(key: ConversationKey) async {
        guard var ctx = contexts[key] else { return }
        // 须在首次 prompt 前完成订阅（SessionStore 不做事件缓冲）。
        let stream = await driver.events(for: ctx.sessionID)
        let task = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, key: key)
            }
            // 主动取消（renewSessions 换 session）不视为中断；
            // 只有流自然终止（进程死亡/断开）才标记 interrupted。
            if !Task.isCancelled {
                await self?.streamEnded(key: key)
            }
        }
        ctx.consumptionTask = task
        contexts[key] = ctx
    }

    private func handle(_ event: AgentEvent, key: ConversationKey) {
        switch event {
        case .textDelta(_, let text):
            appendDelta(key: key, text: text)
        case .completed(_, let stopReason):
            completeStreaming(key: key, stopReason: stopReason)
        case .failed(_, let reason):
            failStreamingIfNeeded(key: key, reason: reason)
        case .thoughtDelta:
            // 思考流不入正文（渲染归 B-M2 之后决策），仅保守记录类型。
            logger.debug("收到 thoughtDelta（不入正文）：\(Self.logLabel(key))")
        case .toolCallStarted, .toolCallUpdated:
            applyToolEvent(event, key: key)
        case .toolCallDenied(_, let callID, let operation, let noticeText):
            applyToolCallDenied(key: key, callID: callID, operation: operation, noticeText: noticeText)
        case .permissionRequested:
            // 响应由 ACPClient 的 default deny 处理（M2-005 接策略器），本层不重复决策。
            break
        case .userTextDelta, .notice, .unknown:
            logger.debug("收到非主对话事件（保守记录，仅类型）：\(Self.logLabel(key))")
        }
    }

    private func appendDelta(key: ConversationKey, text: String) {
        guard var ctx = contexts[key],
              let messageID = ctx.streamingMessageID,
              let index = ctx.messages.firstIndex(where: { $0.id == messageID }) else {
            logger.debug("收到无流式占位的 delta（保守记录）：\(Self.logLabel(key))")
            return
        }
        ctx.messages[index].content += text
        ctx.messages[index].updatedAt = now()
        ctx.pendingDelta += text
        if ctx.phase == .sending { ctx.phase = .streaming }
        if now().timeIntervalSince(ctx.lastFlush) >= flushInterval {
            flushPending(&ctx)
        }
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    private func completeStreaming(key: ConversationKey, stopReason: String) {
        guard var ctx = contexts[key], let messageID = ctx.streamingMessageID else {
            logger.debug("收到无流式占位的 completed（保守记录）：stopReason=\(stopReason)")
            return
        }
        finishStreaming(&ctx, messageID: messageID, status: .completed)
        ctx.phase = .completed
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    private func failStreamingIfNeeded(key: ConversationKey, reason: String) {
        guard var ctx = contexts[key], let messageID = ctx.streamingMessageID else { return }
        finishStreaming(&ctx, messageID: messageID, status: .failed)
        ctx.phase = .failed(retryable: Self.isRetryable(reason: reason), reason: reason)
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    /// 事件流终止（子进程死亡/断开）：流式中的消息标记 interrupted，保留已收内容。
    private func streamEnded(key: ConversationKey) {
        guard let ctx = contexts[key],
              ctx.streamingMessageID != nil || !ctx.toolCallMessageIDs.isEmpty else { return }
        interrupt(key: key)
    }

    /// 终态收口：冲刷缓冲 + 落库状态 + 同步内存副本（completed/failed/interrupted 共用）。
    private func finishStreaming(_ ctx: inout ThreadContext, messageID: String, status: MessageStatus) {
        flushPending(&ctx)
        flushPendingToolCalls(&ctx)
        let date = now()
        do {
            try messages.updateStatus(messageID: messageID, status: status, at: date)
        } catch {
            logger.error("消息状态落库失败（保守记录）：\(error.localizedDescription)")
        }
        if let index = ctx.messages.firstIndex(where: { $0.id == messageID }) {
            ctx.messages[index].status = status
            ctx.messages[index].updatedAt = date
        }
        ctx.streamingMessageID = nil
    }

    /// 冲刷 delta 缓冲到数据库；失败保留缓冲待下次冲刷（保守记录，不崩溃）。
    private func flushPending(_ ctx: inout ThreadContext) {
        guard !ctx.pendingDelta.isEmpty, let messageID = ctx.streamingMessageID else { return }
        do {
            try messages.appendContent(messageID: messageID, delta: ctx.pendingDelta, at: now())
            ctx.pendingDelta = ""
            ctx.lastFlush = now()
        } catch {
            logger.error("delta 落库失败，保留缓冲待重试（保守记录）：\(error.localizedDescription)")
        }
    }

    // MARK: - 工具事件接线（M2-002）

    /// 工具事件 → 卡片消息：一次调用一条 ``MessageKind/toolCall`` 消息，
    /// 首次创建、后续就地更新 content（结果摘要文本）与 metadataJSON（ToolCallRecord JSON）。
    /// 落库节奏参照 ``appendDelta``：内存即时更新 + 节流落库 + 终态强制落库。
    private func applyToolEvent(_ event: AgentEvent, key: ConversationKey) {
        guard var ctx = contexts[key],
              let record = ctx.toolCallTracker.apply(event) else { return }
        let date = now()
        let content = record.contentText ?? record.title ?? ""
        let metadata = Self.encodeToolMetadata(record)
        if let messageID = ctx.toolCallMessageIDs[record.toolCallID],
           let index = ctx.messages.firstIndex(where: { $0.id == messageID }) {
            ctx.messages[index].content = content
            ctx.messages[index].metadataJSON = metadata
            ctx.messages[index].updatedAt = date
            // 工具终态只反映到 metadata 的 record.status；消息状态统一 completed
            // （卡片自绘状态徽标，不触发正文行的失败/重试徽标）。
            if record.status.isTerminal {
                ctx.messages[index].status = .completed
            }
            ctx.pendingToolMessageIDs.insert(messageID)
        } else {
            do {
                let message = Message(
                    id: UUID().uuidString, threadID: key.threadID, branchID: key.branchID,
                    role: .assistant, kind: .toolCall,
                    content: content,
                    sequence: try messages.nextSequence(threadID: key.threadID, branchID: key.branchID),
                    status: record.status.isTerminal ? .completed : .streaming,
                    createdAt: date, updatedAt: date, metadataJSON: metadata
                )
                try messages.insert(message)
                ctx.toolCallMessageIDs[record.toolCallID] = message.id
                ctx.messages.append(message)
            } catch {
                logger.error("工具卡片消息落库失败（保守记录）：\(error.localizedDescription)")
            }
        }
        if record.status.isTerminal || date.timeIntervalSince(ctx.lastFlush) >= flushInterval {
            flushPendingToolCalls(&ctx)
        }
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    /// 冲刷待落库的工具卡片更新（content + metadataJSON + status）；失败保留待重试（保守记录）。
    private func flushPendingToolCalls(_ ctx: inout ThreadContext) {
        let ids = ctx.pendingToolMessageIDs
        guard !ids.isEmpty else { return }
        ctx.pendingToolMessageIDs = []
        for messageID in ids {
            guard let message = ctx.messages.first(where: { $0.id == messageID }) else { continue }
            do {
                try messages.updateMetadata(
                    messageID: messageID, content: message.content,
                    metadataJSON: message.metadataJSON, status: message.status, at: message.updatedAt
                )
            } catch {
                ctx.pendingToolMessageIDs.insert(messageID)
                logger.error("工具卡片落库失败，保留待重试（保守记录）：\(error.localizedDescription)")
            }
        }
    }

    /// 挂起工具调用的终态收口（中断/失败路径）：未达终态的卡片标记 status 并强制落库。
    private func settlePendingToolCalls(_ ctx: inout ThreadContext, status: MessageStatus) {
        for (callID, messageID) in ctx.toolCallMessageIDs {
            guard let record = ctx.toolCallTracker.record(callID: callID),
                  !record.status.isTerminal,
                  let index = ctx.messages.firstIndex(where: { $0.id == messageID }) else { continue }
            ctx.messages[index].status = status
            ctx.messages[index].updatedAt = now()
            ctx.pendingToolMessageIDs.insert(messageID)
        }
        flushPendingToolCalls(&ctx)
    }

    /// 权限拒绝收口（M2-006）：卡片转 denied 终态强制落库 + 对话流落一条
    /// ``MessageKind/notice``（透明展示，重启可回看，SEC-12/13 前置）。
    /// metadata 只记决策类型与工具名，不记文件内容（§6.3 实现顺序 6）。
    private func applyToolCallDenied(key: ConversationKey, callID: String?, operation: ToolOperation, noticeText: String) {
        guard var ctx = contexts[key] else { return }
        let date = now()
        if let callID, let messageID = ctx.toolCallMessageIDs[callID],
           let index = ctx.messages.firstIndex(where: { $0.id == messageID }) {
            let record = ctx.toolCallTracker.markDenied(callID: callID)
            ctx.messages[index].content = record.contentText ?? record.title ?? ""
            ctx.messages[index].metadataJSON = Self.encodeToolMetadata(record)
            ctx.messages[index].status = .completed
            ctx.messages[index].updatedAt = date
            ctx.pendingToolMessageIDs.insert(messageID)
            flushPendingToolCalls(&ctx)
        }
        // notice 低频且须重启可回看：不走节流，立即落库。
        var metadata: [String: String] = ["operation": operation.rawValue]
        if let callID { metadata["toolCallID"] = callID }
        let metadataJSON = try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)
        do {
            let notice = Message(
                id: UUID().uuidString, threadID: key.threadID, branchID: key.branchID,
                role: .system, kind: .notice,
                content: noticeText,
                sequence: try messages.nextSequence(threadID: key.threadID, branchID: key.branchID),
                status: .completed, createdAt: date, updatedAt: date, metadataJSON: metadataJSON ?? nil
            )
            try messages.insert(notice)
            ctx.messages.append(notice)
        } catch {
            logger.error("拒绝 notice 落库失败（保守记录）：\(error.localizedDescription)")
        }
        contexts[key] = ctx
        publishIfNeeded(key)
    }

    /// 工具摘要编码（不存完整 ACP SDK 对象，只存聚合后的 ``ToolCallRecord``）。
    private static func encodeToolMetadata(_ record: ToolCallRecord) -> String? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 新建线程的默认标题（M4-007：首条问题落库后自动替换为问题摘要）。
    static let defaultThreadTitle = "新对话"

    /// 日志标签（脱敏仅前缀；区分主线/支线）。
    private static func logLabel(_ key: ConversationKey) -> String {
        if let branchID = key.branchID {
            return "branch=\(branchID.prefix(8))…(thread=\(key.threadID.prefix(8))…)"
        }
        return "thread=\(key.threadID.prefix(8))…"
    }

    /// 最小错误分类（M1-013 出完整错误页面时再细化）：
    /// 协议参数类错误不可重试，进程/链路类默认可重试。
    static func isRetryable(reason: String) -> Bool {
        let lowered = reason.lowercased()
        return !(lowered.contains("invalid") || lowered.contains("protocol"))
    }
}

/// ConversationStore 调用前置条件错误。
public enum ConversationStoreError: Error, Sendable, Equatable {
    /// 尚无活跃线程（未调用 open/new/switch）。
    case noActiveThread
    /// 支线上下文未打开（须先 openBranch）。
    case branchNotOpen(String)
    /// 主线上下文未打开（线程从未激活；回流注入前置条件）。
    case threadNotOpen(String)
}
