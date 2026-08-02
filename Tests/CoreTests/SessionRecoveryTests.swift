import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// 启动恢复与 session 续接（M4-009/010）测试：
/// REC-01 有映射且 load 成功 → sessionResumed（不新建 session）；
/// REC-02 load 失败 → sessionUnavailable + 退化新建、历史无损、可继续对话；
/// 无映射 → localHistoryAvailable；THREAD-04 恢复上次选中线程；
/// 进程重连 → sessionRecreated；恢复文案四态映射。
/// 全部使用内存库 + FakeDriver，不派生真实子进程（额度零消耗）。
@Suite("启动恢复与 session 续接（M4-009/010）")
@MainActor
struct SessionRecoveryTests {

    typealias FakeDriver = BranchSessionCoordinatorTests.FakeDriver

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private struct World {
        let store: ConversationStore
        let driver: FakeDriver
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
        return World(store: store, driver: driver, threads: threads, messages: messages)
    }

    /// 造一条带历史消息与持久化 session 映射的线程（模拟上次运行留下的库）。
    private func seedThread(
        _ world: World, id: String, title: String, sessionID: String?, at date: Date
    ) throws {
        try world.threads.createThread(id: id, title: title, projectRoot: "/tmp/\(id)", at: date)
        try world.messages.insert(Message(
            id: "m-\(id)", threadID: id, branchID: nil, role: .user, kind: .text,
            content: "历史问题", sequence: 1, status: .completed,
            createdAt: date, updatedAt: date, metadataJSON: nil
        ))
        if let sessionID {
            try world.threads.saveMapping(sessionID: sessionID, owner: .thread(id))
        }
    }

    @Test("REC-01：有映射且 load 成功 → sessionResumed，不新建 session，可在续接 session 上继续")
    func resumeSuccess() async throws {
        let world = try makeWorld()
        try seedThread(world, id: "t1", title: "甲", sessionID: "sess-old", at: t0)

        try await world.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: nil)

        #expect(await world.driver.loadCount == 1)
        #expect(await world.driver.loadedSessionID(at: 0) == "sess-old")
        #expect(await world.driver.sessionCount == 0)  // 未新建
        let snapshot = await world.store.currentSnapshot()
        #expect(snapshot.threadID == "t1")
        #expect(snapshot.recovery == .sessionResumed)
        #expect(snapshot.messages.count == 1)  // 本地历史完整呈现

        try await world.store.send(text: "续接后的新问题")
        #expect(await world.driver.prompts(for: "sess-old") == ["续接后的新问题"])
    }

    @Test("REC-02：load 失败 → sessionUnavailable + 退化新建 session，历史无损、可继续对话")
    func resumeFailureDegrades() async throws {
        let world = try makeWorld()
        try seedThread(world, id: "t1", title: "甲", sessionID: "sess-gone", at: t0)
        await world.driver.failNextLoad(SessionLoadError.failed("session not found"))

        try await world.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: nil)

        #expect(await world.driver.loadCount == 1)
        #expect(await world.driver.sessionCount == 1)  // 退化新建
        let snapshot = await world.store.currentSnapshot()
        #expect(snapshot.recovery == .sessionUnavailable)
        #expect(snapshot.messages.count == 1)

        // 降级后可继续对话（走新建 session，不触碰已死的旧 id）。
        try await world.store.send(text: "新问题")
        let newSession = await world.driver.sessionID(at: 0)
        #expect(await world.driver.prompts(for: newSession) == ["新问题"])
        #expect(await world.driver.prompts(for: "sess-gone").isEmpty)
    }

    @Test("无持久化映射 → localHistoryAvailable（本地历史可见，不宣称续接）")
    func noMappingLocalHistory() async throws {
        let world = try makeWorld()
        try seedThread(world, id: "t1", title: "甲", sessionID: nil, at: t0)

        try await world.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: nil)

        #expect(await world.driver.loadCount == 0)
        #expect(await world.driver.sessionCount == 1)
        #expect(await world.store.currentSnapshot().recovery == .localHistoryAvailable)
    }

    @Test("THREAD-04：恢复上次选中线程（而非最近活动线程）")
    func restoreLastSelected() async throws {
        let world = try makeWorld()
        try seedThread(world, id: "t-old", title: "旧选中", sessionID: nil, at: t0)
        try seedThread(world, id: "t-recent", title: "最近活动", sessionID: nil, at: t0.addingTimeInterval(600))

        try await world.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: "t-old")
        #expect(await world.store.currentSnapshot().threadID == "t-old")

        // 选中记录失效（线程已不存在）→ 回退最近活动线程。
        let world2 = try makeWorld()
        try seedThread(world2, id: "t-recent", title: "最近活动", sessionID: nil, at: t0)
        try await world2.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: "t-deleted")
        #expect(await world2.store.currentSnapshot().threadID == "t-recent")
    }

    @Test("REC-04 数据面：进程重连重建 session 后标记 sessionRecreated")
    func reconnectMarksRecreated() async throws {
        let world = try makeWorld()
        try seedThread(world, id: "t1", title: "甲", sessionID: nil, at: t0)
        try await world.store.openRestoredOrCreate(projectRoot: "/tmp", lastSelectedThreadID: nil)
        #expect(await world.store.currentSnapshot().recovery == .localHistoryAvailable)

        try await world.store.renewSessions()
        #expect(await world.store.currentSnapshot().recovery == .sessionRecreated)
        #expect(await world.driver.sessionCount == 2)  // 初始 + 重建
    }

    @Test("SelectedThreadStore：保存/读取上次选中线程")
    func selectedThreadStoreRoundtrip() {
        let defaults = UserDefaults(suiteName: "twig.test.\(UUID().uuidString)")!
        let store = SelectedThreadStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save("t-123")
        #expect(store.load() == "t-123")
    }

    @Test("恢复文案四态与能力表述一致（不制造「已续接」假象）")
    func recoveryTexts() {
        #expect(MainChatViewModel.recoveryText(.sessionResumed).contains("续接"))
        #expect(MainChatViewModel.recoveryText(.sessionUnavailable).contains("不可续接"))
        #expect(MainChatViewModel.recoveryText(.localHistoryAvailable).contains("新会话"))
        #expect(MainChatViewModel.recoveryText(.sessionRecreated).contains("新会话"))
    }
}
