import Foundation

/// ACP 协议适配层输出的统一领域事件（任务 M1-009，流程文档 §5.6）。
///
/// 核心约束：
/// - ACP SDK 类型不得扩散到 Feature 层，上层只消费本枚举；
/// - 未知/损坏协议事件保守记录（``unknown(updateType:sessionID:)`` + 日志），不崩溃；
/// - permission 请求经事件透明展示，决策只走 PermissionPolicyEngine（M2-005 接入），
///   适配层默认 default deny。
public enum AgentEvent: Sendable, Equatable {
    /// agent_message_chunk：模型正文增量。
    case textDelta(sessionID: String, text: String)
    /// agent_thought_chunk：思考过程增量（G0 实测 kimi 会上报）。
    case thoughtDelta(sessionID: String, text: String)
    /// user_message_chunk：用户消息回放（session/load 重放时出现，G0 实测）。
    case userTextDelta(sessionID: String, text: String)
    /// tool_call：工具调用开始。
    case toolCallStarted(sessionID: String, call: ToolCallInfo)
    /// tool_call_update：工具调用状态/结果增量（字段稀疏，须容忍）。
    case toolCallUpdated(sessionID: String, call: ToolCallInfo)
    /// session/request_permission：权限请求（仅作透明展示；响应由策略器给出）。
    case permissionRequested(PermissionRequestData)
    /// 已知但暂不建模的事件摘要（plan/available_commands/current_mode/session_info/config_option）。
    case notice(String)
    /// prompt 完成（来自 session/prompt 响应的 stopReason）。
    case completed(sessionID: String, stopReason: String)
    /// 协议/链路失败。
    case failed(sessionID: String?, reason: String)
    /// 未知协议事件（保守记录，不崩溃）。
    case unknown(updateType: String, sessionID: String?)
}

/// 工具调用生命周期视图数据（requested → running → succeeded/failed/denied 由 status 承载；
/// 稳定 call id 形如 `0:tool_xxx`，跨 update 关联用）。
public struct ToolCallInfo: Sendable, Equatable, Hashable {
    public var toolCallID: String
    public var title: String?
    public var kind: String?
    public var status: String?
    /// 本次事件中携带的文本内容（G0 实测：tool_call_update 为**累积快照**而非增量，
    /// 合并语义见 ``ToolCallTracker``；终态时为结果摘要）。
    public var contentText: String?
    /// 关联文件路径（locations）。
    public var paths: [String]?

    public init(
        toolCallID: String,
        title: String? = nil,
        kind: String? = nil,
        status: String? = nil,
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

/// 权限请求数据（线格式依据 G0 脱敏样本：options 含 optionId/name/kind）。
public struct PermissionRequestData: Sendable, Equatable, Hashable {
    public var sessionID: String
    public var toolCallID: String?
    public var toolTitle: String?
    public var options: [Option]

    public struct Option: Sendable, Equatable, Hashable {
        public var optionID: String
        public var name: String
        /// allow_once / allow_always / reject_once（G0 实测三档）。
        public var kind: String
    }

    public init(sessionID: String, toolCallID: String? = nil, toolTitle: String? = nil, options: [Option]) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolTitle = toolTitle
        self.options = options
    }
}

/// 权限决策（由 PermissionPolicyEngine 产生，M2-005 已接入；无法给出规范响应时兜底 ``cancelled``）。
public enum PermissionDecision: Sendable, Equatable, Hashable {
    /// 选中某个选项（如 reject / approve_once）。
    case selected(optionID: String)
    /// 协议定义的取消（default deny 的保守表达）。
    case cancelled
}

extension AgentEvent {
    /// 事件归属的 ACP session id；``notice`` 等全局事件无归属（nil）。
    /// 供 ``SessionStore`` 按 session 路由（M1-010）。
    public var sessionID: String? {
        switch self {
        case .textDelta(let id, _), .thoughtDelta(let id, _), .userTextDelta(let id, _),
             .toolCallStarted(let id, _), .toolCallUpdated(let id, _),
             .completed(let id, _):
            return id
        case .permissionRequested(let data):
            return data.sessionID
        case .failed(let id, _), .unknown(_, let id):
            return id
        case .notice:
            return nil
        }
    }
}
