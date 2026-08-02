import Foundation

/// ``BranchSummarizer`` 生产实现（DEC-06，任务 M3-005）：用**临时独立 ACP session**
/// 压缩支线背景，不污染主线/支线历史。
///
/// 流程：`newSession` → 注册临时映射 → 订阅该 session 事件流 → `prompt` 摘要指令
/// → 聚合 ``AgentEvent/textDelta(sessionID:text:)`` 至 ``AgentEvent/completed(sessionID:stopReason:)``
/// → `SessionStore.remove` 摘除临时映射。
///
/// 注意：
/// - 临时 session 的 owner 使用合成 id（非真实支线行）：mappingStore 的落库 UPDATE
///   命中 0 行、无副作用，仅借 ``SessionStore`` 的按 session 事件路由与清理；
/// - 事件流须在 `prompt` 之前订阅（``SessionStore`` 不缓冲，见 LiveConversationDriver 同构）；
/// - 事件经双层 AsyncStream 缓冲，prompt 返回后循环排空即可收齐 delta 与 completed，无竞态；
/// - 超时用非结构化竞速实现（任务组会隐式等待不响应取消的子任务，见 doc/工程笔记.md），
///   与 Shared/TestSupport 的 withTimeout 同构，但本类型属生产代码，不依赖测试支撑；
/// - 真实 CLI 行为归 G3 真实验收；协议级主路径见 Tests/CoreTests/BranchContextAssemblerTests.swift。
public struct ACPSummarizer: BranchSummarizer {

    /// 摘要 prompt 模板（§7.5：保留事实、约束、未决问题和关键术语，输出纯文本摘要）。
    public static func makePrompt(background: String) -> String {
        """
        你是对话背景压缩器。请把下面的对话背景压缩为一段简明摘要，供后续支线对话作为上下文使用。
        要求：
        - 保留事实、约束、未决问题和关键术语；
        - 不添加背景中不存在的信息；
        - 输出纯文本摘要本身，不要任何前后缀说明或复述本指令。

        [对话背景]
        \(background)
        [背景结束]
        """
    }

    private let client: ACPClient
    private let sessionStore: SessionStore
    private let cwd: String
    private let timeoutSeconds: Double

    /// - Parameters:
    ///   - client: 已连接的 ACPClient（调用方负责生命周期）；
    ///   - sessionStore: 已 attach 到该 client 的事件路由；
    ///   - cwd: 临时 session 的工作目录（取线程 projectRoot）；
    ///   - timeoutSeconds: 单次摘要总超时（默认 120s；长背景生成较慢，取宽值）。
    public init(client: ACPClient, sessionStore: SessionStore, cwd: String, timeoutSeconds: Double = 120) {
        self.client = client
        self.sessionStore = sessionStore
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }

    public func summarize(background: String) async throws -> String {
        let sessionID = try await client.newSession(cwd: cwd)
        // 临时映射：owner 为合成 id（非真实支线行），mappingStore 落库命中 0 行无副作用。
        try await sessionStore.register(sessionID: sessionID, owner: .branch("summarizer-temp"))
        do {
            let summary = try await Self.withTimeout(seconds: timeoutSeconds, operation: "支线背景摘要") {
                // 订阅须先于 prompt（SessionStore 不缓冲事件）。
                let events = await sessionStore.events(for: sessionID)
                try await client.prompt(sessionID: sessionID, text: Self.makePrompt(background: background))
                var text = ""
                for await event in events {
                    switch event {
                    case .textDelta(_, let delta):
                        text += delta
                    case .completed:
                        guard !text.isEmpty else { throw BranchSummarizeError.emptyResult }
                        return text
                    case .failed(_, let reason):
                        throw BranchSummarizeError.agentFailed(reason: reason)
                    default:
                        continue
                    }
                }
                // 事件流在 completed 之前意外终结（路由关闭/进程死亡）。
                throw BranchSummarizeError.eventStreamEnded
            }
            try await sessionStore.remove(sessionID: sessionID)
            return summary
        } catch {
            try? await sessionStore.remove(sessionID: sessionID)
            throw error
        }
    }

    // MARK: - 非结构化超时竞速（工程笔记：任务组隐式等待坑）

    /// 一次性声明器（withTimeout 内部使用）。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// 到点抛 ``BranchSummarizeError/timeout(seconds:)``；超时被遗弃的任务挂起在后台，
    /// 不阻塞调用方（与 Shared/TestSupport/Timeout.swift 同构）。
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let value = try await body()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    work.cancel()
                    continuation.resume(throwing: BranchSummarizeError.timeout(seconds: seconds))
                }
            }
        }
    }
}

/// 摘要链路失败（由 ``BranchContextAssembler`` 包装为
/// ``BranchAssemblyError/summarizationFailed(reason:)``，不静默截断）。
public enum BranchSummarizeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 摘要生成超时。
    case timeout(seconds: Double)
    /// prompt 期间 agent 广播了失败事件。
    case agentFailed(reason: String)
    /// 事件流在 completed 之前意外终结。
    case eventStreamEnded
    /// completed 到达但未聚合到任何正文。
    case emptyResult

    public var description: String {
        switch self {
        case .timeout(let seconds):
            return "摘要生成超过 \(seconds)s 未完成"
        case .agentFailed(let reason):
            return "agent 摘要失败：\(reason)"
        case .eventStreamEnded:
            return "摘要事件流在 completed 之前意外终结"
        case .emptyResult:
            return "摘要结果为空"
        }
    }
}
