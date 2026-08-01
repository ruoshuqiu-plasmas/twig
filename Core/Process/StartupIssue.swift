import Foundation

/// 启动期问题分类（任务 M1-013）：环境检测三类失败（G1-02/03/04）+ 握手/连接失败。
///
/// UI 据此渲染对应的引导页（安装/升级/登录/重试），本层只提供分类，不含文案。
public enum StartupIssue: Sendable, Equatable {
    /// CLI 不存在或不可执行 → 安装引导（G1-02）。
    case cliMissing
    /// 版本无法解析或低于基线 → 版本不兼容提示（G1-03）。
    case unsupportedVersion(found: String?)
    /// 凭据缺失 → 登录引导（G1-04 的快速预判路径）。
    case loginRequired
    /// 环境检测通过但握手/连接失败 → 通用错误 + 重试。
    case connectFailed(reason: String)

    /// 从检测结果映射；`.ok` 无对应问题，返回 nil。
    public init?(probeResult: CLIProbeResult) {
        switch probeResult {
        case .ok:
            return nil
        case .cliMissing:
            self = .cliMissing
        case .unsupportedVersion(let found):
            self = .unsupportedVersion(found: found)
        case .loginRequired:
            self = .loginRequired
        }
    }

    /// 凭据文件存在但登录实际失效的兜底识别（G1-04 的另一路径）：
    /// 探测只查凭据文件存在性，失效与否最终以协议错误为准（G0 未采样到失效样本，
    /// 错误形态属待验证）——按关键词保守识别，命中即引导重新登录。
    public static func isAuthRelated(errorMessage: String) -> Bool {
        let lowered = errorMessage.lowercased()
        return lowered.contains("unauthorized")
            || lowered.contains("401")
            || lowered.contains("authentication")
            || lowered.contains("login")
    }
}
