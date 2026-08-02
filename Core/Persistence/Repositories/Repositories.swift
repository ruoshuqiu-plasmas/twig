import Foundation
import GRDB
import Shared

/// 数据仓储层（任务 M1-011）：所有数据库存取的唯一入口。
///
/// 核心约束：
/// - 复合写入同事务（GRDB `write` 块即事务，抛出即整体回滚）；
/// - 不把完整 ACP SDK 对象序列化进库；
/// - 线程/支线删除等操作不在第一阶段范围，本层只提供 B-M1 主对话需要的最小集。
public struct ThreadRepository: Sendable {

    private let db: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        self.db = appDatabase.db
    }

    /// 创建主线程（B-M1 每线程独立 project_root）。
    @discardableResult
    public func createThread(
        id: String = UUID().uuidString,
        title: String,
        projectRoot: String,
        at date: Date = Date()
    ) throws -> ConversationThread {
        let thread = ConversationThread(
            id: id, title: title, projectRoot: projectRoot,
            createdAt: date, updatedAt: date
        )
        try db.write { db in try thread.insert(db) }
        return thread
    }

    /// 按最近活动排序列出全部线程。
    public func listThreads() throws -> [ConversationThread] {
        try db.read { db in
            try ConversationThread
                .order(Column("updated_at").desc)
                .fetchAll(db)
        }
    }

    /// 更新线程活动时间的内部语句（MessageRepository 写入时同事务调用）。
    static func touchThread(_ db: Database, threadID: String, at date: Date) throws {
        try db.execute(
            sql: "UPDATE threads SET updated_at = ? WHERE id = ?",
            arguments: [date, threadID]
        )
    }
}

/// session ↔ thread/branch 映射的持久化（M1-010 的 ``SessionMappingStore`` 缝）。
extension ThreadRepository: SessionMappingStore {

    /// 保存/更新映射；单条 UPDATE 天然原子（thread 与 branch 只会命中其一）。
    public func saveMapping(sessionID: String, owner: SessionStore.Owner) throws {
        switch owner {
        case .thread(let threadID):
            try db.write { db in
                try db.execute(
                    sql: "UPDATE threads SET acp_session_id = ? WHERE id = ?",
                    arguments: [sessionID, threadID]
                )
            }
        case .branch(let branchID):
            try db.write { db in
                try db.execute(
                    sql: "UPDATE branches SET acp_session_id = ? WHERE id = ?",
                    arguments: [sessionID, branchID]
                )
            }
        }
    }

    /// 摘除映射（按 sessionID 反查置空；线程/支线两表都查）。
    public func removeMapping(sessionID: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE threads SET acp_session_id = NULL WHERE acp_session_id = ?",
                arguments: [sessionID]
            )
            try db.execute(
                sql: "UPDATE branches SET acp_session_id = NULL WHERE acp_session_id = ?",
                arguments: [sessionID]
            )
        }
    }

    /// 读取全部映射（应用启动重建；isLive 由 ``SessionStore/restoreFromStore()`` 统一置 false）。
    public func loadMappings() throws -> [SessionStore.Registration] {
        try db.read { db in
            let threads = try ConversationThread
                .filter(Column("acp_session_id") != nil)
                .fetchAll(db)
                .map { SessionStore.Registration(sessionID: $0.acpSessionID!, owner: .thread($0.id)) }
            let branches = try Branch
                .filter(Column("acp_session_id") != nil)
                .fetchAll(db)
                .map { SessionStore.Registration(sessionID: $0.acpSessionID!, owner: .branch($0.id)) }
            return threads + branches
        }
    }
}

/// 消息仓储（B-M1 主对话最小集：插入/追加/状态流转/按 sequence 读取）。
public struct MessageRepository: Sendable {

    private let db: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        self.db = appDatabase.db
    }

    /// 同一会话（thread + branch 维度；branch 为空 = 主线）的下一个 sequence。
    public func nextSequence(threadID: String, branchID: String? = nil) throws -> Int {
        try db.read { db in
            let sql = """
            SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages
            WHERE thread_id = ? AND branch_id IS ?
            """
            return try Int.fetchOne(db, sql: sql, arguments: [threadID, branchID]) ?? 1
        }
    }

    /// 插入消息（§5.7：发送即存 / 流式占位），同事务触碰线程活动时间；
    /// 支线消息一并触碰支线 updated_at（DEC-09 同级「最近活动」排序的数据前提；
    /// 流式 delta 走 ``appendContent`` 不触碰，避免每条 delta 触发树重建）。
    public func insert(_ message: Message) throws {
        try db.write { db in
            try message.insert(db)
            try ThreadRepository.touchThread(db, threadID: message.threadID, at: message.updatedAt)
            if let branchID = message.branchID {
                try db.execute(
                    sql: "UPDATE branches SET updated_at = ? WHERE id = ?",
                    arguments: [message.updatedAt, branchID]
                )
            }
        }
    }

    /// 流式追加正文（delta 顺序追加到同一消息，§5.7）。
    public func appendContent(messageID: String, delta: String, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE messages SET content = content || ?, updated_at = ? WHERE id = ?",
                arguments: [delta, date, messageID]
            )
        }
    }

    /// 工具卡片整行更新（M2-002：content/metadata/status 一并落库，不追加）。
    public func updateMetadata(
        messageID: String,
        content: String,
        metadataJSON: String?,
        status: MessageStatus,
        at date: Date = Date()
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE messages SET content = ?, metadata_json = ?, status = ?, updated_at = ? WHERE id = ?",
                arguments: [content, metadataJSON, status.rawValue, date, messageID]
            )
        }
    }

    /// 状态流转（completed/interrupted/failed，§5.7）。
    public func updateStatus(messageID: String, status: MessageStatus, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE messages SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, date, messageID]
            )
        }
    }

    /// 按 sequence 升序读取一个会话的全部消息。
    public func messages(threadID: String, branchID: String? = nil) throws -> [Message] {
        try db.read { db in
            var request = Message
                .filter(Column("thread_id") == threadID)
                .order(Column("sequence"))
            if let branchID {
                request = request.filter(Column("branch_id") == branchID)
            } else {
                request = request.filter(Column("branch_id") == nil)
            }
            return try request.fetchAll(db)
        }
    }
}
