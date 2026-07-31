import Foundation
import Testing
@testable import Core
import Shared

/// SessionStore 映射管理单元测试（M1-010）。
/// 纯内存/假持久化缝，不派生子进程。
@Suite("SessionStore 映射管理")
struct SessionStoreMappingTests {

    /// 内存假持久化缝：记录调用并回放 loadMappings。
    private actor FakeMappingStore: SessionMappingStore {
        private(set) var saved: [(sessionID: String, owner: SessionStore.Owner)] = []
        private(set) var removed: [String] = []
        private var stored: [SessionStore.Registration]

        init(stored: [SessionStore.Registration] = []) {
            self.stored = stored
        }

        func saveMapping(sessionID: String, owner: SessionStore.Owner) {
            saved.append((sessionID, owner))
        }
        func removeMapping(sessionID: String) {
            removed.append(sessionID)
        }
        func loadMappings() -> [SessionStore.Registration] {
            stored
        }
    }

    @Test("注册 → 查询 → 摘除（内存态）")
    func registerQueryRemove() async throws {
        let store = SessionStore()
        let registration = try await store.register(sessionID: "s1", owner: .thread("t1"))
        #expect(registration.isLive)
        #expect(await store.registration(of: "s1")?.owner == .thread("t1"))
        #expect(await store.allRegistrations().count == 1)

        try await store.remove(sessionID: "s1")
        #expect(await store.registration(of: "s1") == nil)
        #expect(await store.allRegistrations().isEmpty)
    }

    @Test("持久化缝联动：register/remove 同步落库调用")
    func persistenceHook() async throws {
        let fake = FakeMappingStore()
        let store = SessionStore(mappingStore: fake)

        try await store.register(sessionID: "s1", owner: .thread("t1"))
        try await store.register(sessionID: "s2", owner: .branch("b1"))
        try await store.remove(sessionID: "s1")

        let saved = await fake.saved
        #expect(saved.count == 2)
        #expect(saved[0].sessionID == "s1" && saved[0].owner == .thread("t1"))
        #expect(saved[1].sessionID == "s2" && saved[1].owner == .branch("b1"))
        #expect(await fake.removed == ["s1"])
    }

    @Test("restoreFromStore：重建映射且一律 isLive=false（session 不跨进程存活）")
    func restoreAsStale() async throws {
        let fake = FakeMappingStore(stored: [
            SessionStore.Registration(sessionID: "s1", owner: .thread("t1")),
            SessionStore.Registration(sessionID: "s2", owner: .thread("t2"))
        ])
        let store = SessionStore(mappingStore: fake)

        try await store.restoreFromStore()
        let all = await store.allRegistrations()
        #expect(all.count == 2)
        #expect(all.allSatisfy { !$0.isLive }, "恢复出的映射应全部标记失效")
    }

    @Test("markAllStale：子进程重启后整表失效但不删除")
    func markAllStale() async throws {
        let store = SessionStore()
        try await store.register(sessionID: "s1", owner: .thread("t1"))
        try await store.register(sessionID: "s2", owner: .branch("b1"))

        await store.markAllStale()
        let all = await store.allRegistrations()
        #expect(all.count == 2, "失效标记不应删除映射（留待 M4-010 恢复策略）")
        #expect(all.allSatisfy { !$0.isLive })
    }
}

/// SessionStore 事件路由端到端测试（M1-010，fake agent 多 session）。
/// 派生 bash 子进程，须 .serialized（swift-testing 并发 spawn 假死排坑，见 AGENTS.md §8）。
@Suite("SessionStore 事件路由（fake agent 多 session）", .serialized)
struct SessionStoreRoutingTests {

    private actor EventCollector {
        private(set) var events: [AgentEvent] = []
        func add(_ event: AgentEvent) { events.append(event) }
    }

    @Test("双 session 并发流式：各自路由不串线；无主事件不投递不崩溃")
    func multiSessionRouting() async throws {
        let home = try FakeCLI.makeHome(acpBehavior: FakeACPAgent.multiSession)
        let supervisor = ACPProcessSupervisor(configuration: SupervisorConfiguration(
            homeDirectory: home,
            gracefulShutdownTimeout: .seconds(2)
        ))
        let client = ACPClient(supervisor: supervisor)
        let store = SessionStore()

        try await withTimeout(seconds: 10, operation: "connect") { try await client.connect() }
        await store.attach(to: client)

        let session1 = try await withTimeout(seconds: 10, operation: "newSession1") {
            try await client.newSession(cwd: "/tmp")
        }
        let session2 = try await withTimeout(seconds: 10, operation: "newSession2") {
            try await client.newSession(cwd: "/tmp")
        }
        #expect(session1 == "sess_1")
        #expect(session2 == "sess_2")

        try await store.register(sessionID: session1, owner: .thread("t1"))
        try await store.register(sessionID: session2, owner: .thread("t2"))

        let collector1 = EventCollector()
        let collector2 = EventCollector()
        let collectTask1 = Task {
            let stream = await store.events(for: session1)
            for await event in stream { await collector1.add(event) }
        }
        let collectTask2 = Task {
            let stream = await store.events(for: session2)
            for await event in stream { await collector2.add(event) }
        }
        // 等订阅挂好再发 prompt（路由层不做事件缓冲）。
        try await Task.sleep(for: .milliseconds(50))

        // 两个 session 并发 prompt（fake agent 串行处理，但事件归属各自 session）。
        try await withTimeout(seconds: 10, operation: "prompts") {
            async let p1: Void = client.prompt(sessionID: session1, text: "hi 1")
            async let p2: Void = client.prompt(sessionID: session2, text: "hi 2")
            _ = try await (p1, p2)
        }
        try await Task.sleep(for: .milliseconds(100))

        let events1 = await collector1.events
        let events2 = await collector2.events
        #expect(events1.contains(.textDelta(sessionID: session1, text: "reply-sess_1")))
        #expect(events1.contains(.completed(sessionID: session1, stopReason: "end_turn")))
        #expect(events2.contains(.textDelta(sessionID: session2, text: "reply-sess_2")))
        #expect(events2.contains(.completed(sessionID: session2, stopReason: "end_turn")))

        // 不串线：sess_1 的流里不得出现 sess_2 的事件，反之亦然。
        #expect(events1.allSatisfy { $0.sessionID == session1 }, "sess_1 流混入其他 session：\(events1)")
        #expect(events2.allSatisfy { $0.sessionID == session2 }, "sess_2 流混入其他 session：\(events2)")

        collectTask1.cancel()
        collectTask2.cancel()
        await client.disconnect()
    }
}
