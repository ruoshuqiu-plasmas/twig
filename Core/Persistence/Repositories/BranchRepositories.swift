import Foundation
import GRDB
import Shared

/// 回流结果（``BranchRepository/recordMerge`` 的返回值，BR-14 幂等语义）。
public enum MergeOutcome: Equatable {
    /// 首次回流成功；携带新写入的 branch_notes.id。
    case merged(noteID: String)
    /// 该支线已回流过（merge_note_id 已存在），本次不重复写入。
    case alreadyMerged(existingNoteID: String)
}

/// 支线仓储（B-M3）：branches 表的创建/查询/状态与锚点维护，以及回流幂等事务。
public struct BranchRepository: Sendable {

    private let db: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        self.db = appDatabase.db
    }

    /// 创建支线（含锚点坐标三字段；默认状态 open）。
    @discardableResult
    public func create(
        id: String = UUID().uuidString,
        threadID: String,
        parentBranchID: String? = nil,
        acpSessionID: String? = nil,
        anchorMessageID: String? = nil,
        anchorQuote: String,
        anchorStart: Int? = nil,
        anchorLength: Int? = nil,
        anchorContextHash: String? = nil,
        seedContext: String? = nil,
        at date: Date = Date()
    ) throws -> Branch {
        let branch = Branch(
            id: id,
            threadID: threadID,
            parentBranchID: parentBranchID,
            acpSessionID: acpSessionID,
            anchorMessageID: anchorMessageID,
            anchorQuote: anchorQuote,
            anchorStart: anchorStart,
            anchorLength: anchorLength,
            anchorContextHash: anchorContextHash,
            seedContext: seedContext,
            createdAt: date,
            updatedAt: date
        )
        try db.write { db in try branch.insert(db) }
        return branch
    }

    /// 按 id 查询单条支线。
    public func branch(id: String) throws -> Branch? {
        try db.read { db in try Branch.fetchOne(db, key: id) }
    }

    /// 列出一个线程的全部支线（含嵌套），按创建时间升序。
    public func listBranches(threadID: String) throws -> [Branch] {
        try db.read { db in
            try Branch
                .filter(Column("thread_id") == threadID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// 列出某条支线的全部子支线，按创建时间升序。
    public func childBranches(parentBranchID: String) throws -> [Branch] {
        try db.read { db in
            try Branch
                .filter(Column("parent_branch_id") == parentBranchID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// 状态流转（open/merged/closed），同事务触碰线程活动时间
    /// （参考 ``MessageRepository/insert`` 模式）。
    public func updateStatus(branchID: String, status: BranchStatus, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE branches SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, date, branchID]
            )
            if let threadID = try threadID(ofBranch: branchID, db: db) {
                try ThreadRepository.touchThread(db, threadID: threadID, at: date)
            }
        }
    }

    /// 更新注入支线 session 的首条背景（BranchContextAssembler 产物落库）。
    public func updateSeedContext(branchID: String, seedContext: String, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE branches SET seed_context = ?, updated_at = ? WHERE id = ?",
                arguments: [seedContext, date, branchID]
            )
        }
    }

    /// 更新锚点坐标（锚点消息渲染后文本变化时重新定位后回写）。
    public func updateAnchor(
        branchID: String,
        anchorStart: Int?,
        anchorLength: Int?,
        anchorContextHash: String?,
        at date: Date = Date()
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                UPDATE branches
                SET anchor_start = ?, anchor_length = ?, anchor_context_hash = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [anchorStart, anchorLength, anchorContextHash, date, branchID]
            )
        }
    }

    /// 回流幂等事务（M3-012 用，BR-14）：单个 write 内完成
    /// ①已回流 → 不重复写入，返回 ``MergeOutcome/alreadyMerged(existingNoteID:)``；
    /// ②否则同事务插入 note + 插入主线消息（含 touchThread）+
    ///   更新 branches.status=.merged、merge_note_id=note.id → 返回 ``MergeOutcome/merged(noteID:)``。
    public func recordMerge(
        note: BranchNote,
        mainlineMessage: Message,
        branchID: String,
        at date: Date = Date()
    ) throws -> MergeOutcome {
        try db.write { db in
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT merge_note_id FROM branches WHERE id = ?",
                arguments: [branchID]
            ) {
                return .alreadyMerged(existingNoteID: existing)
            }
            try note.insert(db)
            try mainlineMessage.insert(db)
            try ThreadRepository.touchThread(db, threadID: mainlineMessage.threadID, at: date)
            try db.execute(
                sql: "UPDATE branches SET status = ?, merge_note_id = ?, updated_at = ? WHERE id = ?",
                arguments: [BranchStatus.merged.rawValue, note.id, date, branchID]
            )
            return .merged(noteID: note.id)
        }
    }

    /// 事务内反查支线所属线程 id。
    private func threadID(ofBranch branchID: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT thread_id FROM branches WHERE id = ?",
            arguments: [branchID]
        )
    }
}

/// 回流笔记仓储（branch_notes 表）。
public struct BranchNoteRepository: Sendable {

    private let db: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        self.db = appDatabase.db
    }

    /// 写入一条回流笔记（幂等事务见 ``BranchRepository/recordMerge``）。
    @discardableResult
    public func create(note: BranchNote) throws -> BranchNote {
        try db.write { db in try note.insert(db) }
        return note
    }

    /// 按支线 id 查询回流笔记（每支线至多一条）。
    public func note(forBranch branchID: String) throws -> BranchNote? {
        try db.read { db in
            try BranchNote
                .filter(Column("branch_id") == branchID)
                .fetchOne(db)
        }
    }

    /// 列出一个线程的全部回流笔记，按回流时间升序。
    public func listNotes(threadID: String) throws -> [BranchNote] {
        try db.read { db in
            try BranchNote
                .filter(Column("thread_id") == threadID)
                .order(Column("merged_at"))
                .fetchAll(db)
        }
    }
}
