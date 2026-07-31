import Foundation
import ACP

/// `session/request_permission`（agent → client 方向请求）的协议建模。
///
/// SDK 未内置此方法，按 G0 脱敏样本的线格式自行扩展（`Method` 协议开放）：
/// - 请求：`{sessionId, options: [{optionId, name, kind}], toolCall: {toolCallId, title, ...}}`
/// - 响应：`{outcome: {outcome: "selected", optionId}}` 或 `{outcome: {outcome: "cancelled"}}`
public enum RequestPermission: ACP.Method {
    public static let name = "session/request_permission"

    public struct Parameters: Codable, Hashable, Sendable {
        public var sessionID: String
        public var options: [Option]
        public var toolCall: ToolCallRef?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case options
            case toolCall
        }
    }

    public struct Option: Codable, Hashable, Sendable {
        public var optionID: String
        public var name: String
        public var kind: String

        private enum CodingKeys: String, CodingKey {
            case optionID = "optionId"
            case name
            case kind
        }
    }

    /// toolCall 引用：只取决策所需字段，其余（content 等）容忍忽略。
    public struct ToolCallRef: Codable, Hashable, Sendable {
        public var toolCallID: String
        public var title: String?

        private enum CodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case title
        }
    }

    public struct Result: Codable, Hashable, Sendable {
        public var outcome: Outcome

        public init(outcome: Outcome) {
            self.outcome = outcome
        }
    }

    /// 线格式为扁平对象：`{"outcome": "selected", "optionId": "..."}` 或 `{"outcome": "cancelled"}`。
    public struct Outcome: Codable, Hashable, Sendable {
        public var outcome: String
        public var optionID: String?

        private enum CodingKeys: String, CodingKey {
            case outcome
            case optionID = "optionId"
        }

        public init(outcome: String, optionID: String? = nil) {
            self.outcome = outcome
            self.optionID = optionID
        }

        public static func selected(_ optionID: String) -> Outcome {
            Outcome(outcome: "selected", optionID: optionID)
        }

        public static let cancelled = Outcome(outcome: "cancelled")
    }
}
