import Foundation
import Testing
@testable import Core

/// 启动期问题分类测试（M1-013，G1-02/03/04 引导页的映射依据）。
@Suite("StartupIssue：启动问题三态映射")
struct StartupIssueTests {

    @Test("检测结果 → 启动问题：三类失败一一对应，ok 无问题")
    func probeMapping() {
        #expect(StartupIssue(probeResult: .cliMissing) == .cliMissing)
        #expect(StartupIssue(probeResult: .unsupportedVersion(found: "0.20.0"))
            == .unsupportedVersion(found: "0.20.0"))
        #expect(StartupIssue(probeResult: .unsupportedVersion(found: nil))
            == .unsupportedVersion(found: nil))
        #expect(StartupIssue(probeResult: .loginRequired) == .loginRequired)
        let ok = CLIProbeResult.ok(CLIEnvironment(cliPath: "/x", version: "0.31.0"))
        #expect(StartupIssue(probeResult: ok) == nil)
    }

    @Test("登录失效兜底识别：协议错误关键词命中，普通错误不误判")
    func authHeuristic() {
        #expect(StartupIssue.isAuthRelated(errorMessage: "HTTP 401 Unauthorized") == true)
        #expect(StartupIssue.isAuthRelated(errorMessage: "authentication failed") == true)
        #expect(StartupIssue.isAuthRelated(errorMessage: "please login again") == true)
        #expect(StartupIssue.isAuthRelated(errorMessage: "connection lost") == false)
        #expect(StartupIssue.isAuthRelated(errorMessage: "invalid params") == false)
    }
}
