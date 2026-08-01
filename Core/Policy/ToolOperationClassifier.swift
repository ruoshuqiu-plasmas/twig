import Foundation

/// 权限操作分类（任务 M2-003）：协议工具/权限类型 → 内部操作类别。
public enum ToolOperation: String, Sendable, Hashable, CaseIterable {
    case readFile
    case listDirectory
    case search
    case writeFile
    case executeCommand
    /// 请求带分类字段但无法归入已知类型（含 CLI 升级新增类型，SEC-09/14）。
    case unknown
    /// 请求自身缺分类字段（SEC-10）。
    case unparseable
}

/// 权限类型映射（任务 M2-003，基于真实样本）。
///
/// 映射依据（`spike/samples/sanitized/` G0 脱敏样本）：
/// - tool_call 的 `kind` 实测值：`read`、`edit`（perms 样本）、`execute`（terminal 样本）；
/// - permission 请求 toolCall 的 `title` 实测值：`Read`、`Write`、`Bash`；
/// - G0 权限三分：Read 不触发 permission，Write/Bash 触发（见 g0-findings §4）。
///
/// 输入优先级（permission 请求自身不带 kind，G0 实测时序 tool_call 先、request_permission 后）：
/// 1. 首选 `kind`（ToolCallTracker 按 toolCallId 关联已记录的 tool_call 事件）；
/// 2. 兜底 `title` 字符串映射（仅映射样本中实测出现的名字）；
/// 3. 两者都缺 → ``ToolOperation/unparseable``；值无法识别 → ``ToolOperation/unknown``。
/// CLI 新增类型一律落 unknown（default deny，SEC-14）。
public enum ToolOperationClassifier {

    /// 分类入口。
    /// - Parameters:
    ///   - kind: 先前 tool_call sessionUpdate 记录的 kind（可能为 nil 或中途才出现）。
    ///   - title: permission 请求 toolCall 引用携带的 title。
    public static func classify(kind: String?, title: String?) -> ToolOperation {
        if let kind { return classifyKind(kind) }
        if let title { return classifyTitle(title) }
        return .unparseable
    }

    /// kind 映射（样本实测值；未列出的 kind 一律 unknown）。
    private static func classifyKind(_ kind: String) -> ToolOperation {
        switch kind {
        case "read": return .readFile
        case "edit": return .writeFile
        case "execute": return .executeCommand
        default: return .unknown
        }
    }

    /// title 兜底映射（`Read`/`Write`/`Bash` 为样本实测；`Edit`/`Terminal` 为同族命名覆盖）。
    private static func classifyTitle(_ title: String) -> ToolOperation {
        switch title {
        case "Read": return .readFile
        case "Write", "Edit": return .writeFile
        case "Bash", "Terminal": return .executeCommand
        default: return .unknown
        }
    }
}
