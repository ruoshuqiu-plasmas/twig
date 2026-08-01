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

/// 主对话界面快照（ViewModel 订阅；仅承载当前活跃线程）。
public struct ConversationSnapshot: Sendable, Equatable {
    public var threadID: String?
    public var messages: [Message]
    public var phase: ConversationPhase

    public init(threadID: String?, messages: [Message], phase: ConversationPhase) {
        self.threadID = threadID
        self.messages = messages
        self.phase = phase
    }
}

/// 主对话状态机与会话编排（任务 M1-012，流程文档 §5.7）。
///
/// 职责：
/// - 发送即存：user message 立即落库（completed），assistant 占位（streaming）；
/// - delta 顺序追加到同一消息（内存即时 + 节流落库，终态强制落库）；
/// - 工具事件聚合成 ``MessageKind/toolCall`` 卡片消息（M2-002，同节奏落库）；
/// - 完成原子置 completed；中断保留已收内容置 interrupted；
/// - 重试产生明确的新 assistant 消息与新请求，不静默重复扣费；
/// - 跨线程路由：每线程独立消费循环按 session 绑定，UI 切换不影响后台线程写入
///   （G1-06 结构性保证；B-M1 仅提供切回活跃线程的 ``switchToThread(id:)``）。
///
/// 不属本层：permission 决策（M2-005 策略器）、工具卡片渲染（Features 层）。
public actor ConversationStore {

    private let threads: ThreadRepository
    private let messages: MessageRepository
    /// 重连后由 ``updateDriver(_:)`` 替换（旧 driver 绑定的 client 已随进程死亡）。
    private var driver: any ConversationDriver
    private let logger: Logger
    /// delta 节流落库间隔（秒）；测试注入 0 使每个 delta 立即落库。
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// 单线程运行上下文（按 threadID 登记；切换线程不销毁，后台流式继续写入）。
    private struct ThreadContext {
        var thread: ConversationThread
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
    }

    private var contexts: [String: ThreadContext] = [:]
    private var activeThreadID: String?
    private var snapshotContinuations: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]

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
        guard let activeThreadID, let ctx = contexts[activeThreadID] else {
            return ConversationSnapshot(threadID: nil, messages: [], phase: .idle)
        }
        return ConversationSnapshot(threadID: activeThreadID, messages: ctx.messages, phase: ctx.phase)
    }

    /// 订阅快照流（先回放当前值，再推送后续变更；支持多订阅者）。
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

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func publish() {
        let snapshot = currentSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - 线程激活

    /// 启动入口：打开最近线程（无则新建）并激活。
    public func openMostRecentOrCreate(projectRoot: String) async throws {
        let thread = try threads.listThreads().first
            ?? threads.createThread(title: "新对话", projectRoot: projectRoot, at: now())
        try await activate(thread)
    }

    /// 「新对话」按钮：新建线程并激活（旧线程的流式上下文保留，后台继续写入）。
    public func newConversation(projectRoot: String) async throws {
        let thread = try threads.createThread(title: "新对话", projectRoot: projectRoot, at: now())
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
        // 已有上下文：先冲刷未落库缓冲再重读，直接复用（session 仍存活则消费循环继续）。
        if var ctx = contexts[thread.id] {
            flushPending(&ctx)
            ctx.messages = try messages.messages(threadID: thread.id)
            contexts[thread.id] = ctx
            activeThreadID = thread.id
            publish()
            return
        }
        let sessionID = try await driver.makeSession(cwd: thread.projectRoot, owner: .thread(thread.id))
        var ctx = ThreadContext(thread: thread, sessionID: sessionID)
        ctx.messages = try messages.messages(threadID: thread.id)
        contexts[thread.id] = ctx
        activeThreadID = thread.id
        await startConsumption(threadID: thread.id)
        publish()
    }

    // MARK: - 发送与重试

    /// 发送用户消息（§5.7：发送即存 + 占位 streaming 消息）。
    /// streaming/sending 阶段重复发送直接忽略（UI 同步禁发，双保险）。
    public func send(text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let threadID = activeThreadID, var ctx = contexts[threadID] else {
            throw ConversationStoreError.noActiveThread
        }
        guard ctx.phase.canSend else {
            logger.debug("流式中忽略重复发送（thread=\(threadID.prefix(8))…）")
            return
        }

        let date = now()
        let userMessage = Message(
            id: UUID().uuidString, threadID: threadID, role: .user, content: trimmed,
            sequence: try messages.nextSequence(threadID: threadID),
            status: .completed, createdAt: date, updatedAt: date
        )
        try messages.insert(userMessage)
        let placeholder = Message(
            id: UUID().uuidString, threadID: threadID, role: .assistant, content: "",
            sequence: try messages.nextSequence(threadID: threadID),
            status: .streaming, createdAt: date, updatedAt: date
        )
        try messages.insert(placeholder)

        ctx.messages.append(contentsOf: [userMessage, placeholder])
        ctx.streamingMessageID = placeholder.id
        ctx.phase = .sending
        contexts[threadID] = ctx
        publish()

        do {
            try await driver.sendPrompt(sessionID: ctx.sessionID, text: trimmed)
        } catch {
            // ACPClient.prompt 会同时广播 .failed 事件；若消费循环已处理则此处为幂等兜底。
            failStreamingIfNeeded(threadID: threadID, reason: error.localizedDescription)
        }
    }

    /// 显式重试：取最后一条 user 消息，生成**新的** assistant 占位并重发——
    /// 旧消息状态不改写，新请求由用户显式触发（§5.7「不得悄悄重复扣取额度」）。
    public func retry() async throws {
        guard let threadID = activeThreadID, var ctx = contexts[threadID] else { return }
        guard case .failed = ctx.phase, let lastUser = ctx.messages.last(where: { $0.role == .user }) else {
            logger.debug("当前状态不支持重试（thread=\(threadID.prefix(8))…）")
            return
        }
        let date = now()
        let placeholder = Message(
            id: UUID().uuidString, threadID: threadID, role: .assistant, content: "",
            sequence: try messages.nextSequence(threadID: threadID),
            status: .streaming, createdAt: date, updatedAt: date
        )
        try messages.insert(placeholder)
        ctx.messages.append(placeholder)
        ctx.streamingMessageID = placeholder.id
        ctx.phase = .sending
        contexts[threadID] = ctx
        publish()
        do {
            try await driver.sendPrompt(sessionID: ctx.sessionID, text: lastUser.content)
        } catch {
            failStreamingIfNeeded(threadID: threadID, reason: error.localizedDescription)
        }
    }

    /// 中断当前线程的流式（M1-013 进程级路径与事件流终止均经此收口）。
    public func interrupt(threadID: String) {
        guard var ctx = contexts[threadID] else { return }
        if let messageID = ctx.streamingMessageID {
            finishStreaming(&ctx, messageID: messageID, status: .interrupted)
            ctx.phase = .interrupted
        }
        // 挂起的工具调用一并终态收口（M2-002）。
        settlePendingToolCalls(&ctx, status: .interrupted)
        contexts[threadID] = ctx
        if threadID == activeThreadID { publish() }
    }

    // MARK: - 进程中断与恢复（M1-013）

    /// 子进程异常退出时调用：全部线程的流式消息标记 interrupted（保留已收内容，G1-07）。
    public func interruptAllStreaming() {
        for threadID in contexts.keys {
            interrupt(threadID: threadID)
        }
    }

    /// 重连后替换驱动（新 ACPClient）。
    public func updateDriver(_ driver: any ConversationDriver) {
        self.driver = driver
    }

    /// 重连成功后为全部已知线程**重建** session（G1-08）：
    /// 旧 session 随进程死亡不可用，本方法只建新 session、不做续接假象
    /// （list/resume/load 恢复策略归 M4-010）；线程历史全在本地库，不依赖 agent 侧重放。
    public func renewSessions() async throws {
        for threadID in contexts.keys {
            guard var ctx = contexts[threadID] else { continue }
            ctx.consumptionTask?.cancel()
            let sessionID = try await driver.makeSession(cwd: ctx.thread.projectRoot, owner: .thread(threadID))
            ctx.sessionID = sessionID
            contexts[threadID] = ctx
            await startConsumption(threadID: threadID)
        }
        logger.info("session 已全部重建（共 \(self.contexts.count) 个线程）")
    }

    // MARK: - 事件消费

    private func startConsumption(threadID: String) async {
        guard var ctx = contexts[threadID] else { return }
        // 须在首次 prompt 前完成订阅（SessionStore 不做事件缓冲）。
        let stream = await driver.events(for: ctx.sessionID)
        let task = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, threadID: threadID)
            }
            // 主动取消（renewSessions 换 session）不视为中断；
            // 只有流自然终止（进程死亡/断开）才标记 interrupted。
            if !Task.isCancelled {
                await self?.streamEnded(threadID: threadID)
            }
        }
        ctx.consumptionTask = task
        contexts[threadID] = ctx
    }

    private func handle(_ event: AgentEvent, threadID: String) {
        switch event {
        case .textDelta(_, let text):
            appendDelta(threadID: threadID, text: text)
        case .completed(_, let stopReason):
            completeStreaming(threadID: threadID, stopReason: stopReason)
        case .failed(_, let reason):
            failStreamingIfNeeded(threadID: threadID, reason: reason)
        case .thoughtDelta:
            // 思考流不入正文（渲染归 B-M2 之后决策），仅保守记录类型。
            logger.debug("收到 thoughtDelta（不入正文）：thread=\(threadID.prefix(8))…")
        case .toolCallStarted, .toolCallUpdated:
            applyToolEvent(event, threadID: threadID)
        case .permissionRequested:
            // 响应由 ACPClient 的 default deny 处理（M2-005 接策略器），本层不重复决策。
            break
        case .userTextDelta, .notice, .unknown:
            logger.debug("收到非主对话事件（保守记录，仅类型）：thread=\(threadID.prefix(8))…")
        }
    }

    private func appendDelta(threadID: String, text: String) {
        guard var ctx = contexts[threadID],
              let messageID = ctx.streamingMessageID,
              let index = ctx.messages.firstIndex(where: { $0.id == messageID }) else {
            logger.debug("收到无流式占位的 delta（保守记录）：thread=\(threadID.prefix(8))…")
            return
        }
        ctx.messages[index].content += text
        ctx.messages[index].updatedAt = now()
        ctx.pendingDelta += text
        if ctx.phase == .sending { ctx.phase = .streaming }
        if now().timeIntervalSince(ctx.lastFlush) >= flushInterval {
            flushPending(&ctx)
        }
        contexts[threadID] = ctx
        if threadID == activeThreadID { publish() }
    }

    private func completeStreaming(threadID: String, stopReason: String) {
        guard var ctx = contexts[threadID], let messageID = ctx.streamingMessageID else {
            logger.debug("收到无流式占位的 completed（保守记录）：stopReason=\(stopReason)")
            return
        }
        finishStreaming(&ctx, messageID: messageID, status: .completed)
        ctx.phase = .completed
        contexts[threadID] = ctx
        if threadID == activeThreadID { publish() }
    }

    private func failStreamingIfNeeded(threadID: String, reason: String) {
        guard var ctx = contexts[threadID], let messageID = ctx.streamingMessageID else { return }
        finishStreaming(&ctx, messageID: messageID, status: .failed)
        ctx.phase = .failed(retryable: Self.isRetryable(reason: reason), reason: reason)
        contexts[threadID] = ctx
        if threadID == activeThreadID { publish() }
    }

    /// 事件流终止（子进程死亡/断开）：流式中的消息标记 interrupted，保留已收内容。
    private func streamEnded(threadID: String) {
        guard let ctx = contexts[threadID],
              ctx.streamingMessageID != nil || !ctx.toolCallMessageIDs.isEmpty else { return }
        interrupt(threadID: threadID)
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
    private func applyToolEvent(_ event: AgentEvent, threadID: String) {
        guard var ctx = contexts[threadID],
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
                    id: UUID().uuidString, threadID: threadID, role: .assistant, kind: .toolCall,
                    content: content, sequence: try messages.nextSequence(threadID: threadID),
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
        contexts[threadID] = ctx
        if threadID == activeThreadID { publish() }
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

    /// 工具摘要编码（不存完整 ACP SDK 对象，只存聚合后的 ``ToolCallRecord``）。
    private static func encodeToolMetadata(_ record: ToolCallRecord) -> String? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
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
}
