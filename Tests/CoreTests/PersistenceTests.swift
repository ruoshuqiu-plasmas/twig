import Foundation
import GRDB
import Testing
@testable import Core
import Shared

/// GRDB 首版 migration 与仓储层测试（M1-011）。
/// 全部使用内存库，不触碰应用真实数据库文件。
@Suite("Persistence：migration 与仓储")
struct PersistenceTests {

    /// 毫秒精度日期（GRDB 日期存储精度为毫秒，避免往返比较误差）。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100.000)

    private func tableNames(_ appDB: AppDatabase) throws -> Set<String> {
        try appDB.db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    private func columnNames(_ appDB: AppDatabase, table: String) throws -> Set<String> {
        try appDB.db.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
        }
    }

    // MARK: - migration

    @Test("空库迁移：四表 + 工程字段 + 索引齐全")
    func migrateEmptyDatabase() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let tables = try tableNames(appDB)
        #expect(tables.isSuperset(of: ["threads", "messages", "branches", "branch_notes"]))

        let messageColumns = try columnNames(appDB, table: "messages")
        #expect(messageColumns.isSuperset(of: [
            "id", "thread_id", "branch_id", "role", "kind", "content",
            "sequence", "status", "created_at", "updated_at", "metadata_json"
        ]))
        let threadColumns = try columnNames(appDB, table: "threads")
        #expect(threadColumns.isSuperset(of: ["id", "title", "project_root", "acp_session_id", "created_at", "updated_at"]))
        let branchColumns = try columnNames(appDB, table: "branches")
        #expect(branchColumns.isSuperset(of: [
            "id", "thread_id", "parent_branch_id", "acp_session_id", "anchor_message_id",
            "anchor_quote", "seed_context", "status", "merge_note_id", "created_at", "updated_at"
        ]))
        let noteColumns = try columnNames(appDB, table: "branch_notes")
        #expect(noteColumns.isSuperset(of: ["id", "branch_id", "thread_id", "summary", "merged_at"]))

        let indexes = try await appDB.db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        #expect(indexes.contains("idx_messages_thread_branch_seq"))
        #expect(indexes.contains("idx_branches_thread"))
    }

    @Test("迁移幂等：对已迁移库重复执行不报错、数据保留")
    func migrateIdempotent() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        try threads.createThread(id: "t1", title: "主线程", projectRoot: "/tmp", at: t0)

        // 重复跑同一 migrator（模拟应用二次启动）。
        try Migrations.migrator.migrate(appDB.db)

        let all = try threads.listThreads()
        #expect(all.count == 1)
        #expect(all[0].title == "主线程")
    }

    @Test("外键约束生效：消息引用不存在的线程被拒绝")
    func foreignKeyEnforced() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let messages = MessageRepository(appDB)
        let orphan = Message(
            id: "m1", threadID: "不存在", role: .user, content: "hi",
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        )
        #expect(throws: (any Error).self) {
            try messages.insert(orphan)
        }
    }

    // MARK: - ThreadRepository + SessionMappingStore

    @Test("线程创建与最近活动排序")
    func threadListOrdering() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        try threads.createThread(id: "t1", title: "旧", projectRoot: "/a", at: t0)
        try threads.createThread(id: "t2", title: "新", projectRoot: "/b", at: t1)

        let all = try threads.listThreads()
        #expect(all.map(\.id) == ["t2", "t1"])
        #expect(all[1].projectRoot == "/a")
    }

    @Test("session 映射持久化：save/load/remove 回环（thread 与 branch 两路）")
    func sessionMappingRoundtrip() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/a", at: t0)
        // 支线仅建表验证映射路径（B-M3 才做完整仓储）。
        try await appDB.db.write { db in
            try Branch(
                id: "b1", threadID: "t1", anchorQuote: "引文",
                createdAt: t0, updatedAt: t0
            ).insert(db)
        }

        try threads.saveMapping(sessionID: "s1", owner: .thread("t1"))
        try threads.saveMapping(sessionID: "s2", owner: .branch("b1"))
        var mappings = try threads.loadMappings()
        mappings.sort { $0.sessionID < $1.sessionID }
        #expect(mappings.count == 2)
        #expect(mappings[0].sessionID == "s1" && mappings[0].owner == .thread("t1"))
        #expect(mappings[1].sessionID == "s2" && mappings[1].owner == .branch("b1"))

        try threads.removeMapping(sessionID: "s1")
        let remaining = try threads.loadMappings()
        #expect(remaining.count == 1)
        #expect(remaining[0].sessionID == "s2")
    }

    // MARK: - MessageRepository

    @Test("消息：发送即存 → delta 追加 → 状态流转 → 按 sequence 读取")
    func messageLifecycle() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/a", at: t0)

        let seq = try messages.nextSequence(threadID: "t1")
        #expect(seq == 1)
        let user = Message(
            id: "m1", threadID: "t1", role: .user, content: "问题",
            sequence: seq, status: .completed, createdAt: t0, updatedAt: t0
        )
        try messages.insert(user)

        let assistant = Message(
            id: "m2", threadID: "t1", role: .assistant, content: "",
            sequence: try messages.nextSequence(threadID: "t1"),
            status: .streaming, createdAt: t1, updatedAt: t1
        )
        try messages.insert(assistant)
        try messages.appendContent(messageID: "m2", delta: "你", at: t1)
        try messages.appendContent(messageID: "m2", delta: "好", at: t1)
        try messages.updateStatus(messageID: "m2", status: .completed, at: t1)

        let all = try messages.messages(threadID: "t1")
        #expect(all.map(\.id) == ["m1", "m2"], "应按 sequence 升序")
        #expect(all[1].content == "你好")
        #expect(all[1].status == .completed)

        // 插入消息应同事务触碰线程活动时间（t0 → t1）。
        let thread = try threads.listThreads()[0]
        #expect(thread.updatedAt == t1)
    }

    @Test("同事务复合写入：中途抛出整体回滚，不写半")
    func transactionRollback() async throws {
        struct Boom: Error {}
        let appDB = try AppDatabase.makeInMemory()
        let thread = ConversationThread(
            id: "t1", title: "主", projectRoot: "/a", createdAt: t0, updatedAt: t0
        )
        _ = try? await appDB.db.write { db in
            try thread.insert(db)
            throw Boom()
        }
        let count = try await appDB.db.read { db in try ConversationThread.fetchCount(db) }
        #expect(count == 0, "事务回滚后不应残留任何行")
    }
}
