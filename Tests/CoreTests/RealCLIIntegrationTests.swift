import Foundation
import Testing
@testable import Core
import Shared

/// G1 真实 CLI 集成验收（任务 M1-014）：真实 `kimi acp` 子进程上的主对话闭环与跨线程路由。
///
/// **消耗会员额度，默认不跑**：仅当环境变量 `TWIG_REAL_CLI=1` 时执行
/// （`TWIG_REAL_CLI=1 swift test --filter RealCLI`）。每个 Gate 至少跑一次，
/// RC 前全量；常规回归请勿开启（AGENTS.md 额度意识）。
@Suite("G1 真实 CLI 集成验收（额度消耗，TWIG_REAL_CLI=1 才执行）", .serialized)
struct RealCLIIntegrationTests {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TWIG_REAL_CLI"] == "1"
    }

    /// G1-05 + G1-06：真实 CLI 上发消息收到连续流式；流式中切线程，两路内容各自正确。
    @Test("真实 CLI：两线程并发流式不串线（G1-05/06）")
    func twoThreadsRealCLI() async throws {
        guard enabled else { return }

        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let supervisor = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
        let client = ACPClient(supervisor: supervisor)
        let sessionStore = SessionStore(mappingStore: threads)
        let store = ConversationStore(
            threads: threads,
            messages: messages,
            driver: LiveConversationDriver(client: client, sessionStore: sessionStore)
        )

        try await withTimeout(seconds: 120, operation: "G1 真实 CLI 验收") {
            await sessionStore.attach(to: client)
            try await client.connect()

            // 线程 1：发送并等到首个 delta（进入流式）。
            try await store.openMostRecentOrCreate(projectRoot: "/tmp")
            try await store.send(text: "请只回复两个字：苹果")
            let thread1 = try #require(await store.currentSnapshot().threadID)
            while try messages.messages(threadID: thread1).last?.content.isEmpty != false {
                try await Task.sleep(for: .milliseconds(50))
            }

            // 流式中切线程 2 并发发送。
            try await store.newConversation(projectRoot: "/tmp")
            try await store.send(text: "请只回复两个字：香蕉")
            let thread2 = try #require(await store.currentSnapshot().threadID)
            #expect(thread1 != thread2)

            // 等两线程都完成（完成状态以数据库为准，与 UI 活跃线程无关）。
            while true {
                let m1 = try messages.messages(threadID: thread1).last
                let m2 = try messages.messages(threadID: thread2).last
                if m1?.status == .completed && m2?.status == .completed { break }
                #expect(m1?.status != .failed && m2?.status != .failed, "不应失败：\(m1?.status ?? .streaming)/\(m2?.status ?? .streaming)")
                try await Task.sleep(for: .milliseconds(100))
            }

            // 内容各归各线程（G1-06 不串线）。
            let content1 = try #require(try messages.messages(threadID: thread1).last?.content)
            let content2 = try #require(try messages.messages(threadID: thread2).last?.content)
            #expect(content1.contains("苹果"), "线程1 应含「苹果」：\(content1)")
            #expect(content2.contains("香蕉"), "线程2 应含「香蕉」：\(content2)")
            #expect(!content1.contains("香蕉") && !content2.contains("苹果"), "两线程内容不得交叉")
            return true
        }

        await client.disconnect()
    }

    /// G2 真实 CLI 精简验收（M2-010，SEC-04/05/06/08/12 端到端面）：
    /// 指示 CLI 在临时沙箱写文件 → 只读策略拒绝 → 文件未落盘、
    /// 卡片收口 denied、notice 入库、对话继续到 completed。
    /// 单轮单场景，额度消耗最小化（用户 2026-08-01 批准）。
    @Test("真实 CLI：写文件被只读策略拒绝，文件未落盘且对话续行（G2 精简验收）")
    func writeDeniedRealCLI() async throws {
        guard enabled else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-g2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let targetFile = sandbox.appendingPathComponent("hello.txt")

        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let supervisor = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
        let client = ACPClient(supervisor: supervisor)
        let sessionStore = SessionStore(mappingStore: threads)
        let store = ConversationStore(
            threads: threads,
            messages: messages,
            driver: LiveConversationDriver(client: client, sessionStore: sessionStore)
        )

        try await withTimeout(seconds: 120, operation: "G2 真实 CLI 验收") {
            await sessionStore.attach(to: client)
            try await client.connect()

            try await store.openMostRecentOrCreate(projectRoot: sandbox.path)
            try await store.send(text: "请创建文件 hello.txt，内容写 hello。只需要这一步，完成后简单确认即可。")
            let threadID = try #require(await store.currentSnapshot().threadID)

            // 等对话收尾（完成或被拒后续行到 end_turn）。
            while true {
                let last = try messages.messages(threadID: threadID).last { $0.role == .assistant }
                if last?.status == .completed { break }
                #expect(last?.status != .failed, "对话不应失败：\(last?.status ?? .streaming)")
                try await Task.sleep(for: .milliseconds(200))
            }

            let all = try messages.messages(threadID: threadID)

            // 文件未落盘（SEC-04/05 端到端：拒绝真实生效）。
            #expect(!FileManager.default.fileExists(atPath: targetFile.path),
                    "被拒绝的写操作不得落盘")

            // 卡片收口 denied（SEC-12 标记可见）。
            let deniedCards = all.filter {
                $0.kind == .toolCall && $0.toolCallRecord()?.status == .denied
            }
            #expect(!deniedCards.isEmpty, "应有 denied 工具卡片，实际消息：\(all.map { "\($0.kind)/\($0.status)" })")

            // notice 入库（SEC-13 数据面：拒绝记录可回看）。
            #expect(all.contains { $0.kind == .notice }, "应有拒绝 notice 入库")
            return true
        }

        await client.disconnect()
    }
}
