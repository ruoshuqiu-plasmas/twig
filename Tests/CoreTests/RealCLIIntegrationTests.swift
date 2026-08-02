import Foundation
import Testing
@testable import Core
import Shared

/// G1/G2/G3 真实 CLI 集成验收：真实 `kimi acp` 子进程上的主对话闭环、跨线程路由、
/// 只读策略端到端与支线全生命周期（创建/追问/嵌套/摘要/回流）。
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

    // MARK: - G3 支线验收（M3-014；BR-05/08/09/10/13/14）

    /// G3 真实支线全生命周期验收：一条主线生命周期内串起
    /// BR-05/08（开支线 + 支线内追问，历史各自独立）、BR-09（二级嵌套支线，祖先链进播种）、
    /// BR-13/14（真实摘要回流 + 幂等二次合并）。prompt 全部最小化（≤10 字回答），
    /// 共 6 次真实请求（主线 1 + 支线播种 1 + 支线追问 1 + 嵌套播种 1 + 回流摘要 1 + 回流注入 1）。
    @Test("真实 CLI：支线创建/追问/嵌套/回流全生命周期（BR-05/08/09/13/14）")
    func branchLifecycleRealCLI() async throws {
        guard enabled else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-g3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
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
        let summarizer = ACPSummarizer(client: client, sessionStore: sessionStore, cwd: sandbox.path)
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes, summarizer: summarizer
        )
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store
        )
        let mergeService = BranchMergeService(
            branches: branches, notes: notes, messages: messages,
            summarizer: summarizer, conversation: store
        )

        _ = try await withTimeout(seconds: 600, operation: "G3 真实支线生命周期验收") {
            await sessionStore.attach(to: client)
            try await client.connect()

            // 主线发一条消息得到回答（BR-05 前置）。
            try await store.openMostRecentOrCreate(projectRoot: sandbox.path)
            try await store.send(text: "请用不超过10个字回答：什么是队列？")
            let threadID = try #require(await store.currentSnapshot().threadID)
            try await waitAssistantCompleted(messages: messages, threadID: threadID, branchID: nil)
            let mainAssistant = try #require(
                try messages.messages(threadID: threadID).last { $0.role == .assistant },
                "主线应有 assistant 回答（thread=\(threadID.prefix(8))…）"
            )
            #expect(!mainAssistant.content.isEmpty, "主线回答不应为空")

            // BR-05：对主线回答开支线（coordinator 全编排到 ready）。
            let quote1 = mainAssistant.content
            let request1 = BranchCreationRequest(
                requestID: UUID().uuidString,
                threadID: threadID,
                parentBranchID: nil,
                snapshot: SelectionSnapshot(
                    messageID: mainAssistant.id, quote: quote1, start: 0, length: quote1.utf16.count
                ),
                anchorPlainText: mainAssistant.content,
                userQuestion: "请用不超过10个字总结这段回答",
                projectRoot: sandbox.path
            )
            if let failure = await awaitReady(coordinator.startCreation(request1), label: "一级支线") {
                Issue.record("一级支线创建失败：\(failure)")
                return false
            }
            let branch1 = try #require(
                try branches.listBranches(threadID: threadID).first,
                "branches 应有一级支线行（thread=\(threadID.prefix(8))…）"
            )

            // BR-05：独立 acp_session_id（≠主线）、seedContext 非空、首轮回答落库带 branchID。
            let registrations = await sessionStore.allRegistrations()
            let mainSession = registrations.first { $0.owner == .thread(threadID) }?.sessionID
            let branch1Session = try #require(
                branch1.acpSessionID,
                "一级支线应有 acp_session_id（branch=\(branch1.id.prefix(8))…）"
            )
            #expect(branch1Session != mainSession, "支线 session 必须独立于主线（\(branch1Session.prefix(8))…）")
            #expect(registrations.contains { $0.owner == .branch(branch1.id) },
                    "SessionStore 应有一级支线映射（branch=\(branch1.id.prefix(8))…）")
            let seed1 = try #require(branch1.seedContext, "一级支线 seedContext 不应为空")
            #expect(seed1.contains(quote1), "seedContext 应含锚点引文原文")
            let branch1Answer = try #require(
                try messages.messages(threadID: threadID, branchID: branch1.id)
                    .last { $0.role == .assistant && $0.status == .completed },
                "支线首轮回答应落库（branch=\(branch1.id.prefix(8))…）"
            )
            #expect(branch1Answer.branchID == branch1.id && !branch1Answer.content.isEmpty,
                    "支线首轮回答应带 branchID 且非空")

            // BR-08：支线内再追问一轮；历史只累积支线、主线不受影响。
            let mainlineCountBefore = try messages.messages(threadID: threadID).count
            try await store.sendBranchMessage(branchID: branch1.id, text: "请用不超过10个字再补充一点")
            try await waitAssistantCompleted(
                messages: messages, threadID: threadID, branchID: branch1.id
            )
            let branch1Messages = try messages.messages(threadID: threadID, branchID: branch1.id)
            #expect(branch1Messages.filter { $0.role == .user }.count >= 2,
                    "支线追问后应有 ≥2 条支线 user 消息（branch=\(branch1.id.prefix(8))…）")
            let mainlineAfterFollowUp = try messages.messages(threadID: threadID)
            #expect(mainlineAfterFollowUp.count == mainlineCountBefore,
                    "支线追问不得写主线（前 \(mainlineCountBefore) 后 \(mainlineAfterFollowUp.count)）")
            #expect(!mainlineAfterFollowUp.contains { $0.content.contains("再补充") },
                    "支线追问文本不得出现在主线")

            // BR-09：对支线内回答再开一层嵌套支线（两级真实，三级归 fake 层）。
            let branch1LastAnswer = try #require(
                branch1Messages.last { $0.role == .assistant && $0.status == .completed },
                "支线应有两轮回答（branch=\(branch1.id.prefix(8))…）"
            )
            let quote2 = branch1LastAnswer.content
            let request2 = BranchCreationRequest(
                requestID: UUID().uuidString,
                threadID: threadID,
                parentBranchID: branch1.id,
                snapshot: SelectionSnapshot(
                    messageID: branch1LastAnswer.id, quote: quote2, start: 0, length: quote2.utf16.count
                ),
                anchorPlainText: branch1LastAnswer.content,
                userQuestion: "请用不超过10个字概括这句话",
                projectRoot: sandbox.path
            )
            if let failure = await awaitReady(coordinator.startCreation(request2), label: "嵌套支线") {
                Issue.record("嵌套支线创建失败：\(failure)")
                return false
            }
            let branch2 = try #require(
                try branches.childBranches(parentBranchID: branch1.id).first,
                "应有嵌套支线下挂一级支线（parent=\(branch1.id.prefix(8))…）"
            )
            #expect(branch2.parentBranchID == branch1.id, "嵌套支线 parentBranchID 应指向一级支线")
            #expect(branch2.acpSessionID != nil && branch2.acpSessionID != branch1Session,
                    "嵌套支线应有独立 session（branch=\(branch2.id.prefix(8))…）")
            let seed2 = try #require(branch2.seedContext, "嵌套支线 seedContext 不应为空")
            #expect(seed2.contains("[祖先支线]"), "嵌套播种应含祖先支线段")
            #expect(seed2.contains(branch1.anchorQuote),
                    "祖先链应含父级锚点引文（parent anchor=\(branch1.anchorQuote.prefix(12))…）")

            // BR-13：对 ready 支线真实回流（摘要 + 四行注入消息 + status=merged）。
            let mergeResult = try await mergeService.merge(branchID: branch1.id)
            guard case .merged(let noteID, let injectedToACP) = mergeResult else {
                Issue.record("首次回流应为 .merged，实际 \(mergeResult)（branch=\(branch1.id.prefix(8))…）")
                return false
            }
            // injectedToACP 如实记录：主线空闲时预期 true；失败即 §7.8 中间态，不判失败。
            let note = try #require(
                try notes.note(forBranch: branch1.id),
                "回流后应有 branch_notes 行（note=\(noteID.prefix(8))…）"
            )
            #expect(note.id == noteID && !note.summary.isEmpty, "回流笔记应有摘要内容")
            let mergedBranch1 = try #require(try branches.branch(id: branch1.id))
            #expect(mergedBranch1.status == .merged, "回流后支线状态应为 merged")
            let mainlineMerged = try messages.messages(threadID: threadID)
            let mergeNotices = mainlineMerged.filter {
                $0.kind == .notice && $0.content.contains("[支线回流笔记]")
            }
            let notice = try #require(mergeNotices.first, "主线应有四行回流注入消息")
            #expect(notice.content.contains("来源支线：\(branch1.id.prefix(8))"),
                    "注入消息第二行应含支线 id 前缀")
            #expect(notice.content.contains("锚点：\(branch1.anchorQuote)"), "注入消息应含锚点行")
            #expect(notice.content.contains("结论："), "注入消息应含结论行")
            let metadata = BranchMergeService.decodeMetadata(notice.metadataJSON)
            #expect(metadata["injectedToACP"] == (injectedToACP ? "true" : "false"),
                    "metadata 的 injectedToACP 应与回流结果一致（实际 \(injectedToACP)）")

            // BR-14：二次 merge 幂等短路，不产生重复笔记/消息。
            let secondMerge = try await mergeService.merge(branchID: branch1.id)
            guard case .alreadyMerged = secondMerge else {
                Issue.record("二次回流应为 .alreadyMerged，实际 \(secondMerge)")
                return false
            }
            #expect(try notes.listNotes(threadID: threadID).count == 1, "二次回流不得产生重复笔记")
            #expect(
                try messages.messages(threadID: threadID)
                    .filter { $0.kind == .notice && $0.content.contains("[支线回流笔记]") }.count == 1,
                "二次回流不得产生重复注入消息"
            )
            return true
        }

        await client.disconnect()
    }

    /// BR-10 真实摘要路径：Assembler 注入极小 compressionThreshold 强制走摘要，
    /// 真实 ACPSummarizer 跑临时独立 session；断言 usedSummary、锚点/追问原文不改写、
    /// 临时 session 映射已摘除。共 2 次真实请求（主线 1 + 摘要 1）。
    @Test("真实 CLI：背景超阈值走真实摘要压缩（BR-10）")
    func summaryPathRealCLI() async throws {
        guard enabled else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-g3sum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
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
        let summarizer = ACPSummarizer(client: client, sessionStore: sessionStore, cwd: sandbox.path)
        // 极小阈值强制摘要路径（BR-10）。
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes,
            summarizer: summarizer, compressionThreshold: 200
        )

        _ = try await withTimeout(seconds: 240, operation: "BR-10 真实摘要验收") {
            await sessionStore.attach(to: client)
            try await client.connect()

            // 主线一轮：user 问题 >200 字符，使背景（锚点之前的主线问答）超阈值。
            let filler = String(repeating: "队列是一种先进先出的数据结构，常用于任务调度与消息传递。", count: 9)
            try await store.openMostRecentOrCreate(projectRoot: sandbox.path)
            try await store.send(text: "背景：\(filler) 请用不超过10个字回答这段背景的主题是什么。")
            let threadID = try #require(await store.currentSnapshot().threadID)
            try await waitAssistantCompleted(messages: messages, threadID: threadID, branchID: nil)
            let mainAssistant = try #require(
                try messages.messages(threadID: threadID).last { $0.role == .assistant },
                "主线应有 assistant 回答（thread=\(threadID.prefix(8))…）"
            )

            // 直接走 Assembler（usedSummary 仅其返回值可观测；摘要器为真实 ACPSummarizer）。
            let quote = mainAssistant.content
            let question = "请用不超过10个字总结这段回答"
            let assembled = try await assembler.assemble(
                threadID: threadID,
                parentBranchID: nil,
                anchorMessageID: mainAssistant.id,
                anchorQuote: quote,
                userQuestion: question
            )

            // BR-10：usedSummary=true、摘要产物进 seedContext、锚点与追问原文未改写。
            #expect(assembled.usedSummary, "背景超阈值应走摘要路径（原始 \(assembled.originalBackgroundLength) 字符）")
            #expect(assembled.originalBackgroundLength > 200, "背景应确实超阈值 200")
            #expect(assembled.summaryNote != nil, "应有摘要说明（原始范围与压缩事实）")
            #expect(assembled.seedContext.contains(quote), "锚点引文原文不得改写：\(quote)")
            #expect(assembled.seedContext.contains(question), "用户追问原文不得改写：\(question)")
            #expect(assembled.seedContext.contains("[背景上下文]"), "seedContext 应含背景段（摘要产物所在）")

            // DEC-06：临时摘要 session 映射已摘除（合成 owner 无残留注册）。
            let registrations = await sessionStore.allRegistrations()
            #expect(!registrations.contains { $0.owner == .branch("summarizer-temp") },
                    "临时摘要 session 映射应已摘除，实际残留：\(registrations.map { "\($0.owner)" })")
            return true
        }

        await client.disconnect()
    }

    // MARK: - G4 恢复验收（M4-011；REC-01/02）

    /// REC-01 真实续接：store1 建线程并发一轮（session 映射落库）→ 模拟应用重启
    /// （新 supervisor/client/sessionStore，同一文件库）→ store2 `openRestoredOrCreate`
    /// 走 `session/load` 续接成功（sessionResumed，不新建 session）→ 续接 session 上追问一轮。
    /// 共 2 次真实 prompt（均 ≤10 字回答）。
    @Test("真实 CLI：重启后 session/load 续接成功（REC-01）")
    func sessionResumeRealCLI() async throws {
        guard enabled else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-g4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 文件库（跨「重启」保留线程与 session 映射）。
        let appDB = try AppDatabase.makeDefault(directory: sandbox)
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)

        // —— 第一段：建线程、发一轮，session 映射落库 ——
        let supervisor1 = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
        let client1 = ACPClient(supervisor: supervisor1)
        let sessionStore1 = SessionStore(mappingStore: threads)
        let store1 = ConversationStore(
            threads: threads, messages: messages,
            driver: LiveConversationDriver(client: client1, sessionStore: sessionStore1)
        )

        let firstSessionID: String = try await withTimeout(seconds: 180, operation: "G4 REC-01 第一段") {
            await sessionStore1.attach(to: client1)
            try await client1.connect()
            try await store1.openMostRecentOrCreate(projectRoot: sandbox.path)
            try await store1.send(text: "请只回复两个字：续接")
            let threadID = try #require(await store1.currentSnapshot().threadID)
            try await waitAssistantCompleted(messages: messages, threadID: threadID, branchID: nil)
            let thread = try #require(try threads.listThreads().first { $0.id == threadID })
            return try #require(thread.acpSessionID, "首轮后线程应有持久化 session 映射")
        }
        await client1.disconnect()

        // —— 第二段：模拟重启，openRestoredOrCreate 尝试续接 ——
        let supervisor2 = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
        let client2 = ACPClient(supervisor: supervisor2)
        let sessionStore2 = SessionStore(mappingStore: threads)
        let store2 = ConversationStore(
            threads: threads, messages: messages,
            driver: LiveConversationDriver(client: client2, sessionStore: sessionStore2)
        )

        try await withTimeout(seconds: 240, operation: "G4 REC-01 第二段") {
            await sessionStore2.attach(to: client2)
            try await client2.connect()
            #expect(await client2.supportsLoadSession, "CLI 0.31.0 应声明 loadSession 能力")

            try await store2.openRestoredOrCreate(projectRoot: sandbox.path, lastSelectedThreadID: nil)
            let snapshot = await store2.currentSnapshot()
            #expect(snapshot.recovery == .sessionResumed,
                    "续接应成功（实际 \(String(describing: snapshot.recovery))）")
            #expect(!(snapshot.messages.isEmpty), "本地历史应完整呈现")

            // 续接的 session 上继续对话（不新建 session：第二段无任何 session/new）。
            try await store2.send(text: "请只回复两个字：成功")
            let threadID = try #require(snapshot.threadID)
            try await waitAssistantCompleted(messages: messages, threadID: threadID, branchID: nil)
            let thread = try #require(try threads.listThreads().first { $0.id == threadID })
            #expect(thread.acpSessionID == firstSessionID,
                    "续接后映射仍指向原 session（未新建）")
            return true
        }

        await client2.disconnect()
    }

    /// REC-02 真实降级：线程映射指向不存在的 session id → load 失败 →
    /// sessionUnavailable + 退化新建 session，本地历史无损、可继续对话。共 1 次真实 prompt。
    @Test("真实 CLI：session 不可续接时降级新建（REC-02）")
    func sessionResumeUnavailableRealCLI() async throws {
        guard enabled else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-g4bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

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
            threads: threads, messages: messages,
            driver: LiveConversationDriver(client: client, sessionStore: sessionStore)
        )

        try await withTimeout(seconds: 240, operation: "G4 REC-02 验收") {
            await sessionStore.attach(to: client)
            try await client.connect()

            // 预置线程 + 指向不存在 session 的映射（模拟 agent 侧 session 已清理）。
            let thread = try threads.createThread(title: "降级验证", projectRoot: sandbox.path)
            try messages.insert(Message(
                id: "m-hist", threadID: thread.id, branchID: nil, role: .user, kind: .text,
                content: "历史问题", sequence: 1, status: .completed,
                createdAt: Date(), updatedAt: Date(), metadataJSON: nil
            ))
            try threads.saveMapping(sessionID: "sess-definitely-not-exists", owner: .thread(thread.id))

            try await store.openRestoredOrCreate(projectRoot: sandbox.path, lastSelectedThreadID: nil)
            let snapshot = await store.currentSnapshot()
            #expect(snapshot.recovery == .sessionUnavailable,
                    "不存在的 session 应走降级（实际 \(String(describing: snapshot.recovery))）")
            #expect(snapshot.messages.count == 1, "本地历史应无损呈现")

            // 退化后已新建 session，可正常对话。
            try await store.send(text: "请只回复两个字：降级")
            try await waitAssistantCompleted(messages: messages, threadID: thread.id, branchID: nil)
            return true
        }

        await client.disconnect()
    }

    // MARK: - G3 辅助

    /// 轮询数据库直到指定会话（主线/支线）最后一条 assistant 消息落库为 completed；
    /// failed 立即报错（附会话定位信息）。整体超时由外层 withTimeout 兜底。
    private func waitAssistantCompleted(
        messages: MessageRepository, threadID: String, branchID: String?
    ) async throws {
        let scope = branchID.map { "branch=\($0.prefix(8))…" } ?? "主线 thread=\(threadID.prefix(8))…"
        while true {
            let last = try messages.messages(threadID: threadID, branchID: branchID)
                .last { $0.role == .assistant }
            if last?.status == .completed { return }
            try #require(last?.status != .failed, "\(scope) 对话不应失败")
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 等待支线创建状态机到 ready；失败返回可读原因（含步骤定位），流随 break 终止。
    private func awaitReady(
        _ stream: AsyncStream<BranchCreationState>, label: String
    ) async -> String? {
        for await state in stream {
            switch state {
            case .ready:
                return nil
            case .failed(let retryable, let reason):
                return "\(label) 进入 failed（\(retryable ? "可重试" : "不可重试")）：\(reason)"
            default:
                continue
            }
        }
        return "\(label) 状态流在 ready 前意外终止"
    }
}
