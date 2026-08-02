import Foundation
import Logging

/// session 续接失败原因（M4-010，REC-02 降级路径的判定依据）。
public enum SessionLoadError: Error, Sendable, Equatable {
    /// agent 未声明 `session/load` 能力（握手 agentCapabilities）。
    case unsupported
    /// load 调用本身失败（session 已不存在、协议错误等）。
    case failed(String)
}

/// 生产环境 ``ConversationDriver`` 实现（任务 M1-012 接线）：
/// 委托 ACPClient 发 prompt、SessionStore 做 session 映射与按 session 事件路由。
/// 核心约束：UI/会话层不直接触碰 ACP SDK 类型，全部经此适配。
public struct LiveConversationDriver: ConversationDriver {

    private let client: ACPClient
    private let sessionStore: SessionStore
    /// load 重放安静窗口（G0 §2：历史在响应后异步突发到达；窗口内事件由临时订阅吞掉，
    /// 防止重放的 tool_call 事件落成重复工具卡片）。
    private let replaySettle: Duration
    private let logger: Logger

    public init(
        client: ACPClient,
        sessionStore: SessionStore,
        replaySettle: Duration = .milliseconds(500),
        logger: Logger = Logger(label: "twig.conversation.driver")
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.replaySettle = replaySettle
        self.logger = logger
    }

    public func makeSession(cwd: String, owner: SessionStore.Owner) async throws -> String {
        let sessionID = try await client.newSession(cwd: cwd)
        try await sessionStore.register(sessionID: sessionID, owner: owner)
        return sessionID
    }

    public func loadSession(sessionID: String, cwd: String, owner: SessionStore.Owner) async throws {
        let capable = await client.supportsLoadSession
        logger.debug("loadSession 尝试：capable=\(capable) session=\(sessionID.prefix(8))…")
        guard capable else {
            throw SessionLoadError.unsupported
        }
        // 先挂临时订阅吞重放（SessionStore 不做事件缓冲，正式消费在窗口后才订阅）。
        let drain = Task { [sessionStore] in
            for await _ in await sessionStore.events(for: sessionID) {}
        }
        do {
            _ = try await client.loadSession(cwd: cwd, sessionID: sessionID)
            try await Task.sleep(for: replaySettle)
        } catch {
            drain.cancel()
            logger.warning("loadSession 失败：\(error.localizedDescription)")
            if error is SessionLoadError { throw error }
            throw SessionLoadError.failed(error.localizedDescription)
        }
        drain.cancel()
        try await sessionStore.register(sessionID: sessionID, owner: owner)
    }

    public func sendPrompt(sessionID: String, text: String) async throws {
        try await client.prompt(sessionID: sessionID, text: text)
    }

    public func events(for sessionID: String) async -> AsyncStream<AgentEvent> {
        await sessionStore.events(for: sessionID)
    }
}
