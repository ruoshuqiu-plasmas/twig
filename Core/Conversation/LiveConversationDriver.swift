import Foundation

/// 生产环境 ``ConversationDriver`` 实现（任务 M1-012 接线）：
/// 委托 ACPClient 发 prompt、SessionStore 做 session 映射与按 session 事件路由。
/// 核心约束：UI/会话层不直接触碰 ACP SDK 类型，全部经此适配。
public struct LiveConversationDriver: ConversationDriver {

    private let client: ACPClient
    private let sessionStore: SessionStore

    public init(client: ACPClient, sessionStore: SessionStore) {
        self.client = client
        self.sessionStore = sessionStore
    }

    public func makeSession(cwd: String, owner: SessionStore.Owner) async throws -> String {
        let sessionID = try await client.newSession(cwd: cwd)
        try await sessionStore.register(sessionID: sessionID, owner: owner)
        return sessionID
    }

    public func sendPrompt(sessionID: String, text: String) async throws {
        try await client.prompt(sessionID: sessionID, text: text)
    }

    public func events(for sessionID: String) async -> AsyncStream<AgentEvent> {
        await sessionStore.events(for: sessionID)
    }
}
