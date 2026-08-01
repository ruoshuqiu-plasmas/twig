import Foundation
import Testing
@testable import Core
import Shared

/// 主对话状态机测试（M1-012，§5.7）。
/// 全部使用内存库 + 假驱动，不派生真实子进程（无需 .serialized）。
@Suite("ConversationStore：主对话状态机与流式写入")
struct ConversationStoreTests {

    /// 假驱动：记录 session/prompt，事件由测试手动注入。
    final class FakeDriver: ConversationDriver, @unchecked Sendable {
        private(set) var sessions: [(cwd: String, owner: SessionStore.Owner, sessionID: String)] = []
        private(set) var sentPrompts: [(sessionID: String, text: String)] = []
        private var continuations: [String: AsyncStream<AgentEvent>.Continuation] = [:]
        private var sessionCounter = 0
        var promptError: (any Error)?

        func makeSession(cwd: String, owner: SessionStore.Owner) async throws -> String {
            sessionCounter += 1
            let sessionID = "sess-\(sessionCounter)"
            sessions.append((cwd, owner, sessionID))
            return sessionID
        }

        func sendPrompt(sessionID: String, text: String) async throws {
            sentPrompts.append((sessionID, text))
            if let promptError { throw promptError }
        }

        func events(for sessionID: String) async -> AsyncStream<AgentEvent> {
            AsyncStream { continuation in continuations[sessionID] = continuation }
        }

        func emit(sessionID: String, _ event: AgentEvent) {
            continuations[sessionID]?.yield(event)
        }

        func endStream(sessionID: String) {
            continuations[sessionID]?.finish()
        }
    }

    struct Boom: Error, Sendable {}

    private func makeStore(flushInterval: TimeInterval = 0) async throws -> (ConversationStore, FakeDriver, MessageRepository, ThreadRepository) {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: flushInterval
        )
        return (store, driver, messages, threads)
    }

    /// 轮询等待异步条件成立（消费循环在后台 Task 中跑）。
    private func waitFor(
        _ description: String,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await withTimeout(seconds: 5, operation: description) {
            while await !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    // MARK: - 发送即存

    @Test("发送即存：user 立即 completed、assistant 占位 streaming、sequence 递增")
    func sendPersistsImmediately() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")

        try await store.send(text: "你好")

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.threadID != nil)
        #expect(snapshot.messages.count == 2)
        #expect(snapshot.messages[0].role == .user && snapshot.messages[0].status == .completed)
        #expect(snapshot.messages[0].content == "你好")
        #expect(snapshot.messages[1].role == .assistant && snapshot.messages[1].status == .streaming)
        #expect(snapshot.messages.map(\.sequence) == [1, 2])
        #expect(snapshot.phase == .sending)

        // 落库验证（不只看内存快照）。
        let stored = try messages.messages(threadID: snapshot.threadID!)
        #expect(stored.count == 2 && stored[1].status == .streaming)
        #expect(driver.sentPrompts.map(\.text) == ["你好"])
    }

    // MARK: - 流式追加与完成

    @Test("delta 顺序追加同一消息，completed 原子置终态且内容完整落库")
    func streamingLifecycle() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "问")
        let sessionID = driver.sessions[0].sessionID

        driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "你"))
        driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "好"))
        try await waitFor("delta 生效") {
            await store.currentSnapshot().messages.last?.content == "你好"
        }
        #expect(await store.currentSnapshot().phase == .streaming)

        driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("completed 生效") {
            await store.currentSnapshot().phase == .completed
        }

        let threadID = await store.currentSnapshot().threadID!
        let stored = try messages.messages(threadID: threadID)
        #expect(stored[1].content == "你好")
        #expect(stored[1].status == .completed)
    }

    // MARK: - 失败分类

    @Test("failed 事件：进程/链路错误 retryable，协议参数错误 nonRetryable")
    func failureClassification() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "问")
        let sessionID = driver.sessions[0].sessionID

        driver.emit(sessionID: sessionID, .failed(sessionID: sessionID, reason: "connection lost"))
        try await waitFor("failed 生效") {
            if case .failed = await store.currentSnapshot().phase { return true }
            return false
        }
        guard case .failed(let retryable, _) = await store.currentSnapshot().phase else {
            Issue.record("应为 failed 阶段"); return
        }
        #expect(retryable == true)
        let threadID = await store.currentSnapshot().threadID!
        #expect(try messages.messages(threadID: threadID)[1].status == .failed)

        // 协议参数错误 → nonRetryable。
        try await store.send(text: "再问")
        driver.emit(sessionID: sessionID, .failed(sessionID: sessionID, reason: "invalid params"))
        try await waitFor("第二次 failed 生效") {
            if case .failed(let retryable, _) = await store.currentSnapshot().phase { return !retryable }
            return false
        }
        #expect(try messages.messages(threadID: threadID).last?.status == .failed)
    }

    // MARK: - 中断

    @Test("事件流中途终止：保留已收内容并标记 interrupted，不伪装完整")
    func interruptionKeepsPartialContent() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "问")
        let sessionID = driver.sessions[0].sessionID

        driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "半截"))
        try await waitFor("delta 生效") {
            await store.currentSnapshot().messages.last?.content == "半截"
        }
        driver.endStream(sessionID: sessionID)
        try await waitFor("interrupted 生效") {
            await store.currentSnapshot().phase == .interrupted
        }

        let threadID = await store.currentSnapshot().threadID!
        let stored = try messages.messages(threadID: threadID)
        #expect(stored[1].content == "半截")
        #expect(stored[1].status == .interrupted)
    }

    // MARK: - 跨线程路由

    @Test("跨线程路由：流式中切线程，事件仍写入原线程（G1-06 结构性回归）")
    func crossThreadRouting() async throws {
        let (store, driver, messages, threads) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "A")
        let thread1 = await store.currentSnapshot().threadID!
        let session1 = driver.sessions[0].sessionID

        // 流式中切到新线程。
        try await store.newConversation(projectRoot: "/tmp")
        try await store.send(text: "B")
        let thread2 = await store.currentSnapshot().threadID!
        let session2 = driver.sessions[1].sessionID
        #expect(thread1 != thread2)

        // 旧线程的 delta 与终态在后台继续写入 thread1，活跃快照不受污染。
        driver.emit(sessionID: session1, .textDelta(sessionID: session1, text: "甲"))
        driver.emit(sessionID: session2, .textDelta(sessionID: session2, text: "乙"))
        try await waitFor("thread2 delta 落库") {
            (try? messages.messages(threadID: thread2).last?.content) == "乙"
        }
        try await waitFor("thread1 delta 落库") {
            (try? messages.messages(threadID: thread1).last?.content) == "甲"
        }
        #expect(await store.currentSnapshot().messages.last?.content == "乙")

        // 切回 thread1：内容正确恢复。
        try await store.switchToThread(id: thread1)
        #expect(await store.currentSnapshot().threadID == thread1)
        #expect(await store.currentSnapshot().messages.last?.content == "甲")

        let allThreads = try threads.listThreads()
        #expect(allThreads.count == 2)
    }

    // MARK: - 重试

    @Test("重试：生成新 assistant 消息并重发，旧消息状态不改写")
    func retryCreatesNewRequest() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "问")
        let sessionID = driver.sessions[0].sessionID
        driver.emit(sessionID: sessionID, .failed(sessionID: sessionID, reason: "connection lost"))
        try await waitFor("failed 生效") {
            if case .failed = await store.currentSnapshot().phase { return true }
            return false
        }

        try await store.retry()
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.messages.count == 3, "重试应追加新 assistant 消息")
        #expect(snapshot.messages[1].status == .failed, "旧消息状态不改写")
        #expect(snapshot.messages[2].status == .streaming)
        #expect(driver.sentPrompts.map(\.text) == ["问", "问"], "重试产生明确的新请求")

        // 新请求正常流式完成。
        driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "答"))
        driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("重试完成") {
            await store.currentSnapshot().phase == .completed
        }
        let threadID = await store.currentSnapshot().threadID!
        #expect(try messages.messages(threadID: threadID).last?.content == "答")
    }

    // MARK: - 流式中禁发

    @Test("sending/streaming 阶段重复发送被忽略（不重复扣费）")
    func duplicateSendIgnoredWhileStreaming() async throws {
        let (store, driver, _, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "第一条")
        try await store.send(text: "第二条")

        #expect(driver.sentPrompts.map(\.text) == ["第一条"])
        #expect(await store.currentSnapshot().messages.count == 2)
    }

    // MARK: - 进程中断与恢复（M1-013）

    @Test("进程中断：全部线程的流式消息一并标记 interrupted（G1-07）")
    func interruptAllStreaming() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "A")
        let thread1 = await store.currentSnapshot().threadID!
        try await store.newConversation(projectRoot: "/tmp")
        try await store.send(text: "B")
        let thread2 = await store.currentSnapshot().threadID!

        // 两个线程都在流式中，模拟子进程被杀。
        await store.interruptAllStreaming()

        #expect(try messages.messages(threadID: thread1).last?.status == .interrupted)
        #expect(try messages.messages(threadID: thread2).last?.status == .interrupted)
        #expect(await store.currentSnapshot().phase == .interrupted)
        _ = driver
    }

    @Test("重连重建 session：新 sessionID 生效、可继续对话、旧中断消息不改写（G1-08）")
    func renewSessionsAfterReconnect() async throws {
        let (store, driver, messages, _) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await store.send(text: "问")
        let threadID = await store.currentSnapshot().threadID!
        await store.interruptAllStreaming()
        #expect(driver.sessions.count == 1)

        // 重连：换驱动 + 重建 session。
        let newDriver = FakeDriver()
        await store.updateDriver(newDriver)
        try await store.renewSessions()
        #expect(newDriver.sessions.count == 1, "应为已知线程重建一个全新 session")
        #expect(newDriver.sessions[0].owner == .thread(threadID))

        // 新 session 上可正常对话（旧 session 不做续接假象）。
        try await store.send(text: "再问")
        let sessionID = newDriver.sessions[0].sessionID
        newDriver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "答"))
        newDriver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("重建后对话完成") {
            await store.currentSnapshot().phase == .completed
        }

        let stored = try messages.messages(threadID: threadID)
        #expect(stored.map(\.status) == [.completed, .interrupted, .completed, .completed],
               "旧中断消息不改写，新轮次正常完成")
        #expect(stored.last?.content == "答")
    }
}
