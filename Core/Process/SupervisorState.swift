import Foundation

/// 子进程生命周期状态机（流程文档 §5.5 定义的状态全集，不得随意增删）。
///
/// 迁移路径概要：
/// - `notChecked` →（环境检测）→ `cliMissing` / `unsupportedVersion` / `loginRequired` / `stopped`
/// - `stopped` → `starting` → `ready`（握手成功由 ACP 层调用 ``ACPProcessSupervisor/markReady``）
/// - `ready`/`starting` 中子进程异常退出 → `restarting`（有限次数 + 退避）→ 恢复 `starting`，或耗尽后 `failed`
/// - 应用正常退出 → `stopped`；不可恢复错误 → `failed(reason)`
public enum SupervisorState: Sendable, Equatable {
    /// 尚未做环境检测（应用启动初始态）。
    case notChecked
    /// CLI 不存在（G1-02：安装引导）。
    case cliMissing
    /// 凭据缺失/失效（G1-04：登录引导）。
    case loginRequired
    /// CLI 版本不兼容（G1-03）；`found` 为探测到的版本字符串，无法解析时为 nil。
    case unsupportedVersion(found: String?)
    /// 已检测通过、子进程未运行（可启动）。
    case stopped
    /// 子进程已拉起，等待 ACP 可用信号/握手结果。
    case starting
    /// ACP 握手完成，可接受 session 请求。
    case ready
    /// 子进程异常退出，退避后自动重启中。
    case restarting
    /// 不可恢复失败（含重启次数耗尽）。
    case failed(reason: String)
}

/// Supervisor 行为配置。重启次数与退避为内部配置（流程文档 §5.5「流程补充」），
/// 真实 CLI 测试后可调；测试注入毫秒级退避。
public struct SupervisorConfiguration: Sendable {
    /// 用户主目录（CLI 路径与凭据均以其为基准，测试可注入临时目录）。
    public var homeDirectory: URL
    /// kimi 可执行文件路径。
    public var cliPath: String
    /// 子进程参数（ACP 模式固定为 `["acp"]`）。
    public var arguments: [String]
    /// 异常退出后的最大自动重启次数。
    public var maxRestarts: Int
    /// 逐次重启的退避间隔（第 n 次重启取 `backoffDelays[n-1]`，超出取末位）。
    public var backoffDelays: [Duration]
    /// 优雅停止（关闭 stdin）后等待退出的上限，超时升级为 SIGKILL。
    /// 依据 G0 实测：SIGTERM 被 kimi 忽略，故升级路径直接 SIGKILL。
    public var gracefulShutdownTimeout: Duration
    /// stderr 行回调（CLI 日志走 stderr，G0 实测）。调用方负责脱敏，默认丢弃。
    public var onStderrLine: @Sendable (String) -> Void

    public init(
        homeDirectory: URL,
        cliPath: String? = nil,
        arguments: [String] = ["acp"],
        maxRestarts: Int = 3,
        backoffDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        gracefulShutdownTimeout: Duration = .seconds(5),
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.homeDirectory = homeDirectory
        self.cliPath = cliPath
            ?? homeDirectory.appendingPathComponent(".kimi-code/bin/kimi").path
        self.arguments = arguments
        self.maxRestarts = maxRestarts
        self.backoffDelays = backoffDelays
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.onStderrLine = onStderrLine
    }
}
