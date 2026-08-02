import Foundation
import ACP

/// 自定义 `session/load` 方法（M4-010）。
///
/// 为什么不用 SDK 自带的 `SessionLoad`（kimi CLI 0.31.1 实测，见 g0-findings §2 补记）：
/// 1. kimi 要求 `mcpServers` 必须出现（空数组即可），SDK 将其建模为可选缺省省略 → -32602 Invalid params；
/// 2. kimi 的响应**不含 `sessionId`**（只回 `configOptions`），SDK 的 Result 要求非可选 sessionID → 解码失败。
///
/// 协议事实来源：2026-08-02 Python 探针复测（spike/probe_acp.py 驱动真实 CLI 0.31.1）。
public enum TwigSessionLoad: ACP.Method {
    public static let name = "session/load"

    public struct Parameters: Codable, Hashable, Sendable {
        public var sessionID: String
        public var cwd: String
        /// kimi 强制要求该字段存在（空数组合法）。
        public var mcpServers: [MCPServer]

        public init(sessionID: String, cwd: String, mcpServers: [MCPServer] = []) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.mcpServers = mcpServers
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case cwd
            case mcpServers
        }
    }

    /// 宽松结果：sessionId 可选（kimi 不回），configOptions 忽略（configOptions[] 建模缺口，
    /// 与任务 07 已知缺口一致，不影响续接语义）。
    public struct Result: Codable, Hashable, Sendable {
        public var sessionID: String?

        public init(sessionID: String? = nil) {
            self.sessionID = sessionID
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
        }
    }
}
