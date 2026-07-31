import Foundation
import GRDB

/// 领域模型与 GRDB 记录类型（任务 M1-011）。
///
/// 表结构依据开发文档 §4.4（核心四表）+ 流程文档 §5.8（工程字段）。
/// 锚点字段（anchor_start/length/hash）待 DEC-07 关闭后再加，届时新增 migration。
///
/// 核心约束：不把完整 ACP SDK 对象序列化进库——需要保留的协议扩展信息
/// 一律以摘要形式进 ``Message/metadataJSON``。

/// 消息角色。
public enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
    case system
}

/// 消息种类（开发文档 §4.4）。
public enum MessageKind: String, Codable, Sendable, Hashable {
    case text
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case notice
}

/// 消息状态机（流程文档 §5.7）。
public enum MessageStatus: String, Codable, Sendable, Hashable {
    case streaming
    case completed
    case interrupted
    case failed
}

/// 支线状态（开发文档 §4.4）。
public enum BranchStatus: String, Codable, Sendable, Hashable {
    case open
    case merged
    case closed
}

/// 主线程（threads 表）。
public struct ConversationThread: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "threads"

    public var id: String
    public var title: String
    public var projectRoot: String
    /// 关联的 ACP session（session ↔ thread 映射，M1-010）。
    public var acpSessionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        projectRoot: String,
        acpSessionID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.projectRoot = projectRoot
        self.acpSessionID = acpSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case projectRoot = "project_root"
        case acpSessionID = "acp_session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 消息（messages 表；branch_id 为空 = 主线消息）。
public struct Message: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "messages"

    public var id: String
    public var threadID: String
    public var branchID: String?
    public var role: MessageRole
    public var kind: MessageKind
    public var content: String
    /// 同一会话内稳定排序（§5.8）。
    public var sequence: Int
    public var status: MessageStatus
    public var createdAt: Date
    public var updatedAt: Date
    /// 工具调用或协议扩展字段的摘要 JSON（不存完整 ACP SDK 对象）。
    public var metadataJSON: String?

    public init(
        id: String,
        threadID: String,
        branchID: String? = nil,
        role: MessageRole,
        kind: MessageKind = .text,
        content: String,
        sequence: Int,
        status: MessageStatus,
        createdAt: Date,
        updatedAt: Date,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.branchID = branchID
        self.role = role
        self.kind = kind
        self.content = content
        self.sequence = sequence
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, role, kind, content, sequence, status
        case threadID = "thread_id"
        case branchID = "branch_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case metadataJSON = "metadata_json"
    }
}

/// 支线（branches 表；parent_branch_id 为空 = 一级支线）。
public struct Branch: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "branches"

    public var id: String
    public var threadID: String
    public var parentBranchID: String?
    public var acpSessionID: String?
    /// 「从哪段文字长出」：锚点消息 + 引文（树→原文回跳，B-M3/B-M4）。
    public var anchorMessageID: String?
    public var anchorQuote: String
    /// 注入支线新 session 的首条背景（BranchContextAssembler 产物，B-M3）。
    public var seedContext: String?
    public var status: BranchStatus
    /// 防重复回流（§5.8）；指向 branch_notes.id（不建 FK，避免循环依赖）。
    public var mergeNoteID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        threadID: String,
        parentBranchID: String? = nil,
        acpSessionID: String? = nil,
        anchorMessageID: String? = nil,
        anchorQuote: String,
        seedContext: String? = nil,
        status: BranchStatus = .open,
        mergeNoteID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.parentBranchID = parentBranchID
        self.acpSessionID = acpSessionID
        self.anchorMessageID = anchorMessageID
        self.anchorQuote = anchorQuote
        self.seedContext = seedContext
        self.status = status
        self.mergeNoteID = mergeNoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case threadID = "thread_id"
        case parentBranchID = "parent_branch_id"
        case acpSessionID = "acp_session_id"
        case anchorMessageID = "anchor_message_id"
        case anchorQuote = "anchor_quote"
        case seedContext = "seed_context"
        case mergeNoteID = "merge_note_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 回流笔记（branch_notes 表，B-M3 结论回流产物）。
public struct BranchNote: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "branch_notes"

    public var id: String
    public var branchID: String
    public var threadID: String
    public var summary: String
    public var mergedAt: Date

    public init(id: String, branchID: String, threadID: String, summary: String, mergedAt: Date) {
        self.id = id
        self.branchID = branchID
        self.threadID = threadID
        self.summary = summary
        self.mergedAt = mergedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, summary
        case branchID = "branch_id"
        case threadID = "thread_id"
        case mergedAt = "merged_at"
    }
}
