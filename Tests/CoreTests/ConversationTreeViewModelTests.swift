import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// 左侧对话树（M4-002/003/004）ViewModel 可测逻辑：
/// 树含全部支线（closed/merged 不隐藏，TREE-04 数据面）、卡片信息派生（首问摘要/轮数/已回流）、
/// 折叠只隐藏不改数据（TREE-05）、点击出口与选中态、面板 openFromTree 强制打开、
/// DEC-09 数据前提（支线消息落库触碰 updated_at）。
/// 全部使用内存库 + FakeDriver，不派生真实子进程（额度零消耗）。
/// 卡片布局/缩进/徽标配色等 SwiftUI 细节归 G4 手工冒烟清单。
@Suite("ConversationTreeViewModel：左侧对话树")
@MainActor
struct ConversationTreeViewModelTests {

    typealias FakeDriver = BranchSessionCoordinatorTests.FakeDriver

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private struct World {
        let tree: ConversationTreeViewModel
        let panel: BranchPanelViewModel
        let store: ConversationStore
        let branches: BranchRepository
        let messages: MessageRepository
        let notes: BranchNoteRepository
    }

    private func makeWorld() throws -> World {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        try threads.createThread(id: "t1", title: "主线程一", projectRoot: "/tmp", at: t0)

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
            summarizer: FakeSummarizer(),
            conversation: store, now: { self.t0 }
        )
        let panel = BranchPanelViewModel(
            branches: branches, threads: threads, messages: messages,
            conversation: store, coordinator: coordinator, mergeService: merge
        )
        let tree = ConversationTreeViewModel(
            branches: branches, threads: threads, messages: messages, conversation: store
        )
        return World(
            tree: tree, panel: panel, store: store,
            branches: branches, messages: messages, notes: notes
        )
    }

    /// 简易摘要器（本套件不走真实合并摘要路径）。
    private struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "摘要" }
    }

    private func makeMessage(
        id: String, branchID: String? = nil,
        role: MessageRole, content: String, sequence: Int,
        metadataJSON: String? = nil, at: Date? = nil
    ) -> Message {
        Message(
            id: id, threadID: "t1", branchID: branchID, role: role, kind: .text,
            content: content, sequence: sequence, status: .completed,
            createdAt: at ?? t0, updatedAt: at ?? t0, metadataJSON: metadataJSON
        )
    }

    @Test("树含全部支线：closed/merged 不隐藏（关闭标签不删支线，TREE-04 数据面）")
    func treeIncludesAllBranches() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b-open", threadID: "t1", anchorQuote: "甲", at: t0)
        try world.branches.create(id: "b-closed", threadID: "t1", anchorQuote: "乙", at: t0)
        try world.branches.updateStatus(branchID: "b-closed", status: .closed)

        world.tree.threadID = "t1"
        world.tree.refresh()

        #expect(Set(world.tree.tree.roots.map(\.id)) == ["b-open", "b-closed"])
        #expect(world.tree.cardInfos["b-closed"]?.status == .closed)
    }

    @Test("卡片信息：首问摘要/轮数/空摘要回退锚点引文（M4-003）")
    func cardInfoDerivation() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "锚点引文兜底", at: t0)
        // seed 消息（不计轮数、不作摘要）+ 两轮问答。
        try world.messages.insert(makeMessage(
            id: "m-seed", branchID: "b1", role: .user, content: "背景",
            sequence: 1, metadataJSON: #"{"seedContext":true}"#
        ))
        try world.messages.insert(makeMessage(id: "m-q1", branchID: "b1", role: .user, content: "第一个问题？", sequence: 2))
        try world.messages.insert(makeMessage(id: "m-a1", branchID: "b1", role: .assistant, content: "回答一", sequence: 3))
        try world.messages.insert(makeMessage(id: "m-q2", branchID: "b1", role: .user, content: "第二个问题？", sequence: 4))
        try world.branches.create(id: "b2", threadID: "t1", anchorQuote: "只有引文的支线", at: t0)

        world.tree.threadID = "t1"
        world.tree.refresh()

        #expect(world.tree.cardInfos["b1"]?.title == "第一个问题？")
        #expect(world.tree.cardInfos["b1"]?.roundCount == 2)
        #expect(world.tree.cardInfos["b2"]?.title == "只有引文的支线")
        #expect(world.tree.cardInfos["b2"]?.roundCount == 0)
        #expect(world.tree.threadTitle == "主线程一")
    }

    @Test("「已回流」标记：recordMerge 后 mergedBack 为真（TREE-04 徽标数据面）")
    func mergedBackMark() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)
        let note = BranchNote(
            id: "n1", branchID: "b1", threadID: "t1", summary: "结论", mergedAt: t0
        )
        let mainline = makeMessage(id: "m-note", role: .assistant, content: "[支线回流笔记]", sequence: 1)
        let outcome = try world.branches.recordMerge(note: note, mainlineMessage: mainline, branchID: "b1")
        guard case .merged = outcome else { Issue.record("预期首次合并成功"); return }

        world.tree.threadID = "t1"
        world.tree.refresh()

        #expect(world.tree.cardInfos["b1"]?.mergedBack == true)
        #expect(world.tree.cardInfos["b1"]?.status == .merged)
    }

    @Test("折叠只隐藏子树：树数据与卡片信息不变（TREE-05）")
    func collapseOnlyHides() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "父", at: t0)
        try world.branches.create(id: "b2", threadID: "t1", parentBranchID: "b1", anchorQuote: "子", at: t0)

        world.tree.threadID = "t1"
        world.tree.refresh()
        #expect(world.tree.visibleNodes.map(\.id) == ["b1", "b2"])

        world.tree.toggleCollapse("b1")
        #expect(world.tree.visibleNodes.map(\.id) == ["b1"])
        // 数据面不变：完整树仍含子节点。
        #expect(world.tree.tree.roots.first?.children.map(\.id) == ["b2"])
        #expect(world.tree.cardInfos["b2"] != nil)

        world.tree.toggleCollapse("b1")
        #expect(world.tree.visibleNodes.map(\.id) == ["b1", "b2"])
    }

    @Test("点击节点：记录选中并触发出口（M4-004 联动口）")
    func selectTriggersCallback() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)
        world.tree.threadID = "t1"
        world.tree.refresh()

        var selected: String?
        world.tree.onSelectBranch = { selected = $0 }
        world.tree.select(branchID: "b1")

        #expect(selected == "b1")
        #expect(world.tree.selectedBranchID == "b1")
    }

    @Test("面板 openFromTree：closed 支线强制可见且不改 status（TREE-04）")
    func panelOpenFromTree() throws {
        let world = try makeWorld()
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)
        try world.branches.updateStatus(branchID: "b1", status: .closed)

        world.panel.threadID = "t1"
        world.panel.refresh()
        #expect(world.panel.visibleBranches.isEmpty)  // closed 默认过滤

        world.panel.openFromTree(branchID: "b1")
        #expect(world.panel.visibleBranches.map(\.id) == ["b1"])
        #expect(world.panel.activeBranchID == "b1")
        // 不写库：status 仍 closed。
        #expect(try world.branches.branch(id: "b1")?.status == .closed)

        // 关闭标签后恢复不可见。
        world.panel.closeTab(branchID: "b1")
        #expect(world.panel.visibleBranches.isEmpty)
    }

    @Test("DEC-09 数据前提：支线消息落库触碰 updated_at，刷新后轮数与排序更新")
    func messageInsertTouchesBranchActivity() throws {
        let world = try makeWorld()
        let later = t0.addingTimeInterval(600)
        try world.branches.create(id: "b1", threadID: "t1", anchorQuote: "甲", at: t0)
        try world.branches.create(id: "b2", threadID: "t1", anchorQuote: "乙", at: t0)

        world.tree.threadID = "t1"
        world.tree.refresh()
        #expect(world.tree.visibleNodes.map(\.id) == ["b1", "b2"])  // 并列按创建时间/id 兜底

        // b2 来了一条新消息 → updated_at 触碰 → DEC-09 最近活动降序排前。
        try world.messages.insert(makeMessage(id: "m1", branchID: "b2", role: .user, content: "新问题", sequence: 1, at: later))
        world.tree.refresh()

        #expect(world.tree.visibleNodes.map(\.id) == ["b2", "b1"])
        #expect(world.tree.cardInfos["b2"]?.roundCount == 1)
        #expect(world.tree.cardInfos["b2"]?.lastActivity == later)
    }

    @Test("无线程/空支线：空树不崩")
    func emptyState() throws {
        let world = try makeWorld()
        world.tree.refresh()
        #expect(world.tree.visibleNodes.isEmpty)

        world.tree.threadID = "t1"
        world.tree.refresh()
        #expect(world.tree.visibleNodes.isEmpty)
        #expect(world.tree.threadTitle == "主线程一")
    }
}
