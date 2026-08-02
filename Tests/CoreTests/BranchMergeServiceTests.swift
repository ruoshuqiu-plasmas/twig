import Foundation
import Testing
@testable import Core
import Shared

/// 回流服务测试（M3-011/012，§7.8 / BR-13/14）：内存库 + FakeSummarizer + FakeDriver，
/// 不派生真实子进程（无需 .serialized）。FakeDriver 模式照 BranchConversationTests。
@Suite("BranchMergeService：结论回流（幂等与事务）")
struct BranchMergeServiceTests {

    /// 假摘要器：记录输入背景，可注入失败。
    final class FakeSummarizer: BranchSummarizer, @unchecked Sendable {
        private(set) var inputs: [String] = []
        var result = "【假摘要】支线结论"
        var error: (any Error)?

        func summarize(background: String) async throws -> String {
            inputs.append(background)
            if let error { throw error }
            return result
        }
    }

    /// 假驱动：记录 session/prompt，事件流空实现（注入路径不消费事件）。
    final class FakeDriver: ConversationDriver, @unchecked Sendable {
        private(set) var sessions: [(cwd: String, owner: SessionStore.Owner, sessionID: String)] = []
        private(set) var sentPrompts: [(sessionID: String, text: String)] = []
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
            AsyncStream { _ in }
        }
    }

    enum TestFailure: Error { case boom }

    private struct Fixture {
        let service: BranchMergeService
        let driver: FakeDriver
        let summarizer: FakeSummarizer
        let branches: BranchRepository
        let notes: BranchNoteRepository
        let messages: MessageRepository
        let threadID: String
    }

    /// 内存库 + 激活主线（注入前置：主线上下文须已打开）。
    private func makeFixture() async throws -> Fixture {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        let messages = MessageRepository(appDB)
        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        try await store.openMostRecentOrCreate(projectRoot: "/tmp")
        let threadID = await store.currentSnapshot().threadID!
        let summarizer = FakeSummarizer()
        let service = BranchMergeService(
            branches: branches, notes: notes, messages: messages,
            summarizer: summarizer, conversation: store
        )
        return Fixture(
            service: service, driver: driver, summarizer: summarizer,
            branches: branches, notes: notes, messages: messages, threadID: threadID
        )
    }

    private func makeBranch(_ f: Fixture, id: String = "branch-1", quote: String = "锚点引文") throws -> Branch {
        try f.branches.create(id: id, threadID: f.threadID, anchorQuote: quote)
    }

    /// 直接落支线消息（模拟种子/问答/通知/工具卡片；rawMetadataJSON 供手写 metadata 用）。
    private func insertBranchMessage(
        _ f: Fixture, branchID: String,
        role: MessageRole = .user, kind: MessageKind = .text,
        content: String, metadata: [String: String]? = nil, rawMetadataJSON: String? = nil
    ) throws {
        let now = Date()
        var metadataJSON = rawMetadataJSON
        if metadataJSON == nil, let metadata, let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = String(data: data, encoding: .utf8)
        }
        let message = Message(
            id: UUID().uuidString, threadID: f.threadID, branchID: branchID,
            role: role, kind: kind, content: content,
            sequence: try f.messages.nextSequence(threadID: f.threadID, branchID: branchID),
            status: .completed, createdAt: now, updatedAt: now, metadataJSON: metadataJSON
        )
        try f.messages.insert(message)
    }

    /// 主线回流注入消息（metadata 双标记定位）。
    private func mergeMessage(_ f: Fixture) throws -> Message? {
        try f.messages.messages(threadID: f.threadID).first {
            $0.metadataJSON?.contains(#""mergeNote":"true""#) == true
        }
    }

    // MARK: - 正常合并（BR-13）

    @Test("正常合并：note/主线注入消息/status=merged 同库可见；格式四行齐全；种子与工具消息不进摘要")
    func mergeSuccess() async throws {
        let f = try await makeFixture()
        let branch = try makeBranch(f)
        try insertBranchMessage(f, branchID: branch.id, content: "种子背景", metadata: ["kind": "seed_context"])
        try insertBranchMessage(f, branchID: branch.id, content: "手写种子", rawMetadataJSON: #"{"kind":"seedContext"}"#)
        try insertBranchMessage(f, branchID: branch.id, content: "支线问")
        try insertBranchMessage(f, branchID: branch.id, role: .assistant, content: "支线答")
        try insertBranchMessage(f, branchID: branch.id, role: .system, kind: .notice, content: "工具拒绝通知")
        try insertBranchMessage(f, branchID: branch.id, role: .assistant, kind: .toolCall, content: "工具卡片")

        let result = try await f.service.merge(branchID: branch.id)

        guard case .merged(let noteID, let injected) = result else {
            Issue.record("应返回 merged：\(result)")
            return
        }
        #expect(injected, "注入成功应标记 true")
        #expect(noteID == "merge-note-\(branch.id)", "笔记 id 确定性生成")

        // note 落库。
        let note = try #require(try f.notes.note(forBranch: branch.id))
        #expect(note.id == noteID && note.threadID == f.threadID)
        #expect(note.summary == "【假摘要】支线结论")

        // branch 状态同事务更新。
        let stored = try #require(try f.branches.branch(id: branch.id))
        #expect(stored.status == .merged && stored.mergeNoteID == noteID)

        // 主线注入消息：四行格式齐全、role/kind/归属正确、metadata 翻 true。
        let message = try #require(try mergeMessage(f))
        #expect(message.role == .system && message.kind == .notice && message.branchID == nil)
        #expect(message.content.hasPrefix("[支线回流笔记]\n"))
        #expect(message.content.contains("\n来源支线：\(branch.id.prefix(8))\n"))
        #expect(message.content.contains("\n锚点：锚点引文\n"))
        #expect(message.content.contains("\n结论：【假摘要】支线结论"))
        #expect(message.metadataJSON?.contains(#""injectedToACP":"true""#) == true)
        #expect(message.metadataJSON?.contains(#""branchID":"\#(branch.id)""#) == true)

        // 摘要输入：只含支线问答；种子（两种 metadata 写法）、notice、toolCall 均跳过。
        #expect(f.summarizer.inputs.count == 1)
        let background = f.summarizer.inputs[0]
        #expect(background.contains("【用户】支线问"))
        #expect(background.contains("【助手】支线答"))
        #expect(!background.contains("种子背景") && !background.contains("手写种子"))
        #expect(!background.contains("工具拒绝通知") && !background.contains("工具卡片"))

        // ACP 注入：走主线 session 的 sendPrompt，带「无需回复」尾注。
        #expect(f.driver.sentPrompts.count == 1)
        #expect(f.driver.sentPrompts[0].sessionID == f.driver.sessions[0].sessionID)
        #expect(f.driver.sentPrompts[0].text.contains("[支线回流笔记]"))
        #expect(f.driver.sentPrompts[0].text.contains("无需回复"))
    }

    // MARK: - 幂等（BR-14）

    @Test("BR-14：连续两次 merge 只产生一条笔记一条注入消息，第二次返回 alreadyMerged")
    func mergeIdempotent() async throws {
        let f = try await makeFixture()
        let branch = try makeBranch(f)
        try insertBranchMessage(f, branchID: branch.id, content: "支线问")
        try insertBranchMessage(f, branchID: branch.id, role: .assistant, content: "支线答")

        let first = try await f.service.merge(branchID: branch.id)
        guard case .merged(let noteID, true) = first else {
            Issue.record("首次应 merged+injected：\(first)")
            return
        }
        let second = try await f.service.merge(branchID: branch.id)
        #expect(second == .alreadyMerged(noteID: noteID, injectedToACP: true))

        #expect(try f.notes.listNotes(threadID: f.threadID).count == 1, "不重复产生笔记")
        #expect(try f.messages.messages(threadID: f.threadID).count == 1, "不重复产生注入消息")
        #expect(f.driver.sentPrompts.count == 1, "已注入成功不重复发 prompt")
        #expect(f.summarizer.inputs.count == 1, "幂等短路不再调摘要")
    }

    // MARK: - 注入失败中间态与恢复（§7.8）

    @Test("注入失败：merged(injectedToACP:false) 中间态；幂等短路顺带重试；retryInjection 成功翻 true")
    func injectionFailureAndRecovery() async throws {
        let f = try await makeFixture()
        let branch = try makeBranch(f)
        try insertBranchMessage(f, branchID: branch.id, content: "支线问")
        try insertBranchMessage(f, branchID: branch.id, role: .assistant, content: "支线答")

        f.driver.promptError = TestFailure.boom
        let result = try await f.service.merge(branchID: branch.id)
        guard case .merged(let noteID, false) = result else {
            Issue.record("注入失败应返回 merged(injectedToACP:false)：\(result)")
            return
        }
        let pending = try #require(try mergeMessage(f))
        #expect(pending.metadataJSON?.contains(#""injectedToACP":"false""#) == true, "中间态落 false")

        // 注入仍失败时重复 merge：alreadyMerged + 顺带重试注入，不产生重复写入。
        let again = try await f.service.merge(branchID: branch.id)
        #expect(again == .alreadyMerged(noteID: noteID, injectedToACP: false))
        #expect(try f.notes.listNotes(threadID: f.threadID).count == 1)
        #expect(try f.messages.messages(threadID: f.threadID).count == 1)
        #expect(f.driver.sentPrompts.count == 2, "幂等短路顺带重试注入")

        // 恢复后 retryInjection：metadata 翻 true；已成功再 retry 不重复发 prompt。
        f.driver.promptError = nil
        #expect(try await f.service.retryInjection(noteID: noteID) == true)
        let recovered = try #require(try mergeMessage(f))
        #expect(recovered.metadataJSON?.contains(#""injectedToACP":"true""#) == true)
        #expect(recovered.content == pending.content, "重试只翻 metadata，不改笔记正文")
        #expect(f.driver.sentPrompts.count == 3)

        #expect(try await f.service.retryInjection(noteID: noteID) == true)
        #expect(f.driver.sentPrompts.count == 3, "已注入成功不再发 prompt")
    }

    // MARK: - 状态判错

    @Test("closed 支线抛 alreadyClosed；不存在支线抛 branchNotFound；retryInjection 未知 noteID 抛 branchNotFound")
    func statusGuards() async throws {
        let f = try await makeFixture()
        let branch = try makeBranch(f, id: "branch-closed")
        try f.branches.updateStatus(branchID: branch.id, status: .closed)

        do {
            _ = try await f.service.merge(branchID: branch.id)
            Issue.record("closed 支线应抛 alreadyClosed")
        } catch BranchMergeError.alreadyClosed(let id) {
            #expect(id == branch.id)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }

        do {
            _ = try await f.service.merge(branchID: "ghost")
            Issue.record("不存在支线应抛 branchNotFound")
        } catch BranchMergeError.branchNotFound(let id) {
            #expect(id == "ghost")
        } catch {
            Issue.record("错误类型不符：\(error)")
        }

        do {
            _ = try await f.service.retryInjection(noteID: "not-a-merge-note")
            Issue.record("未知 noteID 应抛 branchNotFound")
        } catch BranchMergeError.branchNotFound {
            // 预期
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    // MARK: - 摘要失败零写入

    @Test("摘要失败：抛 summarizationFailed，库内零写入（无笔记/无主线消息/状态仍 open/未发 prompt）")
    func summarizationFailureWritesNothing() async throws {
        let f = try await makeFixture()
        let branch = try makeBranch(f)
        try insertBranchMessage(f, branchID: branch.id, content: "支线问")
        f.summarizer.error = TestFailure.boom

        do {
            _ = try await f.service.merge(branchID: branch.id)
            Issue.record("摘要失败应抛 summarizationFailed")
        } catch BranchMergeError.summarizationFailed(let reason) {
            #expect(reason.contains("boom"), "携带失败原因：\(reason)")
        } catch {
            Issue.record("错误类型不符：\(error)")
        }

        #expect(try f.notes.note(forBranch: branch.id) == nil, "不落笔记")
        #expect(try f.messages.messages(threadID: f.threadID).isEmpty, "不落主线消息")
        let stored = try #require(try f.branches.branch(id: branch.id))
        #expect(stored.status == .open && stored.mergeNoteID == nil, "状态不改写")
        #expect(f.driver.sentPrompts.isEmpty, "不发注入 prompt")
    }
}
