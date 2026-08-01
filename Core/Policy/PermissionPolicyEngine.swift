import Foundation

/// 权限策略引擎（任务 M2-004）：第一阶段绝对只读。
///
/// 核心约束（§5.4）：permission 回调只进入本引擎，不由 View 决定。
/// allowlist 仅读文件/列目录/搜索；写、终端命令、未知类型、无法解析的请求一律
/// 默认拒绝（default deny）。
///
/// 响应形态按 G0 实测规范（g0-findings §4）：从 options 中按 kind 选取
/// （批准选 `allow_once`、拒绝选 `reject_once`），回 ``PermissionDecision/selected(optionID:)``；
/// optionId 字符串不硬编码；options 中找不到对应 kind 时兜底 ``PermissionDecision/cancelled``。
public struct PermissionPolicyEngine: Sendable {

    public init() {}

    /// 策略决策结果：决策 + 脱敏原因（日志只记操作分类与决策原因，不记请求内容）。
    public struct Outcome: Sendable, Equatable {
        public var decision: PermissionDecision
        public var operation: ToolOperation
        public var reason: String
    }

    /// 只读 allowlist（第一阶段唯一放行集）。
    private static let allowedOperations: Set<ToolOperation> = [.readFile, .listDirectory, .search]

    /// 纯函数式决策：同一输入必得同一输出，多并发请求各自独立（SEC-11）。
    public func decide(operation: ToolOperation, options: [PermissionRequestData.Option]) -> Outcome {
        if Self.allowedOperations.contains(operation) {
            if let option = options.first(where: { $0.kind == "allow_once" }) {
                return Outcome(
                    decision: .selected(optionID: option.optionID),
                    operation: operation,
                    reason: "只读操作在 allowlist 内，批准一次"
                )
            }
            return Outcome(
                decision: .cancelled,
                operation: operation,
                reason: "只读操作但 options 缺 allow_once，兜底取消"
            )
        }
        if let option = options.first(where: { $0.kind == "reject_once" }) {
            return Outcome(
                decision: .selected(optionID: option.optionID),
                operation: operation,
                reason: "非只读/未知操作，default deny（规范拒绝）"
            )
        }
        return Outcome(
            decision: .cancelled,
            operation: operation,
            reason: "非只读/未知操作且 options 缺 reject_once，兜底取消"
        )
    }
}
