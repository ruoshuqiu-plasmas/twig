import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// 多主线程（M4-007/008，DEC-10）测试：
/// THREAD-01 双线程数据与 session 独立、THREAD-02 快速切换流式不串线、
/// THREAD-03 各自 project_root、自动标题生成、重命名不动最近活动排序、
/// 线程列表 VM 的切换/创建/重命名逻辑。
/// 全部使用内存库 + FakeDriver，不派生真实子进程（额度零消耗）。
@Suite("多主线程（M4-007/008）")
@MainActor
struct ThreadListViewModelTests {

    typealias FakeDriver = BranchSessionCoordinatorTests.FakeDriver

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private struct World {
        let store: ConversationStore
        let driver: FakeDriver
        let list: ThreadListViewModel
        let threads: ThreadRepository
        let messages: MessageRepository
    }

    private func makeWorld() throws -> World {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let list = ThreadListViewModel(threads: threads, store: store)
        return World(store: store, driver: driver, list: list, threads: threads, messages: messages)
    }

    /// 轮询等待条件成立（VM 异步 Task 落定的测试桥）。
    private func waitUntil(
        _ description: String,
        condition: () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待超时：\(description)")
    }

    @Test("THREAD-01/03：双线程数据与 session 独立、各自 project_root")
    func twoThreadsIndependent() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(title: "线程甲", projectRoot: "/tmp/a")
        try await world.store.newConversation(title: "线程乙", projectRoot: "/tmp/b")

        // 各自独立 session（owner 与 cwd 各自正确，THREAD-03）。
        #expect(await world.driver.sessionCount == 2)
        let sessions = try await world.threads.listThreads()
        #expect(sessions.count == 2)
        let threadA = try #require(sessions.first { $0.title == "线程甲" })
        let threadB = try #require(sessions.first { $0.title == "线程乙" })
        #expect(threadA.projectRoot == "/tmp/a")
        #expect(threadB.projectRoot == "/tmp/b")

        // 当前活跃 = 乙；发一条消息 → 只落在乙的 session 与消息表。
        try await world.store.send(text: "乙的问题")
        let sessionB = await world.driver.sessionID(at: 1)
        #expect(await world.driver.prompts(for: sessionB) == ["乙的问题"])
        #expect(try world.messages.messages(threadID: threadA.id).isEmpty)
        #expect(try world.messages.messages(threadID: threadB.id).count == 2)  // user + 占位

        // 切回甲 → 新发言进甲的 session，互不串线。
        try await world.store.switchToThread(id: threadA.id)
        try await world.store.send(text: "甲的问题")
        let sessionA = await world.driver.sessionID(at: 0)
        #expect(await world.driver.prompts(for: sessionA) == ["甲的问题"])
        #expect(try world.messages.messages(threadID: threadA.id).count == 2)
        #expect(try world.messages.messages(threadID: threadB.id).count == 2)
    }

    @Test("THREAD-02：流式中快速反复切换，delta 不串线")
    func rapidSwitchNoCrossTalk() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(title: "线程甲", projectRoot: "/tmp/a")
        try await world.store.newConversation(title: "线程乙", projectRoot: "/tmp/b")
        let all = try await world.threads.listThreads()
        let threadA = try #require(all.first { $0.title == "线程甲" })
        let threadB = try #require(all.first { $0.title == "线程乙" })
        let sessionA = await world.driver.sessionID(at: 0)
        let sessionB = await world.driver.sessionID(at: 1)

        // 乙开始流式（当前活跃）。
        try await world.store.send(text: "乙的问题")
        await world.driver.emit(sessionID: sessionB, .textDelta(sessionID: sessionB, text: "乙-1"))

        // 快速反复切换甲↔乙，期间乙继续流式、甲也开始流式。
        try await world.store.switchToThread(id: threadA.id)
        await world.driver.emit(sessionID: sessionB, .textDelta(sessionID: sessionB, text: "乙-2"))
        try await world.store.send(text: "甲的问题")
        await world.driver.emit(sessionID: sessionA, .textDelta(sessionID: sessionA, text: "甲-1"))
        try await world.store.switchToThread(id: threadB.id)
        await world.driver.emit(sessionID: sessionB, .textDelta(sessionID: sessionB, text: "乙-3"))
        try await world.store.switchToThread(id: threadA.id)
        await world.driver.emit(sessionID: sessionA, .textDelta(sessionID: sessionA, text: "甲-2"))
        await world.driver.emit(sessionID: sessionA, .completed(sessionID: sessionA, stopReason: "end_turn"))
        await world.driver.emit(sessionID: sessionB, .completed(sessionID: sessionB, stopReason: "end_turn"))

        // 事件经消费循环异步处理：等两个会话都收终态再断言。
        try await waitUntil("两个会话的 assistant 消息均 completed") {
            let a = try? world.messages.messages(threadID: threadA.id)
            let b = try? world.messages.messages(threadID: threadB.id)
            return a?.first { $0.role == .assistant }?.status == .completed
                && b?.first { $0.role == .assistant }?.status == .completed
        }

        // 数据面：各自会话只含各自内容，无串字。
        let messagesA = try world.messages.messages(threadID: threadA.id)
        let messagesB = try world.messages.messages(threadID: threadB.id)
        let assistantA = try #require(messagesA.first { $0.role == .assistant })
        let assistantB = try #require(messagesB.first { $0.role == .assistant })
        #expect(assistantA.content == "甲-1甲-2")
        #expect(assistantB.content == "乙-1乙-2乙-3")
        #expect(assistantA.status == .completed)
        #expect(assistantB.status == .completed)

        // 切回乙：快照呈现乙的完整历史（切回 UI 归视图层，能力在 store）。
        try await world.store.switchToThread(id: threadB.id)
        let snapshot = await world.store.currentSnapshot()
        #expect(snapshot.threadID == threadB.id)
        #expect(snapshot.messages.first { $0.role == .assistant }?.content == "乙-1乙-2乙-3")
    }

    @Test("DEC-10 自动标题：默认标题主线首条问题落库后自动改名（截 20 字）")
    func autoTitleFromFirstQuestion() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(projectRoot: "/tmp/a")
        let thread = try #require(try await world.threads.listThreads().first)
        #expect(thread.title == "新对话")

        try await world.store.send(text: "这是一个很长很长很长很长很长很长的第一个问题")
        let renamed = try #require(try await world.threads.listThreads().first)
        #expect(renamed.title.count == 20)
        #expect(renamed.title.hasPrefix("这是一个很长"))

        // 第二条消息不再改名。
        try await world.store.send(text: "第二个问题")
        #expect(try await world.threads.listThreads().first?.title == renamed.title)
    }

    @Test("显式标题不被自动标题覆盖")
    func explicitTitlePreserved() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(title: "项目复盘", projectRoot: "/tmp/a")
        try await world.store.send(text: "第一个问题")
        #expect(try await world.threads.listThreads().first?.title == "项目复盘")
    }

    @Test("列表 VM：最近活动排序 + 重命名不改动排序（DEC-10）")
    func listSortAndRename() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(title: "甲", projectRoot: "/tmp/a")
        try await world.store.newConversation(title: "乙", projectRoot: "/tmp/b")
        let all = try await world.threads.listThreads()
        let threadA = try #require(all.first { $0.title == "甲" })
        let threadB = try #require(all.first { $0.title == "乙" })

        // 乙更新（后创建）→ 列表乙在前。
        world.list.refresh()
        #expect(world.list.threads.map(\.title) == ["乙", "甲"])

        // 重命名甲 → 标题变了但 updated_at 不动，排序不变。
        world.list.beginRename(threadID: threadA.id)
        world.list.renameDraft = "甲（已改名）"
        world.list.commitRename()
        #expect(world.list.threads.map(\.title) == ["乙", "甲（已改名）"])
        #expect(try await world.threads.listThreads().first { $0.id == threadA.id }?.updatedAt
                == threadA.updatedAt)

        // 空草稿 = 取消，不改名。
        world.list.beginRename(threadID: threadB.id)
        world.list.renameDraft = "   "
        world.list.commitRename()
        #expect(try await world.threads.listThreads().first { $0.id == threadB.id }?.title == "乙")
    }

    @Test("列表 VM：切换线程经 store 激活（快照同步活跃 id）")
    func switchViaList() async throws {
        let world = try makeWorld()
        try await world.store.newConversation(title: "甲", projectRoot: "/tmp/a")
        try await world.store.newConversation(title: "乙", projectRoot: "/tmp/b")
        let all = try await world.threads.listThreads()
        let threadA = try #require(all.first { $0.title == "甲" })

        world.list.start()
        world.list.switchTo(threadID: threadA.id)
        try await waitUntil("切换后快照活跃线程=甲") {
            await world.store.currentSnapshot().threadID == threadA.id
        }
        try await waitUntil("VM 活跃 id 同步") { world.list.activeThreadID == threadA.id }
        world.list.stop()
    }

    @Test("列表 VM：创建线程（显式标题 + project_root）并激活")
    func createViaList() async throws {
        let world = try makeWorld()
        world.list.createThread(title: "新线程", projectRoot: "/tmp/c")
        try await waitUntil("新线程落库") {
            ((try? await world.threads.listThreads()) ?? []).contains { $0.title == "新线程" }
        }
        let thread = try #require(try await world.threads.listThreads().first { $0.title == "新线程" })
        #expect(thread.projectRoot == "/tmp/c")
        #expect(await world.store.currentSnapshot().threadID == thread.id)
    }
}
