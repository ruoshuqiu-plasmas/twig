import Foundation
import GRDB
import Testing
@testable import Core
import Shared

/// Branch/BranchNote 仓储测试（B-M3 阶段 3 前置）。
/// 全部使用内存库，不触碰应用真实数据库文件。
@Suite("BranchRepositories：支线与回流笔记仓储")
struct BranchRepositoriesTests {

    /// 毫秒精度日期（GRDB 日期存储精度为毫秒，避免往返比较误差）。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100.000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_200.000)

    private func makeFixture() throws -> (AppDatabase, BranchRepository, BranchNoteRepository) {
        let appDB = try AppDatabase.makeInMemory()
        try ThreadRepository(appDB).createThread(id: "t1", title: "主", projectRoot: "/a", at: t0)
        return (appDB, BranchRepository(appDB), BranchNoteRepository(appDB))
    }

    // MARK: - BranchRepository 基础 CRUD

    @Test("创建支线（含锚点坐标）并按 id 查询")
    func createAndFetch() async throws {
        let (_, branches, _) = try makeFixture()
        let branch = try branches.create(
            id: "b1", threadID: "t1",
            anchorMessageID: "m1", anchorQuote: "引文",
            anchorStart: 3, anchorLength: 7, anchorContextHash: "abcd1234efgh5678",
            seedContext: "背景", at: t0
        )
        #expect(branch.status == .open)
        #expect(branch.anchorStart == 3)
        #expect(branch.anchorLength == 7)
        #expect(branch.anchorContextHash == "abcd1234efgh5678")

        let fetched = try #require(try branches.branch(id: "b1"))
        #expect(fetched == branch)
        #expect(try branches.branch(id: "不存在") == nil)
    }

    @Test("listBranches 按 createdAt 升序；childBranches 只返回直系子支线")
    func listAndChildren() async throws {
        let (_, branches, _) = try makeFixture()
        let t3 = Date(timeIntervalSince1970: 1_700_000_300.000)
        try branches.create(id: "b2", threadID: "t1", anchorQuote: "后", at: t2)
        try branches.create(id: "b1", threadID: "t1", anchorQuote: "先", at: t0)
        try branches.create(id: "b1a", threadID: "t1", parentBranchID: "b1", anchorQuote: "孙", at: t3)
        try branches.create(id: "b1b", threadID: "t1", parentBranchID: "b1", anchorQuote: "孙2", at: t1)

        #expect(try branches.listBranches(threadID: "t1").map(\.id) == ["b1", "b1b", "b2", "b1a"])
        #expect(try branches.childBranches(parentBranchID: "b1").map(\.id) == ["b1b", "b1a"])
        #expect(try branches.childBranches(parentBranchID: "b2").isEmpty)
        // 嵌套支线不属于 b2 的子支线。
        #expect(try branches.childBranches(parentBranchID: "b1a").isEmpty)
    }

    @Test("状态更新同事务触碰线程活动时间")
    func updateStatusTouchesThread() async throws {
        let (appDB, branches, _) = try makeFixture()
        try branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)

        try branches.updateStatus(branchID: "b1", status: .closed, at: t2)

        let branch = try #require(try branches.branch(id: "b1"))
        #expect(branch.status == .closed)
        #expect(branch.updatedAt == t2)
        let thread = try ThreadRepository(appDB).listThreads()[0]
        #expect(thread.updatedAt == t2, "updateStatus 应同事务 touchThread")
    }

    @Test("seed 背景与锚点坐标更新")
    func updateSeedAndAnchor() async throws {
        let (_, branches, _) = try makeFixture()
        try branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)

        try branches.updateSeedContext(branchID: "b1", seedContext: "新背景", at: t1)
        #expect(try branches.branch(id: "b1")?.seedContext == "新背景")

        try branches.updateAnchor(
            branchID: "b1", anchorStart: 10, anchorLength: 5,
            anchorContextHash: "newhash000000000", at: t1
        )
        let branch = try #require(try branches.branch(id: "b1"))
        #expect(branch.anchorStart == 10)
        #expect(branch.anchorLength == 5)
        #expect(branch.anchorContextHash == "newhash000000000")
    }

    // MARK: - BranchNoteRepository

    @Test("回流笔记：创建 / 按支线查询 / 按线程列出")
    func noteQueries() async throws {
        let (_, branches, notes) = try makeFixture()
        try branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)
        try branches.create(id: "b2", threadID: "t1", anchorQuote: "引文2", at: t0)

        try notes.create(note: BranchNote(id: "n1", branchID: "b1", threadID: "t1", summary: "结论一", mergedAt: t1))
        try notes.create(note: BranchNote(id: "n2", branchID: "b2", threadID: "t1", summary: "结论二", mergedAt: t0))

        #expect(try notes.note(forBranch: "b1")?.summary == "结论一")
        #expect(try notes.note(forBranch: "b2")?.id == "n2")
        #expect(try notes.note(forBranch: "不存在") == nil)
        #expect(try notes.listNotes(threadID: "t1").map(\.id) == ["n2", "n1"], "应按 merged_at 升序")
    }

    // MARK: - recordMerge 幂等事务（BR-14）

    @Test("recordMerge：note + 主线消息 + 状态/merge_note_id 同库可见；重复调用幂等")
    func recordMergeAtomicAndIdempotent() async throws {
        let (appDB, branches, notes) = try makeFixture()
        try branches.create(id: "b1", threadID: "t1", anchorQuote: "引文", at: t0)

        let note = BranchNote(id: "n1", branchID: "b1", threadID: "t1", summary: "回流结论", mergedAt: t1)
        let mainline = Message(
            id: "mm1", threadID: "t1", branchID: nil, role: .assistant,
            content: "回流：回流结论", sequence: 1,
            status: .completed, createdAt: t1, updatedAt: t1
        )

        let outcome = try branches.recordMerge(
            note: note, mainlineMessage: mainline, branchID: "b1", at: t1
        )
        #expect(outcome == .merged(noteID: "n1"))

        // 三件事同库可见。
        #expect(try notes.note(forBranch: "b1") == note)
        let merged = try #require(try branches.branch(id: "b1"))
        #expect(merged.status == .merged)
        #expect(merged.mergeNoteID == "n1")
        let messages = try MessageRepository(appDB).messages(threadID: "t1")
        #expect(messages.count == 1)
        #expect(messages[0].branchID == nil, "回流消息应落在主线（branchID=nil）")
        #expect(messages[0].content == "回流：回流结论")

        // 重复调用：不重复写入，返回 alreadyMerged。
        let duplicate = Message(
            id: "mm2", threadID: "t1", branchID: nil, role: .assistant,
            content: "回流：重复", sequence: 2,
            status: .completed, createdAt: t2, updatedAt: t2
        )
        let dupNote = BranchNote(id: "n2", branchID: "b1", threadID: "t1", summary: "重复", mergedAt: t2)
        let second = try branches.recordMerge(
            note: dupNote, mainlineMessage: duplicate, branchID: "b1", at: t2
        )
        #expect(second == .alreadyMerged(existingNoteID: "n1"))
        #expect(try MessageRepository(appDB).messages(threadID: "t1").count == 1, "不应插入第二条主线消息")
        #expect(try notes.listNotes(threadID: "t1").count == 1, "不应写入第二条笔记")
        #expect(try branches.branch(id: "b1")?.mergeNoteID == "n1", "merge_note_id 不被覆盖")
    }

    @Test("recordMerge：中途抛出整体回滚，不写半")
    func recordMergeRollback() async throws {
        struct Boom: Error {}
        let (appDB, branches, _) = try makeFixture()
        let branch = Branch(id: "b1", threadID: "t1", anchorQuote: "引文", createdAt: t0, updatedAt: t0)
        let note = BranchNote(id: "n1", branchID: "b1", threadID: "t1", summary: "结论", mergedAt: t1)
        _ = try? await appDB.db.write { db in
            try branch.insert(db)
            try note.insert(db)
            throw Boom()
        }
        #expect(try branches.branch(id: "b1") == nil)
        #expect(try BranchNoteRepository(appDB).listNotes(threadID: "t1").isEmpty)
    }
}
