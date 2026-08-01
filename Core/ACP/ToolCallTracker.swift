import Foundation

/// 工具调用生命周期状态（任务 M2-001：requested→running→succeeded/failed/denied）。
///
/// 协议侧状态字符串（G0 实测）：`pending`→``requested``、`in_progress`→``running``、
/// `completed`→``succeeded``、`failed`→``failed``。
/// **协议没有 denied 状态**：被拒绝的调用终态也是 `failed`（G0 样本实证，失败文本含
/// "rejected"）——``denied`` 由本层派生：权限策略器显式标记（M2-005 接入），
/// 或对 failed 文本的保守识别。
public enum ToolCallStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case requested
    case running
    case succeeded
    case failed
    case denied

    /// 协议状态字符串映射；未知字符串返回 nil（调用方保守保留原状态）。
    public init?(protocolStatus: String) {
        switch protocolStatus {
        case "pending": self = .requested
        case "in_progress": self = .running
        case "completed": self = .succeeded
        case "failed": self = .failed
        default: return nil
        }
    }

    /// 是否为终态（终态不可被后续稀疏 update 回退）。
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .denied: return true
        case .requested, .running: return false
        }
    }
}

/// 单个工具调用的聚合视图（跨事件按稳定 call id 合并，形如 `0:tool_xxx`）。
public struct ToolCallRecord: Sendable, Equatable, Hashable, Codable {
    public var toolCallID: String
    public var title: String?
    public var kind: String?
    public var status: ToolCallStatus
    /// 最新内容快照。G0 实测：tool_call_update 携带的是**累积文本**（每次为全量前缀），
    /// 合并语义为「最新快照替换」，不是追加。
    public var contentText: String?
    /// 关联文件路径（locations）。
    public var paths: [String]?

    public init(
        toolCallID: String,
        title: String? = nil,
        kind: String? = nil,
        status: ToolCallStatus = .requested,
        contentText: String? = nil,
        paths: [String]? = nil
    ) {
        self.toolCallID = toolCallID
        self.title = title
        self.kind = kind
        self.status = status
        self.contentText = contentText
        self.paths = paths
    }
}

/// 工具事件聚合器（任务 M2-001）：把 ``AgentEvent/toolCallStarted`` 与稀疏的
/// ``AgentEvent/toolCallUpdated`` 按稳定 call id 合并为生命周期视图。
///
/// 容忍规则（G0 实测为依据）：
/// - update 字段稀疏可空：只合并非 nil 字段；
/// - 乱序容忍：update 先于 started 到达也能建档；
/// - 状态单调：终态不被后续 update 回退；未知状态字符串保守保留原状态；
/// - failed 文本含 "rejected" 时派生为 denied（保守识别，供只读策略展示）。
public struct ToolCallTracker: Sendable {

    public private(set) var records: [ToolCallRecord] = []

    public init() {}

    /// 应用一条工具事件，返回更新后的记录（非工具事件返回 nil）。
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ToolCallRecord? {
        switch event {
        case .toolCallStarted(_, let call):
            return merge(call)
        case .toolCallUpdated(_, let call):
            return merge(call)
        default:
            return nil
        }
    }

    /// 显式标记拒绝（M2-005 权限策略器拒绝时调用；协议终态随后到达也不回退）。
    @discardableResult
    public mutating func markDenied(callID: String) -> ToolCallRecord {
        var record = records.first(where: { $0.toolCallID == callID })
            ?? ToolCallRecord(toolCallID: callID)
        record.status = .denied
        upsert(record)
        return record
    }

    public func record(callID: String) -> ToolCallRecord? {
        records.first(where: { $0.toolCallID == callID })
    }

    private mutating func merge(_ call: ToolCallInfo) -> ToolCallRecord {
        var record = records.first(where: { $0.toolCallID == call.toolCallID })
            ?? ToolCallRecord(toolCallID: call.toolCallID)
        // 稀疏字段只合并非 nil（G0：kind/title 可能中途才出现）。
        if let title = call.title { record.title = title }
        if let kind = call.kind { record.kind = kind }
        if let paths = call.paths { record.paths = paths }
        if let contentText = call.contentText { record.contentText = contentText }
        if let status = call.status {
            record.status = Self.resolve(existing: record.status, incoming: status, contentText: call.contentText)
        }
        upsert(record)
        return record
    }

    /// 状态合并：单调前进（requested < running < 终态），终态不回退；
    /// failed 文本含 "rejected" 派生 denied。
    static func resolve(existing: ToolCallStatus, incoming protocolStatus: String, contentText: String?) -> ToolCallStatus {
        guard let mapped = ToolCallStatus(protocolStatus: protocolStatus) else {
            return existing  // 未知状态字符串：保守保留
        }
        func rank(_ status: ToolCallStatus) -> Int {
            switch status {
            case .requested: return 0
            case .running: return 1
            case .succeeded, .failed, .denied: return 2
            }
        }
        guard rank(mapped) > rank(existing) else { return existing }
        if mapped == .failed, contentText?.localizedCaseInsensitiveContains("rejected") == true {
            return .denied
        }
        return mapped
    }

    private mutating func upsert(_ record: ToolCallRecord) {
        if let index = records.firstIndex(where: { $0.toolCallID == record.toolCallID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}
