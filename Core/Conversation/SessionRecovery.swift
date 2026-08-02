import Foundation

/// session 恢复状态（M4-010，§8.5）：区分「本地历史可见」与「agent 侧 session 已续接」，
/// 不制造「已续接」假象。随主线快照下发，UI 文案须与真实能力一致（G4 附加项）。
public enum SessionRecoveryState: String, Sendable, Equatable {
    /// 仅有本地历史（无已持久化的 session 映射可续接）。
    case localHistoryAvailable
    /// 经 `session/load` 续接成功（agent 侧历史重放已等安静窗口）。
    case sessionResumed
    /// 续接失败（agent 不支持 load 或 session 已不存在）；本地历史完整，
    /// 已退化为新建 session（继续对话不受阻）。
    case sessionUnavailable
    /// 进程重连后新建 session（旧 session 随进程死亡；本地历史完整）。
    case sessionRecreated
}

/// 上次选中线程的轻量持久化（M4-009，THREAD-04）：UserDefaults 单键，
/// 不值得为此加 migration。启动恢复读取见 ``ConversationStore/openRestoredOrCreate(projectRoot:lastSelectedThreadID:)``。
public struct SelectedThreadStore: @unchecked Sendable {

    public static let key = "twig.lastSelectedThreadID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> String? {
        defaults.string(forKey: Self.key)
    }

    public func save(_ threadID: String) {
        defaults.set(threadID, forKey: Self.key)
    }
}
