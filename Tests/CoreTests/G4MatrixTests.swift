import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// G4 矩阵补充测试（M4-011）：不适合放进单一组件套件的跨组件/库级场景。
/// - TREE-03 集成：树点击 → 面板打开标签 + 锚点回跳出口（与引文点击同管线）；
/// - REC-03：数据库文件损坏 → 打开/migration 失败抛出、原文件字节不变（不损原库）。
/// 其余 TREE/THREAD/REC 条目分散在 BranchTreeBuilderTests / ConversationTreeViewModelTests /
/// ThreadListViewModelTests / SessionRecoveryTests / AnchorResolverTests（TREE-07/08）。
@Suite("G4 矩阵补充")
@MainActor
struct G4MatrixTests {

    typealias FakeDriver = BranchSessionCoordinatorTests.FakeDriver

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    // MARK: - TREE-03 集成

    private struct World {
        let tree: ConversationTreeViewModel
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
        try threads.createThread(id: "t1", title: "主线程", projectRoot: "/tmp", at: t0)
        let driver = FakeDriver()
        let store = ConversationStore(threads: threads, messages: messages, driver: driver, flushInterval: 0)
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
        let tree = ConversationTreeViewModel(
            branches: branches, threads: threads, messages: messages, conversation: store
        )
        return World(tree: tree, panel: panel, branches: branches, messages: messages)
    }

    private struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "摘要" }
    }

    @Test("TREE-03 集成：点击树节点 → 激活右侧标签 + 发出主线锚点回跳（与引文点击一致）")
    func treeClickActivatesAndJumps() throws {
        let world = try makeWorld()
        // 主线锚点消息（assistant 正文）。
        try world.messages.insert(Message(
            id: "m1", threadID: "t1", branchID: nil, role: .assistant, kind: .text,
            content: "这是锚点所在的回答正文", sequence: 1, status: .completed,
            createdAt: t0, updatedAt: t0, metadataJSON: nil
        ))
        try world.branches.create(
            id: "b1", threadID: "t1", anchorMessageID: "m1", anchorQuote: "回答正文", at: t0
        )

        // 按 App 层接线方式编排（BranchConversationApp.startUp 同款）。
        var jump: AnchorJump?
        world.panel.onJumpToMainline = { jump = $0 }
        world.tree.onSelectBranch = { branchID in
            world.panel.openFromTree(branchID: branchID)
            world.panel.jumpToAnchorFromTree(branchID: branchID)
        }
        world.tree.threadID = "t1"
        world.panel.threadID = "t1"
        world.tree.refresh()

        world.tree.select(branchID: "b1")

        #expect(world.panel.activeBranchID == "b1")          // 标签已激活
        #expect(world.tree.selectedBranchID == "b1")          // 树选中态
        #expect(jump?.messageID == "m1")                      // 回跳目标 = 锚点消息
    }

    @Test("TREE-03 集成（嵌套）：点击嵌套支线 → 激活子节点标签，不抢回父级、不发主线回跳")
    func treeClickNestedBranchKeepsChildActive() throws {
        let world = try makeWorld()
        try world.messages.insert(Message(
            id: "m1", threadID: "t1", branchID: nil, role: .assistant, kind: .text,
            content: "主线回答正文", sequence: 1, status: .completed,
            createdAt: t0, updatedAt: t0, metadataJSON: nil
        ))
        try world.branches.create(
            id: "b1", threadID: "t1", anchorMessageID: "m1", anchorQuote: "主线正文", at: t0
        )
        try world.messages.insert(Message(
            id: "m2", threadID: "t1", branchID: "b1", role: .assistant, kind: .text,
            content: "父支线回答正文", sequence: 2, status: .completed,
            createdAt: t0, updatedAt: t0, metadataJSON: nil
        ))
        try world.branches.create(
            id: "b2", threadID: "t1", parentBranchID: "b1",
            anchorMessageID: "m2", anchorQuote: "父支线正文", at: t0
        )

        // 与 App 层同款接线（jumpToAnchorFromTree 替代引文场景的 jumpToAnchor）。
        var jump: AnchorJump?
        world.panel.onJumpToMainline = { jump = $0 }
        world.tree.onSelectBranch = { branchID in
            world.panel.openFromTree(branchID: branchID)
            world.panel.jumpToAnchorFromTree(branchID: branchID)
        }
        world.tree.threadID = "t1"
        world.panel.threadID = "t1"
        world.tree.refresh()

        world.tree.select(branchID: "b2")

        #expect(world.panel.activeBranchID == "b2")   // 激活权归点的子节点（不被降级抢回 b1）
        #expect(world.tree.selectedBranchID == "b2")
        #expect(jump == nil)                          // 嵌套锚点在父支线流中，不发主线回跳
    }

    // MARK: - REC-03

    @Test("REC-03：数据库文件损坏 → 打开失败抛出、原文件字节不变（阻止写入不损原库）")
    func corruptedDatabasePreserved() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-rec03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("twig.sqlite")
        let garbage = Data("这不是一个 SQLite 数据库文件……".utf8)
        try garbage.write(to: dbURL)

        #expect(throws: (any Error).self) {
            _ = try AppDatabase.makeDefault(directory: dir)
        }
        // 原库文件字节不变（未被截断/覆盖）。
        #expect(try Data(contentsOf: dbURL) == garbage)
    }

    @Test("REC-03 对照：空目录全新建库 + 二次打开既有库 migration 幂等")
    func freshAndExistingDatabaseMigrate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("twig-rec03-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try AppDatabase.makeDefault(directory: dir)
        try ThreadRepository(first).createThread(id: "t1", title: "甲", projectRoot: "/tmp", at: t0)
        // 二次打开（模拟应用重启）：migration 幂等，数据仍在。
        let second = try AppDatabase.makeDefault(directory: dir)
        #expect(try ThreadRepository(second).listThreads().map(\.id) == ["t1"])
    }
}
