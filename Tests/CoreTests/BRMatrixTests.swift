import Foundation
import GRDB
import Testing
@testable import Core
@testable import Features
@testable import Shared

/// Gate G3 测试矩阵 BR-01~18 的 fake 层补洞（任务 M3-014 前半）。
/// 与既有覆盖互补：BR-04/06/07/10/11/13/14/15/16/17 见各自既有测试文件，
/// 本文件收口 BR-01/02/03/05/08/09/12/18 与 G3 附加「面板与数据库一致」。
/// 全部使用内存库/临时文件库 + FakeDriver，不派生真实子进程（额度零消耗）。

// MARK: - 共享测试设施

/// 状态流收集器（模式照 BranchSessionCoordinatorTests.StateCollector）。
private actor BranchStateCollector {
    private var collected: [BranchCreationState] = []

    var last: BranchCreationState? { collected.last }

    @discardableResult
    func collect(_ stream: AsyncStream<BranchCreationState>) -> Task<Void, Never> {
        Task {
            for await state in stream {
                collected.append(state)
            }
        }
    }
}

private func waitForCondition(
    _ description: String,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    _ = try await withTimeout(seconds: 5, operation: description) {
        while await !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// 断言多个标记在文本中按给定顺序出现（照 BranchContextAssemblerTests 模式）。
private func expectOrderedMarkers(_ text: String, _ markers: [String], _ comment: String) {
    var cursor = text.startIndex
    for marker in markers {
        guard let range = text.range(of: marker, range: cursor..<text.endIndex) else {
            Issue.record("\(comment)：缺少「\(marker)」")
            return
        }
        cursor = range.upperBound
    }
}

/// 支线编排世界：内存库 + FakeDriver + 真实 Assembler/Coordinator/ConversationStore。
private struct BranchOrchestrationWorld {
    let coordinator: BranchSessionCoordinator
    let driver: BranchSessionCoordinatorTests.FakeDriver
    let store: ConversationStore
    let branches: BranchRepository
    let messages: MessageRepository
}

private func makeOrchestrationWorld(
    threadID: String = "t1",
    now: Date = Date(timeIntervalSince1970: 1_700_000_000.000)
) throws -> BranchOrchestrationWorld {
    let appDB = try AppDatabase.makeInMemory()
    let threads = ThreadRepository(appDB)
    let messages = MessageRepository(appDB)
    let branches = BranchRepository(appDB)
    let notes = BranchNoteRepository(appDB)
    try threads.createThread(id: threadID, title: "主", projectRoot: "/tmp", at: now)

    let driver = BranchSessionCoordinatorTests.FakeDriver()
    let store = ConversationStore(
        threads: threads, messages: messages, driver: driver, flushInterval: 0
    )
    let assembler = BranchContextAssembler(
        messages: messages, branches: branches, notes: notes
    )
    let coordinator = BranchSessionCoordinator(
        assembler: assembler, branches: branches, conversation: store, now: { now }
    )
    return BranchOrchestrationWorld(
        coordinator: coordinator, driver: driver, store: store,
        branches: branches, messages: messages
    )
}

/// 发起一次支线创建并驱动到 ready，返回新建 branches 行。
@discardableResult
private func createBranchToReady(
    world: BranchOrchestrationWorld,
    request: BranchCreationRequest,
    answer: String,
    promptOrdinal: Int
) async throws -> Branch {
    let collector = BranchStateCollector()
    await collector.collect(await world.coordinator.startCreation(request))
    try await waitForCondition("播种发出（\(request.requestID)）") {
        await world.driver.sentPromptCount >= promptOrdinal + 1
    }
    let sessionCount = await world.driver.sessionCount
    let sessionID = await world.driver.sessionID(at: sessionCount - 1)
    await world.driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: answer))
    await world.driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
    try await waitForCondition("创建到 ready（\(request.requestID)）") {
        await collector.last == .ready
    }
    let row = try world.branches.listBranches(threadID: request.threadID).first {
        $0.anchorMessageID == request.snapshot.messageID && $0.anchorQuote == request.snapshot.quote
    }
    return try #require(row, "创建完成后应存在对应 branches 行")
}

// MARK: - BR-01 / BR-02：主线两条追问入口路径（G3 附加「主线与工具结果均可开支线」）

/// MainChatViewModel 层：assistant 文本消息（BR-01）与 toolCall 卡片消息（BR-02）
/// 各自的选区 → anchorPlainText → 冻结 → BranchCreationRequest 组装全路径。
/// 浮动按钮位置等 SwiftUI 细节归 G3 手工冒烟清单。
@Suite("BR-01/02：主线两类消息的追问入口路径")
@MainActor
struct BRMatrixEntryPathTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private func makeMessage(
        id: String, kind: MessageKind = .text, content: String
    ) -> Message {
        Message(
            id: id, threadID: "t1", role: .assistant, kind: kind, content: content,
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        )
    }

    private func makeViewModel() throws -> MainChatViewModel {
        let appDB = try AppDatabase.makeInMemory()
        let store = ConversationStore(
            threads: ThreadRepository(appDB),
            messages: MessageRepository(appDB),
            driver: BranchSessionCoordinatorTests.FakeDriver(),
            flushInterval: 0
        )
        return MainChatViewModel(store: store, projectRoot: "/tmp")
    }

    @Test("BR-01：assistant 文本消息选区 → 渲染纯文本冻结 → 请求组装（坐标基准为渲染产物）")
    func assistantTextPath() throws {
        let viewModel = try makeViewModel()
        let message = makeMessage(id: "m1", content: "前文**中段**后文")
        viewModel.messages = [message]
        viewModel.threadID = "t1"

        // 锚点纯文本为 Markdown 渲染产物（不含记号）；选区坐标相对该纯文本。
        let plainText = MainChatViewModel.anchorPlainText(for: message)
        #expect(plainText.contains("中段"))
        #expect(!plainText.contains("**"), "渲染后纯文本不应含 markdown 记号")
        let quoteRange = (plainText as NSString).range(of: "中段")
        #expect(quoteRange.location != NSNotFound)
        let snapshot = SelectionSnapshot(
            messageID: "m1", quote: "中段",
            start: quoteRange.location, length: quoteRange.length
        )

        viewModel.currentSelection = snapshot
        viewModel.beginBranchComposition()
        #expect(viewModel.isComposingBranchQuestion)
        #expect(viewModel.frozenSelection == snapshot)
        #expect(viewModel.frozenAnchorPlainText == plainText, "冻结的坐标基准须为渲染纯文本")

        var captured: BranchCreationRequest?
        viewModel.onRequestBranchCreation = { captured = $0 }
        viewModel.branchQuestionInput = "这段什么意思？"
        viewModel.confirmBranchQuestion()

        let request = try #require(captured)
        #expect(request.threadID == "t1")
        #expect(request.parentBranchID == nil, "主线追问为一级支线")
        #expect(request.snapshot == snapshot)
        #expect(request.anchorPlainText == plainText)
        #expect(request.userQuestion == "这段什么意思？")
        #expect(request.projectRoot == "/tmp")
    }

    @Test("BR-02：toolCall 卡片消息选区 → content 本身为锚点纯文本 → 请求组装")
    func toolCallCardPath() throws {
        let viewModel = try makeViewModel()
        let content = "文件读取结果：第一段。第二段。"
        let message = makeMessage(id: "m-tool", kind: .toolCall, content: content)
        viewModel.messages = [message]
        viewModel.threadID = "t1"

        // 工具卡片消息的锚点纯文本即 content 本身（G3 附加「工具结果可开支线」）。
        let quoteRange = (content as NSString).range(of: "第二段")
        let snapshot = SelectionSnapshot(
            messageID: "m-tool", quote: "第二段",
            start: quoteRange.location, length: quoteRange.length
        )

        viewModel.currentSelection = snapshot
        viewModel.beginBranchComposition()
        #expect(viewModel.isComposingBranchQuestion)
        #expect(viewModel.frozenAnchorPlainText == content, "工具卡片锚点纯文本应为 content 本身")

        var captured: BranchCreationRequest?
        viewModel.onRequestBranchCreation = { captured = $0 }
        viewModel.branchQuestionInput = "这个结果怎么来的？"
        viewModel.confirmBranchQuestion()

        let request = try #require(captured)
        #expect(request.snapshot.messageID == "m-tool")
        #expect(request.snapshot.quote == "第二段")
        #expect(request.anchorPlainText == content)
        #expect(request.userQuestion == "这个结果怎么来的？")
        #expect(request.parentBranchID == nil)
    }
}

// MARK: - BR-03：空白选区无追问入口

/// SelectableMessageText 空白过滤（唯一实现 `SelectableMessageText.makeSnapshot`，
/// Coordinator 与测试共用）：空/纯空白/混合空白换行 → nil；含非空白 → snapshot。
@Suite("BR-03：空白选区过滤")
struct BRMatrixBlankSelectionTests {

    @Test("空/纯空白/混合空白换行 → nil（无追问入口）")
    func blankSelectionsFiltered() {
        #expect(SelectableMessageText.makeSnapshot(messageID: "m1", quote: "", start: 0, length: 0) == nil)
        #expect(SelectableMessageText.makeSnapshot(messageID: "m1", quote: "   ", start: 0, length: 3) == nil)
        #expect(SelectableMessageText.makeSnapshot(messageID: "m1", quote: " \n\t ", start: 0, length: 4) == nil,
                "空格/换行/制表符混合空白同样过滤")
        #expect(SelectableMessageText.makeSnapshot(messageID: "m1", quote: "\n\n", start: 2, length: 2) == nil)
    }

    @Test("含非空白字符 → snapshot（坐标原样保留，含首尾空白）")
    func nonBlankSelectionProducesSnapshot() {
        let snapshot = SelectableMessageText.makeSnapshot(
            messageID: "m1", quote: " 中段 ", start: 4, length: 4
        )
        #expect(snapshot == SelectionSnapshot(messageID: "m1", quote: " 中段 ", start: 4, length: 4))
        // 仅换行包围的正文也算有效选区。
        #expect(SelectableMessageText.makeSnapshot(messageID: "m1", quote: "\n正文\n", start: 0, length: 4) != nil)
    }
}

// MARK: - BR-05 / BR-08：支线 session 独立与历史隔离（fake 层全编排）

/// FakeDriver + 内存库走 BranchSessionCoordinator 全编排：
/// 一级支线创建后 session 独立（BR-05）；支线内 sendBranchMessage 追问的历史
/// 只累积在支线，主线/支线消息查询互不包含（BR-08 双向）。
@Suite("BR-05/08：支线 session 独立与历史隔离")
struct BRMatrixHistoryIsolationTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    @Test("一级支线：独立 session（owner=.branch）；支线追问只进支线历史、主线追问只进主线历史")
    func branchSessionIndependentAndHistoryIsolated() async throws {
        let world = try makeOrchestrationWorld(now: t0)
        // 主线问答（锚点消息 m2 为 assistant 回答）。
        try world.messages.insert(Message(
            id: "m1", threadID: "t1", role: .user, content: "主线问题",
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        ))
        try world.messages.insert(Message(
            id: "m2", threadID: "t1", role: .assistant, content: "锚点原文",
            sequence: 2, status: .completed, createdAt: t0, updatedAt: t0
        ))

        // 打开主线 → session 0（owner=.thread）。
        try await world.store.openMostRecentOrCreate(projectRoot: "/tmp")
        try await waitForCondition("主线 session 建立") { await world.driver.sessionCount == 1 }
        let mainlineSession = await world.driver.sessionID(at: 0)
        #expect(await world.driver.sessionOwner(at: 0) == .thread("t1"))

        // 一级支线创建到 ready → session 1（owner=.branch）。
        let branch = try await createBranchToReady(
            world: world,
            request: BranchCreationRequest(
                requestID: "req-br05", threadID: "t1",
                snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
                anchorPlainText: "锚点原文", userQuestion: "这段什么意思？", projectRoot: "/tmp"
            ),
            answer: "播种回答", promptOrdinal: 0
        )

        // BR-05：支线 session 独立于主线 session，且归属 .branch。
        #expect(await world.driver.sessionCount == 2)
        let branchSession = await world.driver.sessionID(at: 1)
        #expect(branchSession != mainlineSession)
        #expect(await world.driver.sessionOwner(at: 1) == .branch(branch.id))

        // 支线内追问（BR-08）：prompt 只发往支线 session，历史只累积在支线。
        try await world.store.sendBranchMessage(branchID: branch.id, text: "支线追问一")
        try await waitForCondition("支线追问发出") { await world.driver.sentPromptCount == 2 }
        await world.driver.emit(sessionID: branchSession, .textDelta(sessionID: branchSession, text: "支线回答一"))
        await world.driver.emit(sessionID: branchSession, .completed(sessionID: branchSession, stopReason: "end_turn"))
        try await waitForCondition("支线历史 4 条") {
            (try? world.messages.messages(threadID: "t1", branchID: branch.id).count) == 4
        }

        let branchPrompts = await world.driver.prompts(for: branchSession)
        #expect(branchPrompts.count == 2, "支线 session 只收到播种 + 支线追问")
        #expect(branchPrompts.last == "支线追问一")
        #expect(await world.driver.prompts(for: mainlineSession).isEmpty,
                "主线 session 不应收到支线播种/追问")

        let branchHistory = try world.messages.messages(threadID: "t1", branchID: branch.id)
        #expect(branchHistory.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(branchHistory[2].content == "支线追问一")
        #expect(branchHistory[3].content == "支线回答一")
        #expect(branchHistory.allSatisfy { $0.branchID == branch.id })

        // 主线追问（反向隔离）：只进主线历史，不进支线。
        try await world.store.send(text: "主线追问一")
        try await waitForCondition("主线追问发出") { await world.driver.sentPromptCount == 3 }
        await world.driver.emit(sessionID: mainlineSession, .textDelta(sessionID: mainlineSession, text: "主线回答一"))
        await world.driver.emit(sessionID: mainlineSession, .completed(sessionID: mainlineSession, stopReason: "end_turn"))
        try await waitForCondition("主线历史 4 条") {
            (try? world.messages.messages(threadID: "t1").count) == 4
        }

        let mainlineHistory = try world.messages.messages(threadID: "t1")
        #expect(Set(mainlineHistory.map(\.id)).isSuperset(of: ["m1", "m2"]))
        #expect(mainlineHistory.allSatisfy { $0.branchID == nil }, "主线查询只含 branch_id 为 NULL 的消息")
        #expect(!mainlineHistory.contains { $0.content == "支线追问一" || $0.content == "支线回答一" },
                "主线历史不含支线消息")
        let branchHistoryAfter = try world.messages.messages(threadID: "t1", branchID: branch.id)
        #expect(branchHistoryAfter.count == 4, "主线追问不得进入支线历史")
        #expect(!branchHistoryAfter.contains { $0.content == "主线追问一" || $0.content == "主线回答一" })
    }
}

// MARK: - BR-09：三级嵌套创建链

/// coordinator 层连续创建 parent → child → grandchild（每级锚点为上一级支线内的消息），
/// 断言 branches 行 parentBranchID 链正确，且三级创建的播种背景含根→叶祖先链
/// （Assembler 祖先链字段级断言见 BranchContextAssemblerTests.nestedAncestorChain）。
@Suite("BR-09：三级嵌套创建链")
struct BRMatrixNestingTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    @Test("parent→child→grandchild：parentBranchID 链与锚点消息链正确；三级播种含根→叶祖先链")
    func threeLevelNesting() async throws {
        let world = try makeOrchestrationWorld(now: t0)
        try world.messages.insert(Message(
            id: "m1", threadID: "t1", role: .user, content: "主线问题",
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        ))
        try world.messages.insert(Message(
            id: "m2", threadID: "t1", role: .assistant, content: "锚点原文",
            sequence: 2, status: .completed, createdAt: t0, updatedAt: t0
        ))

        // 一级：锚点在主线 m2。
        let parent = try await createBranchToReady(
            world: world,
            request: BranchCreationRequest(
                requestID: "req-l1", threadID: "t1",
                snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
                anchorPlainText: "锚点原文", userQuestion: "一级追问", projectRoot: "/tmp"
            ),
            answer: "一级回答", promptOrdinal: 0
        )
        let parentAnswer = try #require(
            try world.messages.messages(threadID: "t1", branchID: parent.id)
                .first { $0.role == .assistant }
        )

        // 二级：锚点在一级支线的回答消息上。
        let child = try await createBranchToReady(
            world: world,
            request: BranchCreationRequest(
                requestID: "req-l2", threadID: "t1", parentBranchID: parent.id,
                snapshot: SelectionSnapshot(messageID: parentAnswer.id, quote: "一级", start: 0, length: 2),
                anchorPlainText: "一级回答", userQuestion: "二级追问", projectRoot: "/tmp"
            ),
            answer: "二级回答", promptOrdinal: 1
        )
        let childAnswer = try #require(
            try world.messages.messages(threadID: "t1", branchID: child.id)
                .first { $0.role == .assistant }
        )

        // 三级：锚点在二级支线的回答消息上。
        let grandchild = try await createBranchToReady(
            world: world,
            request: BranchCreationRequest(
                requestID: "req-l3", threadID: "t1", parentBranchID: child.id,
                snapshot: SelectionSnapshot(messageID: childAnswer.id, quote: "二级", start: 0, length: 2),
                anchorPlainText: "二级回答", userQuestion: "三级追问", projectRoot: "/tmp"
            ),
            answer: "三级回答", promptOrdinal: 2
        )

        // parentBranchID 链与锚点消息链。
        #expect(parent.parentBranchID == nil)
        #expect(child.parentBranchID == parent.id)
        #expect(grandchild.parentBranchID == child.id)
        #expect(child.anchorMessageID == parentAnswer.id, "二级锚点须落在一级支线消息上")
        #expect(grandchild.anchorMessageID == childAnswer.id, "三级锚点须落在二级支线消息上")
        #expect(try world.branches.childBranches(parentBranchID: parent.id).map(\.id) == [child.id])
        #expect(try world.branches.childBranches(parentBranchID: child.id).map(\.id) == [grandchild.id])

        // 三级播种背景：祖先链根→叶（parent → child），各级锚点引文齐全。
        let seed = try #require(grandchild.seedContext)
        expectOrderedMarkers(
            seed,
            ["[背景上下文]", "[祖先支线]", "── 支线 1 ──", "── 支线 2 ──",
             "[当前选中段落]", "[用户追问]"],
            "三级播种模板段落与祖先链顺序"
        )
        #expect(seed.contains("锚点引文：锚点"), "祖先链第一节为一级支线（锚点引文「锚点」）")
        #expect(seed.contains("锚点引文：一级"), "祖先链第二节为二级支线（锚点引文「一级」）")
        // 各祖先块的「最近回答」取该支线最近完成的 assistant 回答。
        #expect(seed.contains("最近回答：一级回答"))
        #expect(seed.contains("最近回答：二级回答"))
        expectOrderedMarkers(seed, ["锚点引文：锚点", "锚点引文：一级"], "祖先链引文根→叶顺序")

        // 三个支线各建独立 session。
        #expect(await world.driver.sessionCount == 3)
        #expect(await world.driver.sessionOwner(at: 0) == .branch(parent.id))
        #expect(await world.driver.sessionOwner(at: 1) == .branch(child.id))
        #expect(await world.driver.sessionOwner(at: 2) == .branch(grandchild.id))
    }
}

// MARK: - BR-12：引文回跳解析集成面

/// 真实 branches 行锚点字段 + 锚点消息渲染纯文本走 BranchPanelViewModel.jumpToAnchor
/// → AnchorResolver.resolve：坐标/指纹一致 → exact 出口；原文改写（坐标+指纹失配）
/// → degradedToMessage。
/// （Resolver 三条规则的字段级单测见 AnchorResolverTests；此处验证集成面。）
@Suite("BR-12：引文回跳解析集成")
@MainActor
struct BRMatrixAnchorJumpTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "压缩摘要" }
    }

    private struct World {
        let panel: BranchPanelViewModel
        let branches: BranchRepository
        let messages: MessageRepository
    }

    private func makeWorld() throws -> World {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)

        let driver = BranchSessionCoordinatorTests.FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store, now: { self.t0 }
        )
        let merge = BranchMergeService(
            branches: branches, notes: notes, messages: messages,
            summarizer: FakeSummarizer(), conversation: store, now: { self.t0 }
        )
        let panel = BranchPanelViewModel(
            branches: branches, threads: threads, messages: messages,
            conversation: store, coordinator: coordinator, mergeService: merge
        )
        return World(panel: panel, branches: branches, messages: messages)
    }

    /// 播种主线锚点消息与带真实锚点字段的 branches 行。
    /// `currentContent` 非空时模拟「原文已变化」：branches 行保留创建时的锚点字段
    /// （引文/坐标/指纹均相对原始文本），消息内容已是新文本。
    /// 返回 (渲染纯文本, 引文在纯文本中的 Character 偏移)。
    @discardableResult
    private func seedAnchor(
        _ world: World, branchID: String, currentContent: String? = nil
    ) throws -> (plainText: String, start: Int, length: Int) {
        let originalPlainText = "前文中段后文"
        try world.messages.insert(Message(
            id: "m2", threadID: "t1", role: .assistant,
            content: currentContent ?? "前文**中段**后文",
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        ))
        // 锚点字段始终相对创建时的原始渲染纯文本（ADR-003）。
        let utf16Range = (originalPlainText as NSString).range(of: "中段")
        let coordinates = try #require(AnchorCoordinates.characterRange(
            utf16Start: utf16Range.location, utf16Length: utf16Range.length, in: originalPlainText
        ))
        try world.branches.create(
            id: branchID, threadID: "t1",
            anchorMessageID: "m2", anchorQuote: "中段",
            anchorStart: coordinates.start, anchorLength: coordinates.length,
            anchorContextHash: AnchorResolver.contextHash(of: originalPlainText),
            seedContext: "背景", at: t0
        )
        return (originalPlainText, coordinates.start, coordinates.length)
    }

    @Test("坐标与上下文指纹一致 → 回跳出口 exact（精确范围）")
    func jumpResolvesExact() throws {
        let world = try makeWorld()
        let anchor = try seedAnchor(world, branchID: "b1")
        world.panel.threadID = "t1"
        world.panel.refresh()

        var captured: AnchorJump?
        world.panel.onJumpToMainline = { captured = $0 }
        world.panel.jumpToAnchor(branchID: "b1")

        let jump = try #require(captured)
        #expect(jump.messageID == "m2")
        #expect(jump.resolution == .exact(start: anchor.start, length: anchor.length, ambiguous: false),
                "行内锚点字段 + 渲染纯文本应解析为精确范围")
    }

    @Test("原文已变化（坐标失配 + 上下文指纹失配）→ 回跳出口 degradedToMessage（降级消息级）")
    func jumpDegradesWhenSourceChanged() throws {
        let world = try makeWorld()
        // branches 行保留创建时锚点字段，消息内容已被改写（坐标切片与指纹双双失配）。
        try seedAnchor(world, branchID: "b1", currentContent: "完全改写后的回答，原文已不在")
        world.panel.threadID = "t1"
        world.panel.refresh()

        var captured: AnchorJump?
        world.panel.onJumpToMainline = { captured = $0 }
        world.panel.jumpToAnchor(branchID: "b1")

        let jump = try #require(captured)
        #expect(jump.messageID == "m2")
        #expect(jump.resolution == .degradedToMessage(messageID: "m2"),
                "原文已改写：坐标切片与上下文指纹双失配，须降级消息级")
    }
}

// MARK: - BR-18：重启持久化（临时文件库）

/// 临时文件库造 thread/三级 branches（含锚点坐标与 seed）/支线消息/merged 笔记与注入消息
/// + session 映射 → 重新打开同一文件库逐字段断言完好；
/// SessionStore.restoreFromStore 恢复映射一律 isLive=false（内存库单测见 SessionStoreTests，
/// 此处验证文件库重启链路）。
@Suite("BR-18：重启后支线树/锚点/回流状态持久化")
struct BRMatrixPersistenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100.000)

    private func makeMessage(
        _ id: String, branchID: String? = nil, role: MessageRole,
        content: String, sequence: Int, metadataJSON: String? = nil
    ) -> Message {
        Message(
            id: id, threadID: "t1", branchID: branchID, role: role, content: content,
            sequence: sequence, status: .completed, createdAt: t0, updatedAt: t0,
            metadataJSON: metadataJSON
        )
    }

    @Test("文件库重开：支线树/锚点坐标/seed/支线消息/merged 笔记与注入消息/session 映射逐字段完好")
    func reopenPreservesBranchWorld() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("br18-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("twig.sqlite").path

        let b1Hash = AnchorResolver.contextHash(of: "主线回答原文")
        let b2Hash = AnchorResolver.contextHash(of: "一级回答原文")

        // 第一次打开：造完整支线世界。
        do {
            let appDB = try AppDatabase(DatabasePool(path: databasePath))
            let threads = ThreadRepository(appDB)
            let messages = MessageRepository(appDB)
            let branches = BranchRepository(appDB)
            try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)

            // 主线消息 + 三级支线（b1 → b2 → b3，锚点坐标与 seed 齐全）。
            try messages.insert(makeMessage("m1", role: .user, content: "主线问题", sequence: 1))
            try messages.insert(makeMessage("m2", role: .assistant, content: "主线回答原文", sequence: 2))
            try branches.create(
                id: "b1", threadID: "t1",
                anchorMessageID: "m2", anchorQuote: "主线回答",
                anchorStart: 0, anchorLength: 4, anchorContextHash: b1Hash,
                seedContext: "一级种子背景", at: t0
            )
            try messages.insert(makeMessage("b1-u", branchID: "b1", role: .user, content: "一级问题", sequence: 1))
            try messages.insert(makeMessage("b1-a", branchID: "b1", role: .assistant, content: "一级回答原文", sequence: 2))
            try branches.create(
                id: "b2", threadID: "t1", parentBranchID: "b1",
                anchorMessageID: "b1-a", anchorQuote: "一级回答",
                anchorStart: 0, anchorLength: 4, anchorContextHash: b2Hash,
                seedContext: "二级种子背景", at: t0
            )
            try messages.insert(makeMessage("b2-u", branchID: "b2", role: .user, content: "二级问题", sequence: 1))
            try branches.create(
                id: "b3", threadID: "t1", parentBranchID: "b2",
                anchorMessageID: "b2-a", anchorQuote: "二级回答",
                anchorStart: 0, anchorLength: 4,
                seedContext: "三级种子背景", at: t0
            )
            // b3 已回流：笔记 + 主线注入消息 + status/merge_note_id 同事务。
            let note = BranchNote(id: "n3", branchID: "b3", threadID: "t1", summary: "三级结论", mergedAt: t1)
            let injection = makeMessage(
                "mm3", role: .assistant, content: "回流：三级结论", sequence: 3,
                metadataJSON: #"{"mergeNote":"true"}"#
            )
            let outcome = try branches.recordMerge(note: note, mainlineMessage: injection, branchID: "b3", at: t1)
            #expect(outcome == .merged(noteID: "n3"))

            // session 映射（主线 + 支线各一）。
            try threads.saveMapping(sessionID: "sess-main", owner: .thread("t1"))
            try threads.saveMapping(sessionID: "sess-b1", owner: .branch("b1"))
        }

        // 重新打开同一文件库（模拟应用重启）。
        let reopened = try AppDatabase(DatabasePool(path: databasePath))
        let rThreads = ThreadRepository(reopened)
        let rMessages = MessageRepository(reopened)
        let rBranches = BranchRepository(reopened)
        let rNotes = BranchNoteRepository(reopened)

        // 支线树：parentBranchID 链完好。
        let rows = try rBranches.listBranches(threadID: "t1")
        #expect(rows.map(\.id) == ["b1", "b2", "b3"])
        #expect(rows[0].parentBranchID == nil)
        #expect(rows[1].parentBranchID == "b1")
        #expect(rows[2].parentBranchID == "b2")

        // 锚点字段与 seed 完好（含 hash 为 NULL 的 b3 行）。
        let b1 = try #require(rows.first { $0.id == "b1" })
        #expect(b1.anchorMessageID == "m2")
        #expect(b1.anchorQuote == "主线回答")
        #expect(b1.anchorStart == 0 && b1.anchorLength == 4)
        #expect(b1.anchorContextHash == b1Hash)
        #expect(b1.seedContext == "一级种子背景")
        #expect(b1.status == .open)
        let b3 = try #require(rows.first { $0.id == "b3" })
        #expect(b3.anchorContextHash == nil)
        #expect(b3.seedContext == "三级种子背景")

        // 回流状态完好：merged + merge_note_id + 笔记 + 主线注入消息。
        #expect(b3.status == .merged)
        #expect(b3.mergeNoteID == "n3")
        #expect(try rNotes.note(forBranch: "b3")?.summary == "三级结论")
        let mainline = try rMessages.messages(threadID: "t1")
        #expect(mainline.map(\.id) == ["m1", "m2", "mm3"])
        let injected = try #require(mainline.first { $0.id == "mm3" })
        #expect(injected.branchID == nil)
        #expect(injected.content == "回流：三级结论")
        #expect(injected.metadataJSON?.contains("mergeNote") == true)

        // 支线消息历史完好（含嵌套支线）。
        #expect(try rMessages.messages(threadID: "t1", branchID: "b1").map(\.id) == ["b1-u", "b1-a"])
        #expect(try rMessages.messages(threadID: "t1", branchID: "b2").map(\.id) == ["b2-u"])

        // session 映射：restoreFromStore 重建且一律 isLive=false（不制造「已续接」假象）。
        let sessionStore = SessionStore(mappingStore: rThreads)
        try await sessionStore.restoreFromStore()
        let registrations = await sessionStore.allRegistrations()
        #expect(registrations.count == 2)
        #expect(registrations.allSatisfy { !$0.isLive }, "重启恢复的 session 映射一律失效标记")
        #expect(registrations.contains { $0.sessionID == "sess-main" && $0.owner == .thread("t1") })
        #expect(registrations.contains { $0.sessionID == "sess-b1" && $0.owner == .branch("b1") })
    }
}

// MARK: - G3 附加：面板标签/锚点/状态与数据库一致

/// BranchPanelViewModel 可见列表/状态徽标/锚点引文与仓储查询逐字段一致性：
/// 库内 open/merged/closed 三态各一行 → 面板可见列表逐字段等于仓储行（closed 过滤）、
/// merged 行徽标恢复为 mergedInjected、锚点引文与标题回退一致。
@Suite("G3附加：支线面板与数据库逐字段一致")
@MainActor
struct BRMatrixPanelConsistencyTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100.000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_200.000)

    private struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "压缩摘要" }
    }

    @Test("可见列表逐字段等于仓储行（closed 过滤）；merged 徽标恢复；锚点引文/标题与库内一致")
    func panelMatchesRepository() throws {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)

        let driver = BranchSessionCoordinatorTests.FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store, now: { self.t0 }
        )
        let merge = BranchMergeService(
            branches: branches, notes: notes, messages: messages,
            summarizer: FakeSummarizer(), conversation: store, now: { self.t0 }
        )
        let panel = BranchPanelViewModel(
            branches: branches, threads: threads, messages: messages,
            conversation: store, coordinator: coordinator, mergeService: merge
        )

        // 库内三态各一行（含锚点坐标），createdAt 拉开以固定排序。
        try branches.create(
            id: "b-open", threadID: "t1", anchorMessageID: "m2", anchorQuote: "引文一",
            anchorStart: 0, anchorLength: 3,
            anchorContextHash: AnchorResolver.contextHash(of: "原文一"),
            seedContext: "背景一", at: t0
        )
        try branches.create(
            id: "b-merged", threadID: "t1", anchorMessageID: "m3", anchorQuote: "引文二",
            anchorStart: 2, anchorLength: 3,
            anchorContextHash: AnchorResolver.contextHash(of: "原文二"),
            seedContext: "背景二", at: t1
        )
        try branches.recordMerge(
            note: BranchNote(id: "n2", branchID: "b-merged", threadID: "t1", summary: "结论二", mergedAt: t2),
            mainlineMessage: Message(
                id: "mm2", threadID: "t1", role: .assistant, content: "回流：结论二",
                sequence: 1, status: .completed, createdAt: t2, updatedAt: t2,
                metadataJSON: #"{"mergeNote":"true"}"#
            ),
            branchID: "b-merged", at: t2
        )
        try branches.create(id: "b-closed", threadID: "t1", anchorQuote: "引文三", at: t2)
        try branches.updateStatus(branchID: "b-closed", status: .closed, at: t2)

        panel.threadID = "t1"
        panel.refresh()

        // 可见列表逐字段等于仓储行（closed 被过滤；Branch 为 Equatable 全字段比较）。
        let repoRows = try branches.listBranches(threadID: "t1")
        let expected = repoRows.filter { $0.status != .closed }
        #expect(panel.visibleBranches == expected, "面板可见支线应与仓储查询逐字段一致")
        #expect(panel.visibleBranches.map(\.id) == ["b-open", "b-merged"])

        // 状态徽标：merged 行恢复为 mergedInjected，open 行无合并徽标。
        #expect(panel.mergeStates["b-merged"] == .mergedInjected)
        #expect(panel.mergeStates["b-open"] == nil)

        // 锚点引文与库内一致；无消息时标题回退锚点引文（§7.7）。
        #expect(panel.visibleBranches.map(\.anchorQuote) == ["引文一", "引文二"])
        let openRow = try #require(panel.visibleBranches.first { $0.id == "b-open" })
        #expect(panel.title(for: openRow) == "引文一")
        #expect(openRow.anchorStart == 0 && openRow.anchorLength == 3)
        #expect(openRow.anchorContextHash == AnchorResolver.contextHash(of: "原文一"))
    }
}
