import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// 右侧支线标签栏（M3-007）ViewModel 可测逻辑：轮数/10 轮阈值（M3-013）、标题派生、
/// seed 识别折叠、创建状态流驱动与自动切标签、嵌套创建（M3-009）、
/// 关闭标签不删上下文（BR-15/BR-18 数据面）、合并结果状态映射含中间态（§7.8/BR-14）。
/// 全部使用内存库 + FakeDriver，不派生真实子进程（额度零消耗）。
/// 标签栏布局/徽标配色/滚动跟随等 SwiftUI 细节归 G3 手工冒烟清单。
@Suite("BranchPanelViewModel：右侧支线标签栏")
@MainActor
struct BranchPanelViewModelTests {

    // MARK: - 测试替身

    typealias FakeDriver = BranchSessionCoordinatorTests.FakeDriver

    struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "压缩摘要" }
    }

    struct ThrowingSummarizer: BranchSummarizer {
        struct SummarizeFailed: Error {}
        func summarize(background: String) async throws -> String { throw SummarizeFailed() }
    }

    // MARK: - 环境搭建

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private struct World {
        let panel: BranchPanelViewModel
        let driver: FakeDriver
        let store: ConversationStore
        let branches: BranchRepository
        let notes: BranchNoteRepository
        let messages: MessageRepository
    }

    private func makeWorld(mergeSummarizer: any BranchSummarizer = FakeSummarizer()) throws -> World {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)

        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store, now: { self.t0 }
        )
        let merge = BranchMergeService(
            branches: branches, notes: notes, messages: messages,
            summarizer: mergeSummarizer, conversation: store, now: { self.t0 }
        )
        let panel = BranchPanelViewModel(
            branches: branches, threads: threads, messages: messages,
            conversation: store, coordinator: coordinator, mergeService: merge
        )
        return World(
            panel: panel, driver: driver, store: store,
            branches: branches, notes: notes, messages: messages
        )
    }

    private func makeMessage(
        id: String, threadID: String = "t1", branchID: String? = nil,
        role: MessageRole, kind: MessageKind = .text,
        content: String, sequence: Int, metadataJSON: String? = nil
    ) -> Message {
        Message(
            id: id, threadID: threadID, branchID: branchID, role: role, kind: kind,
            content: content, sequence: sequence, status: .completed,
            createdAt: t0, updatedAt: t0, metadataJSON: metadataJSON
        )
    }

    /// 播种主线问答（锚点消息 m2 为 assistant 回答）。
    private func seedMainline(_ messages: MessageRepository) throws {
        try messages.insert(makeMessage(id: "m1", role: .user, content: "主线问题", sequence: 1))
        try messages.insert(makeMessage(id: "m2", role: .assistant, content: "锚点原文", sequence: 2))
    }

    private func waitFor(
        _ description: String,
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        _ = try await withTimeout(seconds: 5, operation: description) {
            while await !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    /// 发起一级支线创建并驱动到 ready，返回新支线行。
    @discardableResult
    private func createBranchToReady(
        _ world: World, requestID: String = "req-1", question: String = "这段什么意思？"
    ) async throws -> Branch {
        let request = BranchCreationRequest(
            requestID: requestID, threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
            anchorPlainText: "锚点原文", userQuestion: question, projectRoot: "/tmp"
        )
        let promptsBefore = await world.driver.sentPromptCount
        world.panel.startCreation(request)
        try await waitFor("播种发出") { await world.driver.sentPromptCount > promptsBefore }
        // 创建流程为最新创建的 session 播种（父支线 session 在前，取最后一个）。
        let sessionCount = await world.driver.sessionCount
        let sessionID = await world.driver.sessionID(at: sessionCount - 1)
        await world.driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "播种回答"))
        await world.driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("新支线标签出现") {
            world.panel.visibleBranches.contains { $0.anchorMessageID == "m2" }
        }
        return try #require(world.panel.visibleBranches.first { $0.anchorMessageID == "m2" })
    }

    // MARK: - 纯派生逻辑（轮数/标题/seed/进度文案）

    @Test("轮数统计：role==user 且非 seed 的 text 消息计数；seed 与 assistant 不计")
    func roundCounting() {
        let messages = [
            makeMessage(id: "a", role: .user, content: "问题一", sequence: 1),
            makeMessage(id: "b", role: .user, content: "背景", sequence: 2,
                        metadataJSON: #"{"seedContext":"true"}"#),
            makeMessage(id: "c", role: .assistant, content: "回答一", sequence: 3),
            makeMessage(id: "d", role: .user, content: "问题二", sequence: 4),
        ]
        #expect(BranchPanelViewModel.roundCount(messages: messages) == 2)
        #expect(BranchPanelViewModel.roundCount(messages: []) == 0)
    }

    @Test("seed 识别：seedContext / seed_context 两种 metadata 均识别；无 metadata 不误判")
    func seedRecognition() {
        let camel = makeMessage(id: "a", role: .user, content: "x", sequence: 1,
                                metadataJSON: #"{"seedContext":"true"}"#)
        let snake = makeMessage(id: "b", role: .user, content: "x", sequence: 1,
                                metadataJSON: #"{"kind":"seed_context"}"#)
        let plain = makeMessage(id: "c", role: .user, content: "x", sequence: 1)
        let other = makeMessage(id: "d", role: .user, content: "x", sequence: 1,
                                metadataJSON: #"{"mergeNote":"true"}"#)
        #expect(BranchPanelViewModel.isSeed(camel))
        #expect(BranchPanelViewModel.isSeed(snake))
        #expect(!BranchPanelViewModel.isSeed(plain))
        #expect(!BranchPanelViewModel.isSeed(other))
    }

    @Test("标题派生：首个非 seed user 问题截 20 字；无 user 问题则锚点引文占位")
    func titleDerivation() throws {
        let branch = Branch(
            id: "b1", threadID: "t1", anchorQuote: "锚点引文占位文字",
            createdAt: t0, updatedAt: t0
        )
        let longQuestion = String(repeating: "问", count: 25)
        let withQuestion = [
            makeMessage(id: "a", role: .user, content: "背景", sequence: 1,
                        metadataJSON: #"{"seedContext":"true"}"#),
            makeMessage(id: "b", role: .user, content: longQuestion, sequence: 2),
        ]
        let title = BranchPanelViewModel.title(for: branch, messages: withQuestion)
        #expect(title == String(repeating: "问", count: 20))
        #expect(title.count == 20)

        // 无 user 问题 → 锚点引文占位。
        #expect(BranchPanelViewModel.title(for: branch, messages: []) == "锚点引文占位文字")
        // 引文也为空 → 兜底占位。
        let emptyQuote = Branch(id: "b2", threadID: "t1", anchorQuote: "  ", createdAt: t0, updatedAt: t0)
        #expect(BranchPanelViewModel.title(for: emptyQuote, messages: []) == "支线")
    }

    @Test("创建进度文案：组装背景/创建会话/播种等阶段映射")
    func creationProgressText() {
        #expect(BranchPanelViewModel.creationProgressText(.preparingContext) == "组装背景…")
        #expect(BranchPanelViewModel.creationProgressText(.compressingContext) == "压缩背景…")
        #expect(BranchPanelViewModel.creationProgressText(.creatingSession) == "创建会话…")
        #expect(BranchPanelViewModel.creationProgressText(.sendingSeed) == "播种背景…")
        #expect(BranchPanelViewModel.creationProgressText(.streaming) == "等待支线回答…")
        #expect(BranchPanelViewModel.creationProgressText(.failed(retryable: true, reason: "网络")) == "创建失败：网络")
    }

    // MARK: - 创建状态流驱动与自动切标签

    @Test("创建就绪：pending 进度移除、新支线自动切为激活标签；seed 不计轮数")
    func creationReadyAutoSwitch() async throws {
        let world = try makeWorld()
        try seedMainline(world.messages)
        world.panel.threadID = "t1"
        world.panel.refresh()
        #expect(!world.panel.hasVisibleContent)

        let request = BranchCreationRequest(
            requestID: "req-auto", threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
            anchorPlainText: "锚点原文", userQuestion: "这段什么意思？", projectRoot: "/tmp"
        )
        world.panel.startCreation(request)
        #expect(world.panel.pendingCreations.count == 1)
        #expect(world.panel.hasVisibleContent, "创建进行中也应展示右栏")

        try await waitFor("播种发出") { await world.driver.sentPromptCount == 1 }
        let sessionID = await world.driver.sessionID(at: 0)
        await world.driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("自动切到新标签") {
            world.panel.activeBranchID != nil && world.panel.pendingCreations.isEmpty
        }

        let branch = try #require(world.panel.visibleBranches.first)
        #expect(world.panel.activeBranchID == branch.id, "新建支线自动切到该标签（§7.7）")
        // 此时支线内仅 seed 消息与播种回答：首个非 seed user 问题尚不存在，
        // 标题按 §7.7 回退锚点引文占位（用户发出首条追问后转为问题截断）。
        #expect(world.panel.title(for: branch) == "锚点")
        // 支线消息：seed user + assistant 回答；轮数只计非 seed user → 0。
        #expect(world.panel.roundCount(branchID: branch.id) == 0)
        let branchMessages = try #require(world.panel.branchMessages[branch.id])
        #expect(branchMessages.contains { BranchPanelViewModel.isSeed($0) }, "seed 消息在流中（视图层折叠展示）")
    }

    // MARK: - 嵌套创建（M3-009）

    @Test("嵌套追问：支线内选区冻结后确认，创建请求带 parentBranchID；就绪后子支线自动激活")
    func nestedCreation() async throws {
        let world = try makeWorld()
        try seedMainline(world.messages)
        world.panel.threadID = "t1"
        world.panel.refresh()
        let parent = try await createBranchToReady(world)

        // 父支线 assistant 回答「播种回答」上制造选区。
        let parentMessages = try #require(world.panel.branchMessages[parent.id])
        let answer = try #require(parentMessages.first { $0.role == .assistant })
        #expect(answer.content == "播种回答")
        let selection = SelectionSnapshot(messageID: answer.id, quote: "播种回答", start: 0, length: 4)

        world.panel.branchSelections[parent.id] = selection
        world.panel.beginNestedComposition(parentBranchID: parent.id)
        #expect(world.panel.isComposingNestedQuestion)
        #expect(world.panel.frozenNestedParentID == parent.id)
        #expect(world.panel.frozenNestedSelection == selection)

        // 冻结后改选区不影响（BR-04 同语义）。
        world.panel.branchSelections[parent.id] = nil
        #expect(world.panel.frozenNestedSelection == selection)

        world.panel.nestedQuestionInput = "嵌套追问"
        world.panel.confirmNestedQuestion()
        #expect(!world.panel.isComposingNestedQuestion)
        let pending = try #require(world.panel.pendingCreations.first)
        #expect(pending.request.parentBranchID == parent.id)
        #expect(pending.request.userQuestion == "嵌套追问")
        #expect(pending.request.snapshot.messageID == answer.id, "锚点消息属于父支线")

        try await waitFor("嵌套播种发出") { await world.driver.sentPromptCount == 2 }
        let sessionID = await world.driver.sessionID(at: 1)
        await world.driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("子支线标签出现") { world.panel.visibleBranches.count == 2 }

        let child = try #require(world.panel.visibleBranches.first { $0.parentBranchID == parent.id })
        #expect(world.panel.activeBranchID == child.id)
        #expect(child.anchorMessageID == answer.id)
    }

    // MARK: - 关闭标签（BR-15/BR-18 数据面）

    @Test("关闭标签仅 UI 层：支线行/消息/上下文数据不动，status 仍 open（BR-15）")
    func closeTabKeepsData() async throws {
        let world = try makeWorld()
        try seedMainline(world.messages)
        world.panel.threadID = "t1"
        world.panel.refresh()
        let branch = try await createBranchToReady(world)

        world.panel.closeTab(branchID: branch.id)
        #expect(world.panel.visibleBranches.isEmpty)
        #expect(!world.panel.hasVisibleContent)

        // 数据面不动：branches 行仍 open，支线消息仍在（重启恢复的数据基础，BR-18）。
        let row = try #require(try world.branches.branch(id: branch.id))
        #expect(row.status == .open)
        let history = try world.messages.messages(threadID: "t1", branchID: branch.id)
        #expect(history.count == 2, "seed user + assistant 回答保留")
    }

    // MARK: - 10 轮提示（M3-013，BR-16）

    @Test("10 轮阈值：round>10 显示提示；忽略后本轮不再提示；恰好 10 轮不提示")
    func tenRoundBanner() async throws {
        let world = try makeWorld()
        world.panel.threadID = "t1"

        func seedBranch(id: String, userRounds: Int) throws {
            try world.branches.create(
                id: id, threadID: "t1", anchorQuote: "引文",
                seedContext: "背景", at: t0
            )
            for index in 0..<userRounds {
                try world.messages.insert(makeMessage(
                    id: "\(id)-u\(index)", branchID: id, role: .user,
                    content: "问题 \(index)", sequence: index + 1
                ))
            }
        }

        try seedBranch(id: "b10", userRounds: 10)
        try seedBranch(id: "b11", userRounds: 11)
        world.panel.refresh()

        #expect(!world.panel.shouldShowTenRoundBanner(branchID: "b10"), "恰好 10 轮不提示")
        #expect(world.panel.shouldShowTenRoundBanner(branchID: "b11"), "超过 10 轮提示（BR-16）")

        world.panel.dismissTenRoundBanner(branchID: "b11")
        #expect(!world.panel.shouldShowTenRoundBanner(branchID: "b11"), "忽略后本轮会话不再提示")
    }

    // MARK: - 合并结果状态映射（§7.8 / BR-14）

    @Test("合并：主线程未打开 → 中间态「已保存未注入」；打开后重试注入成功；重复合并不产生重复笔记（BR-14）")
    func mergeStateMapping() async throws {
        let world = try makeWorld()
        world.panel.threadID = "t1"
        try world.branches.create(
            id: "b1", threadID: "t1", anchorQuote: "引文", seedContext: "背景", at: t0
        )
        try world.messages.insert(makeMessage(id: "b1-u", branchID: "b1", role: .user,
                                              content: "支线问题", sequence: 1))
        try world.messages.insert(makeMessage(id: "b1-a", branchID: "b1", role: .assistant,
                                              content: "支线回答", sequence: 2))
        world.panel.refresh()

        // 主线上下文未打开（从未激活）：注入失败 → 中间态 savedNotInjected，库内已落笔记。
        world.panel.merge(branchID: "b1")
        try await waitFor("合并到中间态") {
            if case .savedNotInjected = world.panel.mergeStates["b1"] { return true }
            return false
        }
        guard case .savedNotInjected(let noteID) = world.panel.mergeStates["b1"] else {
            Issue.record("应为 savedNotInjected 中间态")
            return
        }
        #expect(noteID == "merge-note-b1")
        #expect(try world.branches.branch(id: "b1")?.status == .merged)
        #expect(try world.notes.note(forBranch: "b1") != nil)

        // 激活主线后重试注入 → mergedInjected。
        try await world.store.openMostRecentOrCreate(projectRoot: "/tmp")
        world.panel.retryInjection(branchID: "b1")
        try await waitFor("重试注入成功") { world.panel.mergeStates["b1"] == .mergedInjected }

        // 重复点击合并：幂等（BR-14），不产生第二条笔记/主线消息，状态保持已注入。
        world.panel.merge(branchID: "b1")
        try await waitFor("重复合并落定") { world.panel.mergeStates["b1"] == .mergedInjected }
        #expect(try world.notes.listNotes(threadID: "t1").count == 1)
        let mergeMessages = try world.messages.messages(threadID: "t1").filter {
            $0.metadataJSON?.contains("mergeNote") == true
        }
        #expect(mergeMessages.count == 1, "主线注入消息不重复")
    }

    @Test("合并失败：摘要失败映射 failed 状态，支线仍 open，可重试（BR-11 同原则）")
    func mergeFailureMapping() async throws {
        let world = try makeWorld(mergeSummarizer: ThrowingSummarizer())
        world.panel.threadID = "t1"
        try world.branches.create(
            id: "b1", threadID: "t1", anchorQuote: "引文", seedContext: "背景", at: t0
        )
        try world.messages.insert(makeMessage(id: "b1-u", branchID: "b1", role: .user,
                                              content: "支线问题", sequence: 1))
        world.panel.refresh()

        world.panel.merge(branchID: "b1")
        try await waitFor("合并失败落定") {
            if case .failed = world.panel.mergeStates["b1"] { return true }
            return false
        }
        #expect(try world.branches.branch(id: "b1")?.status == .open, "摘要失败零写入，支线仍 open")
        #expect(try world.notes.note(forBranch: "b1") == nil)
    }

    // MARK: - 合并并关闭（M3-013）

    @Test("合并并关闭：合并成功后 status 流转 closed，标签随刷新移除")
    func mergeAndClose() async throws {
        let world = try makeWorld()
        world.panel.threadID = "t1"
        try world.branches.create(
            id: "b1", threadID: "t1", anchorQuote: "引文", seedContext: "背景", at: t0
        )
        try world.messages.insert(makeMessage(id: "b1-u", branchID: "b1", role: .user,
                                              content: "支线问题", sequence: 1))
        world.panel.refresh()
        #expect(world.panel.visibleBranches.count == 1)

        world.panel.mergeAndClose(branchID: "b1")
        try await waitFor("标签移除") { world.panel.visibleBranches.isEmpty }
        #expect(try world.branches.branch(id: "b1")?.status == .closed)
        // 中间态（注入失败）也算合并成功，允许关闭。
        #expect(try world.notes.note(forBranch: "b1") != nil)
    }
}
