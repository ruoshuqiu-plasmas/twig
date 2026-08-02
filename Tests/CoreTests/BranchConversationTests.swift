import Foundation
import GRDB
import Testing
@testable import Core
import Shared

/// 支线会话维度测试（M3-008）：ConversationStore 泛化为 ConversationKey 后的支线行为。
/// 全部使用内存库 + 假驱动，不派生真实子进程（无需 .serialized）。
@Suite("ConversationStore：支线会话（ConversationKey 维度）")
struct BranchConversationTests {

    /// 假驱动：记录 session/prompt，事件由测试手动注入（模式照 ConversationStoreTests）。
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

        func loadSession(sessionID: String, cwd: String, owner: SessionStore.Owner) async throws {}

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

    private func makeStore(flushInterval: TimeInterval = 0) async throws
        -> (ConversationStore, FakeDriver, MessageRepository, AppDatabase)
    {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: flushInterval
        )
        return (store, driver, messages, appDB)
    }

    /// 插入 branches 行（messages.branch_id 外键依赖；本任务不测 BranchRepository，直接落行）。
    private func insertBranch(_ appDB: AppDatabase, id: String, threadID: String) throws {
        let now = Date()
        let branch = Branch(id: id, threadID: threadID, anchorQuote: "引文", createdAt: now, updatedAt: now)
        try appDB.db.write { db in try branch.insert(db) }
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

    // MARK: - 支线发送与流式

    @Test("支线发送→流式→completed：消息落库带 branchID，主线消息列表不受影响")
    func branchSendStreamingLifecycle() async throws {
        let (store, driver, messages, appDB) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        try await store.send(text: "主线问")
        let branchID = "branch-1"
        try insertBranch(appDB, id: branchID, threadID: threadID)

        let opened = try await store.openBranch(branchID: branchID, threadID: threadID, projectRoot: "/tmp")
        #expect(opened.branchID == branchID && opened.threadID == threadID)
        #expect(opened.messages.isEmpty && opened.phase == .idle)
        #expect(driver.sessions.count == 2)
        #expect(driver.sessions[1].owner == .branch(branchID))

        try await store.sendBranchMessage(branchID: branchID, text: "支线问")
        let branchSession = driver.sessions[1].sessionID
        #expect(driver.sentPrompts.last?.sessionID == branchSession)
        #expect(driver.sentPrompts.last?.text == "支线问")

        driver.emit(sessionID: branchSession, .textDelta(sessionID: branchSession, text: "支"))
        driver.emit(sessionID: branchSession, .textDelta(sessionID: branchSession, text: "线答"))
        try await waitFor("支线 delta 生效") {
            await store.currentBranchSnapshot(branchID: branchID).messages.last?.content == "支线答"
        }
        #expect(await store.currentBranchSnapshot(branchID: branchID).phase == .streaming)

        driver.emit(sessionID: branchSession, .completed(sessionID: branchSession, stopReason: "end_turn"))
        try await waitFor("支线 completed 生效") {
            await store.currentBranchSnapshot(branchID: branchID).phase == .completed
        }

        // 落库验证：支线消息带 branchID，sequence 独立递增。
        let branchStored = try messages.messages(threadID: threadID, branchID: branchID)
        #expect(branchStored.count == 2)
        #expect(branchStored.allSatisfy { $0.branchID == branchID })
        #expect(branchStored.map(\.sequence) == [1, 2])
        #expect(branchStored[1].content == "支线答" && branchStored[1].status == .completed)

        // 主线消息列表不受支线写入影响（branchID 恒为 nil，仍只有主线两条）。
        let mainStored = try messages.messages(threadID: threadID)
        #expect(mainStored.count == 2)
        #expect(mainStored.allSatisfy { $0.branchID == nil })
        #expect(await store.currentSnapshot().messages.count == 2)
        #expect(await store.currentSnapshot().branchID == nil)
    }

    // MARK: - 主线与多支线并发不串线（BR-17 假层验证）

    @Test("主线 + 两支线并发注入 delta：各自写入本会话，互不串线（BR-17）")
    func mainlineAndBranchesDoNotCross() async throws {
        let (store, driver, messages, appDB) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        try await store.send(text: "主线问")
        let mainSession = driver.sessions[0].sessionID

        try insertBranch(appDB, id: "branch-1", threadID: threadID)
        try insertBranch(appDB, id: "branch-2", threadID: threadID)
        try await store.openBranch(branchID: "branch-1", threadID: threadID, projectRoot: "/tmp")
        try await store.sendBranchMessage(branchID: "branch-1", text: "支线一问")
        try await store.openBranch(branchID: "branch-2", threadID: threadID, projectRoot: "/tmp")
        try await store.sendBranchMessage(branchID: "branch-2", text: "支线二问")
        let session1 = driver.sessions[1].sessionID
        let session2 = driver.sessions[2].sessionID

        // 三个会话交错注入 delta 与终态。
        driver.emit(sessionID: mainSession, .textDelta(sessionID: mainSession, text: "主"))
        driver.emit(sessionID: session1, .textDelta(sessionID: session1, text: "甲"))
        driver.emit(sessionID: session2, .textDelta(sessionID: session2, text: "乙"))
        driver.emit(sessionID: mainSession, .textDelta(sessionID: mainSession, text: "线"))
        driver.emit(sessionID: session1, .textDelta(sessionID: session1, text: "一"))
        driver.emit(sessionID: session2, .textDelta(sessionID: session2, text: "二"))
        driver.emit(sessionID: session1, .completed(sessionID: session1, stopReason: "end_turn"))
        driver.emit(sessionID: session2, .completed(sessionID: session2, stopReason: "end_turn"))
        driver.emit(sessionID: mainSession, .completed(sessionID: mainSession, stopReason: "end_turn"))

        try await waitFor("三线终态落库") {
            let main = (try? messages.messages(threadID: threadID).last?.content) == "主线"
            let b1 = (try? messages.messages(threadID: threadID, branchID: "branch-1").last?.content) == "甲一"
            let b2 = (try? messages.messages(threadID: threadID, branchID: "branch-2").last?.content) == "乙二"
            return main && b1 && b2
        }

        // 活跃主线快照不受支线事件污染。
        #expect(await store.currentSnapshot().messages.last?.content == "主线")
        #expect(await store.currentSnapshot().phase == .completed)
        #expect(await store.currentBranchSnapshot(branchID: "branch-1").messages.last?.content == "甲一")
        #expect(await store.currentBranchSnapshot(branchID: "branch-2").messages.last?.content == "乙二")
        #expect(await store.currentBranchSnapshot(branchID: "branch-1").phase == .completed)
    }

    // MARK: - 支线重试

    @Test("支线重试：生成新 assistant 占位消息并重发，旧消息状态不改写")
    func retryBranchCreatesNewPlaceholder() async throws {
        let (store, driver, messages, appDB) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        let branchID = "branch-1"
        try insertBranch(appDB, id: branchID, threadID: threadID)
        try await store.openBranch(branchID: branchID, threadID: threadID, projectRoot: "/tmp")
        try await store.sendBranchMessage(branchID: branchID, text: "支线问")
        let branchSession = driver.sessions[1].sessionID

        driver.emit(sessionID: branchSession, .failed(sessionID: branchSession, reason: "connection lost"))
        try await waitFor("支线 failed 生效") {
            if case .failed = await store.currentBranchSnapshot(branchID: branchID).phase { return true }
            return false
        }

        try await store.retryBranch(branchID: branchID)
        let snapshot = await store.currentBranchSnapshot(branchID: branchID)
        #expect(snapshot.messages.count == 3, "重试应追加新 assistant 占位消息")
        #expect(snapshot.messages[1].status == .failed, "旧消息状态不改写")
        #expect(snapshot.messages[2].status == .streaming && snapshot.messages[2].role == .assistant)
        #expect(driver.sentPrompts.map(\.text) == ["支线问", "支线问"], "重试产生明确的新请求")

        // 落库验证：三条都在支线维度，sequence 独立递增。
        let stored = try messages.messages(threadID: threadID, branchID: branchID)
        #expect(stored.map(\.sequence) == [1, 2, 3])
        #expect(stored.allSatisfy { $0.branchID == branchID })
        #expect(try messages.messages(threadID: threadID).isEmpty, "主线不受影响")
    }

    // MARK: - 重连重建 session

    @Test("renewSessions：为主线与支线分别重建 session，owner 区分 thread/branch")
    func renewSessionsRebuildsMainAndBranch() async throws {
        let (store, driver, _, appDB) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        let branchID = "branch-1"
        try insertBranch(appDB, id: branchID, threadID: threadID)
        try await store.openBranch(branchID: branchID, threadID: threadID, projectRoot: "/tmp")
        #expect(driver.sessions.count == 2)

        let newDriver = FakeDriver()
        await store.updateDriver(newDriver)
        try await store.renewSessions()

        #expect(newDriver.sessions.count == 2, "主线与支线各重建一个全新 session")
        #expect(Set(newDriver.sessions.map(\.owner)) == [.thread(threadID), .branch(branchID)])
    }

    // MARK: - 种子消息 metadata

    @Test("支线 metadata 参数：编码进 user 消息 metadataJSON 落库（种子消息标记）")
    func branchMessageMetadataPersisted() async throws {
        let (store, driver, messages, appDB) = try await makeStore()
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        let branchID = "branch-1"
        try insertBranch(appDB, id: branchID, threadID: threadID)
        try await store.openBranch(branchID: branchID, threadID: threadID, projectRoot: "/tmp")

        try await store.sendBranchMessage(
            branchID: branchID, text: "背景：引文节选", metadata: ["kind": "seed_context"]
        )

        let stored = try messages.messages(threadID: threadID, branchID: branchID)
        #expect(stored.count == 2)
        #expect(stored[0].role == .user)
        #expect(stored[0].metadataJSON?.contains(#""kind":"seed_context""#) == true)
        #expect(stored[1].metadataJSON == nil, "占位 assistant 消息不带 metadata")
        #expect(driver.sentPrompts.last?.text == "背景：引文节选")

        // 未传 metadata 的普通支线消息 metadataJSON 为 nil。
        driver.endStream(sessionID: driver.sessions[1].sessionID)
        try await waitFor("中断收口") {
            await store.currentBranchSnapshot(branchID: branchID).phase == .interrupted
        }
        try await store.sendBranchMessage(branchID: branchID, text: "普通问")
        let again = try messages.messages(threadID: threadID, branchID: branchID)
        #expect(again.last(where: { $0.role == .user })?.metadataJSON == nil)
    }
}
