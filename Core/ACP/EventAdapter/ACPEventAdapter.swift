import Foundation
import ACP

/// SDK 通知 → ``AgentEvent`` 领域事件适配（任务 M1-009）。
///
/// 职责（§5.6）：SDK 类型到领域类型的映射、未知事件的保留与保守记录。
/// 不在此层做界面状态判断；事件顺序与 session 归属由上层（M1-010 路由）按 sessionID 消费。
/// 须容忍 tool_call_update 稀疏字段（G0 实测：字段可空）。
public struct ACPEventAdapter: Sendable {

    /// 未知事件保守记录 hook（接 Shared.Logging；只记事件类型，不记内容——脱敏约束）。
    public var onUnknownEvent: @Sendable (String) -> Void

    public init(onUnknownEvent: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onUnknownEvent = onUnknownEvent
    }

    /// 将一条 session/update 通知映射为领域事件。
    public func map(_ params: SessionUpdateNotification.Parameters) -> AgentEvent {
        let sid = params.sessionID
        switch params.update {
        case .agentMessageChunk(let chunk):
            return .textDelta(sessionID: sid, text: chunk.content.text)
        case .agentThoughtChunk(let chunk):
            return .thoughtDelta(sessionID: sid, text: chunk.content.text)
        case .userMessageChunk(let chunk):
            return .userTextDelta(sessionID: sid, text: chunk.content.text)
        case .toolCall(let call):
            return .toolCallStarted(sessionID: sid, call: Self.map(call))
        case .toolCallUpdate(let update):
            return .toolCallUpdated(sessionID: sid, call: Self.map(update))
        case .planUpdate(let plan):
            return .notice("plan 更新（\(plan.entries.count) 项）")
        case .availableCommandsUpdate(let update):
            return .notice("可用命令更新（\(update.availableCommands.count) 项）")
        case .currentModeUpdate(let update):
            return .notice("模式切换：\(update.currentModeID)")
        case .sessionInfoUpdate(let update):
            return .notice("session 信息更新：\(update.title ?? "无标题")")
        case .configOptionUpdate(let update):
            return .notice("配置项更新：\(update.key)")
        case .unknown(let updateType, _):
            onUnknownEvent(updateType)
            return .unknown(updateType: updateType, sessionID: sid)
        }
    }

    private static func map(_ call: ToolCall) -> ToolCallInfo {
        ToolCallInfo(
            toolCallID: call.toolCallID,
            title: call.title,
            kind: call.kind,
            status: call.status,
            paths: call.locations?.map(\.path)
        )
    }

    private static func map(_ update: ToolCallUpdate) -> ToolCallInfo {
        ToolCallInfo(
            toolCallID: update.toolCallID,
            title: update.title,
            kind: update.kind,
            status: update.status,
            contentText: update.content.flatMap(aggregateText),
            paths: update.locations?.map(\.path)
        )
    }

    /// 聚合 content 数组中的文本片段；diff/terminal 以占位摘要表达（卡片渲染在 M2-002）。
    /// G0 实测：每次 update 的 text 为累积快照（全量前缀），``ToolCallTracker`` 按替换合并。
    private static func aggregateText(_ contents: [ToolCallContent]) -> String? {
        var parts: [String] = []
        for content in contents {
            switch content {
            case .text(let text):
                parts.append(text.content.text)
            case .diff(let diff):
                parts.append("[diff: \(diff.path)]")
            case .terminal(let terminal):
                parts.append("[terminal: \(terminal.terminalID)]")
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
