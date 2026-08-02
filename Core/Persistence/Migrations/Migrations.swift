import Foundation
import GRDB

/// schema 迁移集合（任务 M1-011 起逐个新增，已发布 migration 不得修改）。
///
/// v1 表结构依据开发文档 §4.4（核心四表）+ 流程文档 §5.8（工程字段）：
/// - messages: sequence / status / updated_at / metadata_json
/// - threads/branches: updated_at；branches: merge_note_id
///
/// 建表顺序：threads → branches → messages → branch_notes。
/// 注意：branches.anchor_message_id 不建 FK——它与 messages.branch_id 构成循环引用，
/// 而 SQLite 在外键开启时不允许 CREATE TABLE 引用尚未创建的表；锚点关系由应用层保证。
///
/// v2（DEC-07 / ADR-003，任务 M3-002）：branches 追加锚点坐标三列
/// （anchor_start / anchor_length / anchor_context_hash），只 ALTER TABLE 追加
/// nullable 列，不重建表、不补 FK（SQLite ALTER 不支持加 FK，应用层保证已足够）。
public enum Migrations {

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-core-tables") { db in
            try db.create(table: "threads") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("project_root", .text).notNull()
                t.column("acp_session_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "branches") { t in
                t.primaryKey("id", .text)
                t.column("thread_id", .text).notNull()
                    .references("threads", onDelete: .cascade)
                t.column("parent_branch_id", .text)
                    .references("branches")
                t.column("acp_session_id", .text)
                t.column("anchor_message_id", .text)
                t.column("anchor_quote", .text).notNull()
                t.column("seed_context", .text)
                t.column("status", .text).notNull()
                // 防重复回流（§5.8）；指向 branch_notes.id，不建 FK 避免循环依赖。
                t.column("merge_note_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_branches_thread", on: "branches", columns: ["thread_id"])

            try db.create(table: "messages") { t in
                t.primaryKey("id", .text)
                t.column("thread_id", .text).notNull()
                    .references("threads", onDelete: .cascade)
                t.column("branch_id", .text)
                    .references("branches", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("metadata_json", .text)
            }
            // 同一会话（主线或支线）内按 sequence 稳定排序（§5.8）。
            try db.create(
                index: "idx_messages_thread_branch_seq",
                on: "messages",
                columns: ["thread_id", "branch_id", "sequence"]
            )

            try db.create(table: "branch_notes") { t in
                t.primaryKey("id", .text)
                t.column("branch_id", .text).notNull()
                    .references("branches", onDelete: .cascade)
                t.column("thread_id", .text).notNull()
                    .references("threads", onDelete: .cascade)
                t.column("summary", .text).notNull()
                t.column("merged_at", .datetime).notNull()
            }
        }

        // v2：DEC-07 / ADR-003 锚点坐标（任务 M3-002）。
        // start/length 相对锚点消息渲染后纯文本（非原始 markdown 源）；
        // context_hash 为该纯文本的 SHA256 前 16 位 hex。三列均 nullable，
        // 既有支线（v1 时期）与新支线创建失败兜底时可为空，解析规则见 AnchorResolver。
        migrator.registerMigration("v2-anchor-coordinates") { db in
            try db.alter(table: "branches") { t in
                t.add(column: "anchor_start", .integer)
                t.add(column: "anchor_length", .integer)
                t.add(column: "anchor_context_hash", .text)
            }
        }
        return migrator
    }
}
